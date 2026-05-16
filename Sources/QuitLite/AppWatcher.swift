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
        var result: [AXUIElement] = []
        for window in windows {
            // Herhangi bir pencerenin alt-rolü SORGULANAMAZSA (örn. izin tam bu
            // sırada geri alındı) durum belirsizdir → nil dön. Aksi halde sorgu
            // hataları "0 standart pencere" sanılıp uygulama yanlışlıkla kapatılır.
            guard let standard = isStandardWindow(window) else { return nil }
            if standard { result.append(window) }
        }
        return result
    }

    /// true = standart pencere, false = değil, nil = alt-rol sorgulanamadı (AX hatası).
    private func isStandardWindow(_ window: AXUIElement) -> Bool? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString,
                                            &roleValue) == .success else { return nil }
        guard let subrole = roleValue as? String else { return false }
        return subrole == (kAXStandardWindowSubrole as String)
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
