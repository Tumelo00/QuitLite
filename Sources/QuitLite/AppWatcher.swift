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

    /// Bu uygulamanın EKRANDA görülmüş gerçek pencerelerinin CG pencere
    /// numaraları. AX pencere listesi yalnızca AKTİF Space'i kapsadığından,
    /// kullanıcı başka Space'e geçince (ya da bir uygulamayı tam ekran yapınca)
    /// arka plandaki uygulamanın AX listesi boşalır — oysa penceresi durur.
    /// Bu küme, "başka Space'e park olmuş pencere" ile "gerçekten kapanmış
    /// pencere"yi ayırt etmek için kullanılır. Hayalet pencereler hiçbir zaman
    /// ekranda olmadığından bu kümeye asla girmez.
    private var knownOnScreenWindowIDs: Set<CGWindowID> = []

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
            // değil, ~2 sn gecikmeli); sessiz kalmasın diye kaydet.
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

    /// Uygulamanın o anki gerçek (uygulamayı ayakta tutan) pencerelerini döndürür.
    /// Kayan palet/panel gibi yardımcı pencereler sayılmaz. Minimize edilmiş
    /// pencereler "açık" sayılır.
    ///
    /// Discord/Slack/VS Code gibi Electron uygulamaları son pencere kapatılınca
    /// pencereyi YOK ETMEZ — `orderOut` ile gizler. Gizli pencere AX listesinde
    /// "standart pencere" olarak kalır; AX bu yüzden tek başına yetmez. Çözüm:
    /// AX standart pencereleri varsa, ek olarak pencere sunucusuna (CGWindowList)
    /// sorulur — gerçekten ekranda görünen pencere yoksa VE hiçbiri minimize
    /// değilse uygulama penceresiz sayılır.
    ///
    /// AX çağrısı başarısız olursa (uygulama yanıt vermiyor, izin yok vb.) `nil`
    /// döner — bu "durum bilinmiyor" demektir ve "0 pencere" ile karıştırılmamalıdır.
    /// Aksi halde yanıt vermeyen bir uygulama yanlışlıkla kapatılabilir.
    func standardWindows() -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var result: [AXUIElement] = []
        var anyMinimized = false
        for window in windows {
            // Herhangi bir pencerenin alt-rolü SORGULANAMAZSA (örn. izin tam bu
            // sırada geri alındı) durum belirsizdir → nil dön. Aksi halde sorgu
            // hataları "0 standart pencere" sanılıp uygulama yanlışlıkla kapatılır.
            guard let standard = isStandardWindow(window) else { return nil }
            guard standard else { continue }
            result.append(window)
            // Tek bir minimize pencere bile uygulamayı "açık" yapar; ilkini
            // bulunca AX'e sormayı bırak.
            if !anyMinimized, isMinimized(window) { anyMinimized = true }
        }
        // Bu uygulamanın ŞU AN ekranda (aktif Space'te) olan pencerelerinin CG
        // numaralarını al; varsa "bilinen gerçek pencereler" olarak sakla — bir
        // sonraki Space değişiminde park kontrolü için gerekecek.
        let onScreenIDs = WindowServerCache.onScreenWindowIDs(pid: pid)
        if !onScreenIDs.isEmpty { knownOnScreenWindowIDs = onScreenIDs }
        // AX'te standart pencere var ama hiçbiri minimize değil → bunların hepsi
        // gizli (Discord gibi) olabilir. Pencere sunucusu ekranda görünür pencere
        // bildirmiyorsa uygulama penceresiz sayılır (gizli pencere kapatma yolu).
        //
        // app.isHidden: kullanıcı uygulamayı Cmd-H ile GİZLEDİ — bu bir pencere
        // kapatma değildir, pencereler olduğu gibi durur. Gizli uygulama "açık"
        // sayılır; aksi halde Cmd-H'lanan her uygulama yanlışlıkla kapatılırdı.
        // (Electron'un pencere kapatması uygulamayı gizlemez → isHidden false →
        // o yol etkilenmez.)
        if !result.isEmpty, !anyMinimized, !app.isHidden, onScreenIDs.isEmpty {
            return []
        }
        return result
    }

    /// AX'in pencere listesi yalnızca AKTİF Space'i kapsar: tüm pencereleri
    /// başka bir Space'te olan uygulama (kullanıcı Space değiştirince ya da
    /// başka bir uygulamayı tam ekran yapınca) AX'e göre "penceresiz" görünür —
    /// oysa penceresi durur. Bu, gerçekten penceresiz bir uygulamayla
    /// karıştırılırsa arka plandaki uygulama yanlışlıkla kapatılır.
    ///
    /// Ayrım şudur: AX KESİNLİKLE 0 pencere bildiriyorsa (Space'e bağlı kör
    /// nokta) VE bu uygulamanın daha önce EKRANDA görülmüş bir penceresi hâlâ
    /// pencere sunucusunun sistem geneli listesinde (`[]` = tüm Space'ler)
    /// duruyorsa → pencere başka Space'te park olmuştur, kapatılmamalıdır.
    /// Gerçekten kapatılan pencere bu listeden anında düşer (test edilip
    /// doğrulandı); park olan pencere kalır. Aradaki fark budur.
    ///
    /// Electron'un gizlediği (orderOut) pencerelerde AX listesi BOŞALMAZ
    /// (pencere uygulamanın listesinde kalır) — bu yüzden gizli-pencereli
    /// Electron uygulaması "park" sayılmaz, otomatik kapatma mantığı bozulmaz.
    func hasParkedWindowOnAnotherSpace() -> Bool {
        // Daha önce hiç ekranda pencere görülmediyse park kararı verilemez.
        guard !knownOnScreenWindowIDs.isEmpty else { return false }
        // AX'i yeniden sorgula: yalnızca AX KESİN olarak 0 pencere derse park
        // ihtimali vardır. AX bir pencere bildiriyorsa (aktif Space'te ya da
        // Electron-gizli) bu bir park durumu değildir.
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString,
                                            &value) == .success,
              let axWindows = value as? [AXUIElement], axWindows.isEmpty else { return false }
        // Bilinen gerçek pencerelerden biri hâlâ sistem genelinde yaşıyor mu?
        let alive = WindowServerCache.allWindowIDs()
        return knownOnScreenWindowIDs.contains { alive.contains($0) }
    }

    /// Pencere minimize mi? AX hatasında `false` döner — bu güvenli yöndür:
    /// pencere yine de listede sayılır, uygulama yanlışlıkla kapatılmaz.
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

    /// Pencere sayısını yeniden hesaplar ve uygun callback'i tetikler.
    func evaluate() {
        guard !app.isTerminated else { return }
        // nil = pencere durumu belirlenemedi (AX hatası) → hiçbir şey yapma.
        guard let windows = standardWindows() else {
            if kDebugMode { NSLog("QuitLite[eval] \(bundleID): standardWindows=nil → karar yok") }
            return
        }
        if !windows.isEmpty {
            if kDebugMode && !hadWindow {
                NSLog("QuitLite[eval] \(bundleID): hadWindow false→true "
                    + "(\(windows.count) standart pencere)")
            }
            hadWindow = true
            onWindowAppeared?(self)
        } else if hadWindow {
            // AX aktif Space'te 0 standart pencere bildiriyor. Uygulamayı
            // penceresiz saymadan önce Space'e bağlı kör noktayı ele: penceresi
            // başka Space'e park olmuş bir uygulama hâlâ "açık" sayılmalıdır.
            if hasParkedWindowOnAnotherSpace() {
                if kDebugMode {
                    NSLog("QuitLite[eval] \(bundleID): 0 AX penceresi ama pencere "
                        + "başka Space'te park → açık sayıldı")
                }
                onWindowAppeared?(self)
            } else {
                if kDebugMode {
                    NSLog("QuitLite[eval] \(bundleID): 0 standart pencere + hadWindow → onWindowsEmptied")
                }
                onWindowsEmptied?(self)
            }
        } else if kDebugMode {
            NSLog("QuitLite[eval] \(bundleID): 0 standart pencere ama hadWindow=false → atlandı")
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

/// Pencere sunucusu (CoreGraphics) sorgularının kısa ömürlü önbelleği.
///
/// `CGWindowListCopyWindowInfo` sistem genelinde pencere bilgisi tahsis eden
/// pahalı bir çağrıdır. Emniyet taraması her uygulama için `standardWindows()`
/// çağırır; her biri ayrı ayrı sorsa tur başına onlarca tahsis olurdu. Sonuç
/// çok kısa süre (0,5 sn) önbelleğe alınır: tüm tarama turu tek bir CG çağrısı
/// paylaşır, recheck (1 sn sonra) ise süre dolduğundan taze veri alır. Yalnızca
/// ana thread'den erişilir — kilit gerekmez.
///
/// İki ayrı liste tutulur:
/// - ekranda: yalnızca AKTİF Space'teki pencereler (`.optionOnScreenOnly`).
/// - tümü: her Space'teki tüm pencereler (`[]`). Bu liste yalnızca bir uygulama
///   penceresiz görününce (park kontrolü) sorgulanır — boştayken hiç çağrılmaz.
private enum WindowServerCache {
    private static let ttl: TimeInterval = 0.5

    private static var onScreenByPID: [pid_t: Set<CGWindowID>] = [:]
    private static var onScreenAt: TimeInterval = -1

    private static var allIDs: Set<CGWindowID> = []
    private static var allAt: TimeInterval = -1

    /// Verilen uygulamanın AKTİF Space'te ekranda olan (layer 0) pencerelerinin
    /// CG numaraları.
    static func onScreenWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let now = ProcessInfo.processInfo.systemUptime
        if onScreenAt < 0 || now - onScreenAt > ttl {
            onScreenAt = now
            onScreenByPID = captureOnScreen()
        }
        return onScreenByPID[pid] ?? []
    }

    /// Sistemdeki TÜM Space'lerde var olan (layer 0) pencerelerin CG numaraları.
    static func allWindowIDs() -> Set<CGWindowID> {
        let now = ProcessInfo.processInfo.systemUptime
        if allAt < 0 || now - allAt > ttl {
            allAt = now
            allIDs = captureAll()
        }
        return allIDs
    }

    private static func captureOnScreen() -> [pid_t: Set<CGWindowID>] {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var result: [pid_t: Set<CGWindowID>] = [:]
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let owner = window[kCGWindowOwnerPID as String] as? Int,
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            result[pid_t(owner), default: []].insert(CGWindowID(number))
        }
        return result
    }

    private static func captureAll() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var result: Set<CGWindowID> = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            result.insert(CGWindowID(number))
        }
        return result
    }
}
