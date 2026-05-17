import Foundation
import ApplicationServices

/// Arka plan çekirdeğinin yaşam döngüsünü yönetir:
/// Erişilebilirlik iznini izler, izin varken WindowMonitor'ü çalıştırır,
/// izin durumunu paylaşılan ayarlara yazar (GUI bunu okuyup gösterir).
final class CoreController {

    private let monitor = WindowMonitor()
    private var monitoring = false

    /// App Nap'i kapatan etkinlik bildiriminin tokenı. Süreç boyunca tutulur
    /// (asla endActivity çağrılmaz); serbest bırakılırsa App Nap geri gelir.
    private var activityToken: NSObjectProtocol?

    func start() {
        // App Nap'i devre dışı bırak: menü çubuğu modunda çekirdek görünür
        // penceresi olmayan bir NSApplication'dır ve App Nap onu askıya alıp
        // pencere izlemeyi saatlerce durdurabilir. ...AllowingIdleSystemSleep
        // seçeneği sistemin normal uyumasını ENGELLEMEZ (uykudayken kapanacak
        // pencere zaten yoktur; uyanışta izleme kaldığı yerden sürer).
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "QuitLite pencere izleme")
        // İlk açılışta sistemin izin penceresini göster.
        _ = axTrusted(prompt: true)
        tick()
        scheduleNextCheck()

        // GUI ayar değiştirip diske yazınca bir Darwin bildirimi gönderir.
        // Çekirdek burada dinler ve ayarları CANLI yükler — yeniden başlatma yok,
        // yoklama (polling) yok. Tek observer; CoreController gibi süreç ömrü
        // boyunca yaşadığından kaldırılması gerekmez (passUnretained güvenli).
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            corePrefsChangedCallback,
            kPrefsChangedNotification as CFString,
            nil,
            .deliverImmediately)
    }

    /// GUI'den "ayarlar değişti" Darwin bildirimi gelince çağrılır (ana thread:
    /// Darwin callback'leri kaydı yapan thread'in run loop'unda teslim edilir).
    /// Ayarları diskten tazeler ve izlenen uygulamaları bir kez yeniden
    /// değerlendirir; yeni nesne, zamanlayıcı ya da kalıcı durum oluşturmaz.
    func reloadPreferences() {
        Preferences.shared.refresh()
        if kDebugMode { NSLog("QuitLite[reload] ayarlar canlı yüklendi") }
        monitor.preferencesChanged()
    }

    /// İzin yoklamasını kendi kendine yeniden zamanlar.
    /// İzin verilene kadar sık (3 sn), verildikten sonra çok seyrek (300 sn) yoklar.
    /// İzin verildikten sonra yoklama yalnızca iznin GERİ ALINMASINI yakalamak
    /// içindir (izin yokken AX çağrıları zaten güvenli biçimde başarısız olur),
    /// bu yüzden seyrek olması yeterli — çekirdeğin uyanma sayısı en aza iner.
    private func scheduleNextCheck() {
        let interval: TimeInterval = monitoring ? 300.0 : 3.0
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            self?.tick()
            self?.scheduleNextCheck()
        }
        timer.tolerance = interval * 0.5
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let trusted = axTrusted(prompt: false)
        if trusted && !monitoring {
            monitor.start()
            monitoring = true
        } else if !trusted && monitoring {
            monitor.stop()
            monitoring = false
        }
    }

    private func axTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}

/// Darwin bildirimi C callback'i — bağlam yakalayamaz; observer pointer ile
/// canlı CoreController'a köprülenir (AppWatcher'daki AXObserver kalıbının aynısı).
private func corePrefsChangedCallback(_ center: CFNotificationCenter?,
                                      _ observer: UnsafeMutableRawPointer?,
                                      _ name: CFNotificationName?,
                                      _ object: UnsafeRawPointer?,
                                      _ userInfo: CFDictionary?) {
    guard let observer else { return }
    Unmanaged<CoreController>.fromOpaque(observer).takeUnretainedValue().reloadPreferences()
}
