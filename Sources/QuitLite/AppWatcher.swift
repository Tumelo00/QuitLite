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
        // Yanıt vermeyen bir uygulama çekirdeğin ana thread'ini kilitlemesin diye
        // AX çağrılarına üst zaman sınırı koy.
        AXUIElementSetMessagingTimeout(axApp, 1.0)
    }

    func start() {
        // İki kez başlatılırsa ikinci observer sızar; zaten çalışıyorsa çık.
        guard observer == nil else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &obs) == .success, let obs else { return }
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

    /// Uygulamanın o anki "standart" pencerelerini döndürür.
    /// Sheet, popover, panel, palette gibi yardımcı pencereler sayılmaz.
    /// Minimize edilmiş pencereler hâlâ AX listesinde olduğundan açık sayılır.
    ///
    /// AX çağrısı başarısız olursa (uygulama yanıt vermiyor, izin yok vb.) `nil`
    /// döner — bu "durum bilinmiyor" demektir ve "0 pencere" ile karıştırılmamalıdır.
    /// Aksi halde yanıt vermeyen bir uygulama yanlışlıkla kapatılabilir.
    func standardWindows() -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.filter { isStandardWindow($0) }
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &roleValue) == .success,
              let subrole = roleValue as? String else { return false }
        return subrole == (kAXStandardWindowSubrole as String)
    }

    /// Mevcut tüm pencerelere "yok edildi" bildirimi kaydeder.
    /// Aynı pencereye tekrar kayıt zararsızdır (alreadyRegistered döner).
    private func registerDestroyObservers() {
        guard let obs = observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in (standardWindows() ?? []) {
            AXObserverAddNotification(obs, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }
    }

    /// Pencere sayısını yeniden hesaplar ve uygun callback'i tetikler.
    func evaluate() {
        guard !app.isTerminated else { return }
        // nil = pencere durumu belirlenemedi (AX hatası) → hiçbir şey yapma.
        guard let windows = standardWindows() else { return }
        if !windows.isEmpty {
            hadWindow = true
            onWindowAppeared?(self)
        } else if hadWindow {
            onWindowsEmptied?(self)
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
