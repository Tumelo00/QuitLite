import AppKit

/// Son pencere kapandığında uygulamayı kapatmaktan sorumlu.
///
/// Doğrudan kapatmaz — bir gecikme (debounce) uygular. Gecikme dolduğunda
/// pencere sayısını YENİDEN doğrular; bu arada pencere açıldıysa kapatmayı iptal eder.
/// Bu, splash ekranı veya pencereler arası geçiş sırasında yanlış kapatmayı önler.
final class QuitController {

    private var pending: [pid_t: DispatchWorkItem] = [:]

    /// İlk doğrulama "0 pencere" derse, kapatmadan önce kısa bir süre sonra
    /// ikinci kez doğrulanır. Yeni belge açma, tam ekrana geçiş gibi durumlarda
    /// uygulama bir an "0 pencere" raporlar; bu çift doğrulama o anlık boşlukları
    /// eler. Gecikme "Anında" (0 sn) seçilse bile yanlış kapatma önlenir.
    private let recheckInterval: TimeInterval = 0.4

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
        guard pending[pid] == nil, !quitRequested.contains(pid) else { return }

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
        // nil = AX durumu belirsiz → güvenli tarafta kal, kapatma.
        guard let windows = watcher.standardWindows(), windows.isEmpty else { return }

        let pid = watcher.pid
        let recheck = DispatchWorkItem { [weak self, weak watcher] in
            guard let self, let watcher else { return }
            self.pending[watcher.pid] = nil
            guard !watcher.app.isTerminated else { return }
            // İkinci (son) doğrulama: hâlâ kesin olarak 0 pencere mi?
            guard let windows = watcher.standardWindows(), windows.isEmpty else { return }
            self.quitRequested.insert(watcher.pid)
            watcher.app.terminate()
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
