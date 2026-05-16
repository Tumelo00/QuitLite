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
