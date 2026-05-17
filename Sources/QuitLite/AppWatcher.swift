import AppKit
import ApplicationServices

/// Tek bir uygulamayı izler: o uygulamaya bağlı bir AXObserver kurar,
/// pencere olaylarında "standart pencere" sayısını yeniden hesaplar.
///
/// Tasarım ilkesi: AX callback'leri güvenilmez olduğu için callback yalnızca
/// bir "tetikleyici"dir — gerçek pencere sayısı her seferinde yeniden sayılır.
final class AppWatcher {

    let app: NSRunningApplication
    let pid: pid_t
    let bundleID: String

    private let axApp: AXUIElement
    private var observer: AXObserver?

    /// Bir değerlendirme (evaluate) zaten bu runloop turu için sıraya alındı mı?
    /// Odak değişimi gibi durumlarda AX bildirimleri art arda gelir; bu bayrak
    /// onları tek bir taramada birleştirir. Yalnızca ana thread'den okunup yazılır.
    private var evaluateScheduled = false

    /// 'yok edildi' bildirimi kayıtlı olan pencere öğeleri. Her kayıt turundan
    /// önce bunların kaydı kaldırılır; aksi halde yok edilmiş pencerelerin
    /// kayıtları AXObserver'ın tablosunda zamanla sınırsız birikir (bellek sızıntısı).
    private var registeredWindows: [AXUIElement] = []

    /// Uygulamanın izlenmeye başladığından beri en az bir penceresi oldu mu?
    /// Hiç pencere açmamış (menü çubuğu / arka plan) uygulamalar asla kapatılmaz.
    private(set) var hadWindow = false

    /// Son standart pencere de kapandığında çağrılır.
    var onWindowsEmptied: ((AppWatcher) -> Void)?
    /// Yeniden pencere açıldığında çağrılır (bekleyen kapatmayı iptal için).
    var onWindowAppeared: ((AppWatcher) -> Void)?

    init?(app: NSRunningApplication) {
        guard let bid = app.bundleIdentifier else { return nil }
        self.app = app
        self.pid = app.processIdentifier
        self.bundleID = bid
        self.axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Yanıt vermeyen bir uygulama çekirdeğin ana thread'ini uzun süre
        // kilitlemesin diye AX çağrılarına sıkı bir zaman sınırı koy. 0,3 sn
        // sağlıklı bir uygulama için fazlasıyla yeterli (AX yanıtları genelde
        // <10 ms); donmuş bir uygulama her çağrıda en fazla 0,3 sn bloklar.
        AXUIElementSetMessagingTimeout(axApp, 0.3)
    }

    func start() {
        // İki kez başlatılırsa ikinci observer sızar; zaten çalışıyorsa çık.
        guard observer == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else {
            // Nadir. Uygulama yine de emniyet taramasıyla izlenir (olay tabanlı
            // değil, ~10 sn gecikmeli); sessiz kalmasın diye kaydet.
            NSLog("QuitLite: AXObserver oluşturulamadı — pid \(pid) (\(bundleID))")
            return
        }
        observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, axApp, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(obs, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, axApp, kAXMainWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)

        registerDestroyObservers()
        evaluate()
    }

    func stop() {
        guard let obs = observer else { return }
        // Uygulama düzeyindeki bildirimleri açıkça kaldır. Pencere düzeyindeki
        // 'yok edildi' bildirimleri ise observer serbest kalınca temizlenir.
        for notification in [kAXWindowCreatedNotification,
                             kAXFocusedWindowChangedNotification,
                             kAXMainWindowChangedNotification] {
            AXObserverRemoveNotification(obs, axApp, notification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = nil
    }

    /// AX'in bildirdiği "standart" pencerelerin listesi (kayan palet/panel gibi
    /// yardımcılar elenir). Bu liste yalnızca "yok edildi" bildirimi kaydı için
    /// kullanılır; kapatma KARARI için `isWindowless()` kullanılır.
    ///
    /// AX çağrısı başarısız olursa `nil` döner — "durum bilinmiyor" demektir.
    func standardWindows() -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var result: [AXUIElement] = []
        for window in windows {
            // Alt-rol SORGULANAMAZSA durum belirsizdir → nil dön; aksi halde
            // sorgu hatası "0 pencere" sanılıp uygulama yanlışlıkla kapatılır.
            guard let standard = isStandardWindow(window) else { return nil }
            if standard { result.append(window) }
        }
        return result
    }

    /// Uygulama kapatılmaya aday mı — yani penceresiz mi?
    ///  • AX standart pencere SAYISI ≥ 1:
    ///     – ekranda görünür pencere var → açık (false).
    ///     – minimize pencere var → açık (false).
    ///     – aksi halde hepsi gizli (Discord — `orderOut`) → penceresiz (true).
    ///  • AX standart pencere YOK (0):
    ///     – ekranı kaplayan bir pencere varsa uygulama TAM EKRANDADIR (tam ekran
    ///       uygulama AX'te pencere bildirmez) → açık (false).
    ///     – aksi halde gerçekten penceresiz (true).
    /// AX durumu belirsizse `nil` döner — çağıran kapatma yapmaz.
    func isWindowless() -> Bool? {
        guard let windows = standardWindows() else { return nil }
        if !windows.isEmpty {
            if WindowPresence.hasOnScreenWindow(pid: pid) { return false }
            for window in windows where isMinimized(window) { return false }
            return true
        }
        // AX 0 standart pencere bildiriyor. Tam ekran uygulama da 0 bildirir —
        // ekranı kaplayan penceresi varsa kapatma.
        return !WindowPresence.hasFullScreenWindow(pid: pid)
    }

    /// Pencere minimize mi? AX hatasında `false` döner — güvenli yön: emin
    /// olunmayan pencere "minimize değil" sayılır, karar görünürlüğe bırakılır.
    private func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString,
                                            &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// Yalnızca kesinlikle yardımcı olan kayan palet/panel alt-rolleri. Pencere
    /// sayımında KARA liste olarak kullanılır: bu sette OLMAYAN her pencere
    /// gerçek sayılır. Süreç ömrü boyunca bir kez oluşturulur (static let).
    private static let auxiliarySubroles: Set<String> = [
        kAXFloatingWindowSubrole as String,
        kAXSystemFloatingWindowSubrole as String
    ]

    /// true  = uygulamayı ayakta tutan gerçek bir pencere,
    /// false = yalnızca yardımcı pencere (kayan palet/panel),
    /// nil   = alt-rol sorgulanamadı (AX hatası — durum belirsiz).
    ///
    /// Beyaz liste ("yalnızca AXStandardWindow say") yerine KARA liste: alt-rolü
    /// kesinlikle yardımcı olanlar dışında her pencere gerçek sayılır. Electron
    /// uygulamaları (Discord, Slack, VS Code…) özel başlık çubuğu kullandığından
    /// ana pencerelerini her zaman `AXStandardWindow` bildirmez; beyaz liste
    /// bunları görmezden gelir, kara liste görür. Bu yön yanlış kapatma riskini
    /// ARTIRMAZ — azaltır: daha çok pencere "gerçek" sayılır, uygulama daha geç
    /// kapatılır.
    private func isStandardWindow(_ window: AXUIElement) -> Bool? {
        var roleValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            window, kAXSubroleAttribute as CFString, &roleValue)
        switch status {
        case .success:
            // Alt-rol bir String değilse (boş değer) yardımcı değildir → gerçek say.
            guard let subrole = roleValue as? String else { return true }
            return !AppWatcher.auxiliarySubroles.contains(subrole)
        case .noValue, .attributeUnsupported:
            // Pencerenin alt-rolü hiç yok — yardımcı değil → gerçek say.
            // (Özel başlık çubuklu Electron pencereleri sıklıkla buraya düşer.)
            return true
        default:
            // .cannotComplete (uygulama yanıt vermiyor) vb. → durum belirsiz.
            return nil
        }
    }

    /// Mevcut pencerelere "yok edildi" bildirimi kaydeder. Önce önceki turdaki
    /// kayıtları (yok edilmiş pencereler dahil) kaldırır ki AXObserver'ın kayıt
    /// tablosu zamanla sınırsız büyümesin. AX durumu belirsizse kayıtlara dokunmaz.
    private func registerDestroyObservers() {
        guard let obs = observer else { return }
        guard let current = standardWindows() else { return }
        // Yok edilmiş öğelere RemoveNotification zararsızdır (hata döner, çökmez).
        for window in registeredWindows {
            AXObserverRemoveNotification(obs, window, kAXUIElementDestroyedNotification as CFString)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in current {
            AXObserverAddNotification(obs, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        registeredWindows = current
    }

    /// Pencere durumunu yeniden hesaplar ve uygun callback'i tetikler.
    func evaluate() {
        guard !app.isTerminated else { return }
        // nil = durum belirlenemedi (AX hatası) → hiçbir şey yapma.
        guard let windowless = isWindowless() else {
            if kDebugMode { NSLog("QuitLite[eval] \(bundleID): durum belirsiz → karar yok") }
            return
        }
        if windowless {
            if kDebugMode && hadWindow {
                NSLog("QuitLite[eval] \(bundleID): penceresiz → onWindowsEmptied")
            }
            if hadWindow { onWindowsEmptied?(self) }
        } else {
            if kDebugMode && !hadWindow {
                NSLog("QuitLite[eval] \(bundleID): hadWindow false→true")
            }
            hadWindow = true
            onWindowAppeared?(self)
        }
    }

    fileprivate func handleNotification() {
        // Olaylar art arda gelebilir (örn. pencereler arası odak değişiminde
        // birden çok bildirim). Her birinde tam AX pencere taraması yapmak
        // yerine değerlendirmeyi runloop turunun sonuna ertele; aynı tura
        // düşen tüm bildirimler tek bir taramada birleşir.
        guard !evaluateScheduled else { return }
        evaluateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.evaluateScheduled = false
            // Bu arada stop() çağrıldıysa değerlendirme yapma.
            guard self.observer != nil else { return }
            // AX çağrıları geçici CF nesneleri üretir; tepe bellek kullanımını
            // sınırlamak için hemen serbest bırak.
            autoreleasepool {
                // Her turda yeniden kaydet: 'windowCreated' bildirimi kaçırılsa
                // bile yeni pencereler 'yok edildi' bildirimine kavuşur.
                // Kayıt idempotent ve ucuzdur (zaten kayıtlıysa no-op).
                self.registerDestroyObservers()
                self.evaluate()
            }
        }
    }
}

/// AXObserver C callback'i — bağlam yakalayamadığı için refcon ile AppWatcher'a köprülenir.
private func axObserverCallback(_ observer: AXObserver,
                                _ element: AXUIElement,
                                _ notification: CFString,
                                _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<AppWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleNotification()
}

/// Pencere sunucusuna (CGWindowList) dayalı iki soruyu yanıtlar:
///  • Uygulamanın O AN ekranda görünen penceresi var mı?
///  • Uygulamanın bir ekranı tam kaplayan (tam ekran) penceresi var mı?
///
/// `CGWindowListCopyWindowInfo` sistem genelinde pencere bilgisi tahsis eden
/// pahalı bir çağrıdır; emniyet taraması her pencereli uygulama için sorar.
/// Sonuç 0,5 sn önbelleğe alınır: tüm tarama turu tek anlık görüntüyü paylaşır,
/// recheck (1 sn sonra) süre dolduğu için taze veri alır. Yalnızca ana
/// thread'den erişilir — kilit gerekmez.
private enum WindowPresence {
    private static var onScreenPIDs: Set<pid_t> = []
    private static var fullScreenPIDs: Set<pid_t> = []
    private static var capturedAt: TimeInterval = -1

    /// Bu uygulamanın O AN ekranda görünen (layer 0) bir penceresi var mı?
    static func hasOnScreenWindow(pid: pid_t) -> Bool {
        refreshIfStale()
        return onScreenPIDs.contains(pid)
    }

    /// Bu uygulamanın boyutu bir ekranı tam kaplayan (= macOS tam ekran modu)
    /// penceresi var mı? Tam ekran uygulama AX'te pencere bildirmediği için bu
    /// CG tabanlı kontrol gerekir.
    static func hasFullScreenWindow(pid: pid_t) -> Bool {
        refreshIfStale()
        return fullScreenPIDs.contains(pid)
    }

    private static func refreshIfStale() {
        let now = ProcessInfo.processInfo.systemUptime
        guard capturedAt < 0 || now - capturedAt > 0.5 else { return }
        capturedAt = now
        capture()
    }

    private static func capture() {
        var onScreen: Set<pid_t> = []
        var fullScreen: Set<pid_t> = []
        let screenSizes = NSScreen.screens.map { $0.frame.size }
        if let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] {
            for window in list {
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      let owner = window[kCGWindowOwnerPID as String] as? Int else { continue }
                let pid = pid_t(owner)
                if (window[kCGWindowIsOnscreen as String] as? Bool) == true {
                    onScreen.insert(pid)
                }
                if let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                   let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                   screenSizes.contains(where: {
                       abs($0.width - bounds.width) < 1 && abs($0.height - bounds.height) < 1 }) {
                    fullScreen.insert(pid)
                }
            }
        }
        onScreenPIDs = onScreen
        fullScreenPIDs = fullScreen
    }
}
