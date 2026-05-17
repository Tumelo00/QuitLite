import AppKit

/// Son pencere kapandığında uygulamayı kapatmaktan sorumlu.
///
/// Doğrudan kapatmaz — bir gecikme (debounce) uygular. Gecikme dolduğunda
/// pencere sayısını YENİDEN doğrular; bu arada pencere açıldıysa kapatmayı iptal eder.
/// Bu, splash ekranı veya pencereler arası geçiş sırasında yanlış kapatmayı önler.
final class QuitController {

    private var pending: [pid_t: DispatchWorkItem] = [:]

    /// İlk doğrulama "0 pencere" derse, kapatmadan önce bu süre kadar beklenip
    /// ikinci kez doğrulanır. Yeni belge açma, tam ekrana/Space geçişi gibi
    /// durumlarda uygulama bir an "0 pencere" raporlar; bu çift doğrulama o anlık
    /// boşlukları eler. 1 sn, tam ekran animasyonu (~0,5-0,7 sn) gibi en uzun
    /// geçişleri de kapsar — gecikme "Anında" seçilse bile yanlış kapatma önlenir.
    private let recheckInterval: TimeInterval = 1.0

    /// Kapatma isteği gönderilmiş pid'ler. Aynı uygulamaya tekrar tekrar
    /// `terminate()` çağrılmasını önler — örn. uygulama "Kaydedilsin mi?"
    /// diyaloğu gösterip beklerken her tarama turunda yeniden tetiklenmemesi için.
    /// Uygulama yeniden pencere açınca (cancelQuit) ya da kapanınca temizlenir.
    private var quitRequested: Set<pid_t> = []

    func scheduleQuit(for watcher: AppWatcher, delay: TimeInterval) {
        let pid = watcher.pid
        // Zaten bekleyen ya da kapatma isteği gönderilmiş bir uygulamayı
        // yeniden zamanlama — aksi halde tekrarlayan tetiklemeler debounce
        // sayacını sürekli sıfırlar ve uygulama hiç kapanmaz.
        guard pending[pid] == nil, !quitRequested.contains(pid) else {
            if kDebugMode {
                NSLog("QuitLite[quit] \(watcher.bundleID): scheduleQuit atlandı "
                    + "(pending=\(pending[pid] != nil) quitRequested=\(quitRequested.contains(pid)))")
            }
            return
        }
        if kDebugMode {
            NSLog("QuitLite[quit] \(watcher.bundleID): kapatma zamanlandı (gecikme \(max(0, delay))s)")
        }

        let work = DispatchWorkItem { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.pending[watcher.pid] = nil
            self.confirmAndQuit(watcher)
        }

        pending[pid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    /// İlk doğrulama: pencere kesin olarak 0 mı? Öyleyse kapatmayı hemen yapmaz —
    /// kısa bir aradan sonra ikinci kez doğrular. İki doğrulama da "0 pencere"
    /// derse uygulama kapatılır; arada pencere açılırsa (onWindowAppeared →
    /// cancelQuit) ikinci doğrulama iptal edilir.
    private func confirmAndQuit(_ watcher: AppWatcher) {
        guard !watcher.app.isTerminated else { return }
        // isWindowless: true = kesin penceresiz; false = penceresi var;
        // nil = AX durumu belirsiz. true değilse kapatma iptal.
        guard watcher.isWindowless() == true else {
            if kDebugMode {
                NSLog("QuitLite[quit] \(watcher.bundleID): 1. doğrulama başarısız → kapatma iptal")
            }
            return
        }

        let pid = watcher.pid
        let recheck = DispatchWorkItem { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.pending[watcher.pid] = nil
            guard !watcher.app.isTerminated else { return }
            // İkinci (son) doğrulama: hâlâ kesin olarak penceresiz mi?
            guard watcher.isWindowless() == true else {
                if kDebugMode {
                    NSLog("QuitLite[quit] \(watcher.bundleID): 2. doğrulama başarısız → iptal")
                }
                return
            }
            // Bekleme sırasında uygulama menü çubuğu moduna geçmiş olabilir.
            guard watcher.app.activationPolicy == .regular else { return }
            // Bekleme sırasında uygulama kara listeye alınmış ya da otomatik
            // kapatma kapatılmış olabilir — son anda yeniden denetle.
            guard Preferences.shared.shouldManage(bundleID: watcher.bundleID) else { return }
            // quitRequested'a yalnızca kapatma isteği BAŞARIYLA gönderilirse ekle.
            // terminate() false dönerse istek gitmemiştir; pid'i işaretlersek
            // uygulama bir daha hiç kapatılamaz — bu yüzden yalnızca başarıda işaretle.
            let terminated = watcher.app.terminate()
            if kDebugMode {
                NSLog("QuitLite[quit] \(watcher.bundleID): terminate() denendi → \(terminated)")
            }
            if terminated {
                self.quitRequested.insert(watcher.pid)
            }
        }
        // pending[pid] daima o an bekleyen iş öğesini gösterir; böylece
        // cancelQuit her iki aşamayı da iptal edebilir.
        pending[pid] = recheck
        DispatchQueue.main.asyncAfter(deadline: .now() + recheckInterval, execute: recheck)
    }

    func cancelQuit(pid: pid_t) {
        pending[pid]?.cancel()
        pending[pid] = nil
        quitRequested.remove(pid)
    }

    func cancelAll() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        quitRequested.removeAll()
    }
}
