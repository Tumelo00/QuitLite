import AppKit

/// Çekirdek koordinatör: çalışan uygulamaları izler, her biri için bir AppWatcher
/// kurar/söker ve pencere boşaldığında QuitController'a haber verir.
final class WindowMonitor {

    private var watchers: [pid_t: AppWatcher] = [:]
    private let quitController = QuitController()
    private var sweepTimer: Timer?
    private var running = false
    private var sweepCount = 0

    /// AX callback'leri kaçırılırsa diye düşük frekanslı emniyet taraması.
    /// Olağan durumda kapatma anında AX observer ile algılanır; tarama yalnızca
    /// kaçırılan olaylar için yedektir. Geniş tolerans ile macOS bu zamanlayıcıyı
    /// başka uyanmalara denk getirip birleştirir → şarj tüketimi en aza iner.
    private let sweepInterval: TimeInterval = 10.0

    func start() {
        guard !running else { return }
        running = true

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appLaunched(_:)),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            addWatcher(for: app)
        }

        let timer = Timer(timeInterval: sweepInterval, target: self,
                          selector: #selector(sweep), userInfo: nil, repeats: true)
        timer.tolerance = sweepInterval / 2
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    func stop() {
        guard running else { return }
        running = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        sweepTimer?.invalidate()
        sweepTimer = nil
        quitController.cancelAll()
        watchers.values.forEach { $0.stop() }
        watchers.removeAll()
    }

    // MARK: - Watcher yaşam döngüsü

    private func addWatcher(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, watchers[pid] == nil else { return }
        guard let watcher = AppWatcher(app: app) else { return }
        guard watcher.bundleID != kGUIBundleID else { return }

        watcher.onWindowsEmptied = { [weak self] watcher in
            self?.handleWindowsEmptied(watcher)
        }
        watcher.onWindowAppeared = { [weak self] watcher in
            self?.quitController.cancelQuit(pid: watcher.pid)
        }
        watchers[pid] = watcher
        watcher.start()
    }

    private func removeWatcher(pid: pid_t) {
        quitController.cancelQuit(pid: pid)
        watchers[pid]?.stop()
        watchers[pid] = nil
    }

    private func handleWindowsEmptied(_ watcher: AppWatcher) {
        guard Preferences.shared.shouldManage(bundleID: watcher.bundleID) else { return }
        quitController.scheduleQuit(for: watcher, delay: Preferences.shared.quitDelay)
    }

    // MARK: - NSWorkspace bildirimleri

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        addWatcher(for: app)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // pid işletim sistemi tarafından yeniden kullanılmış olabilir ve
        // launch/terminate bildirimleri sıra dışı gelebilir: yalnızca kayıtlı
        // watcher gerçekten BU uygulamaya aitse kaldır. Yanlış pozitifte watcher
        // kalsa bile emniyet taraması isTerminated kontrolüyle onu temizler.
        guard watchers[app.processIdentifier]?.app == app else { return }
        removeWatcher(pid: app.processIdentifier)
    }

    /// Emniyet taraması: kaçırılmış AX callback'lerini yakalamak için tüm
    /// izlenen uygulamaların pencere sayısını yeniden değerlendirir.
    @objc private func sweep() {
        sweepCount &+= 1
        // Olağan taramalarda yalnızca penceresi olmuş (= kapatılabilir) uygulamalar
        // AX ile taranır; pencere açmamış uygulamalar zaten kapatılamaz. Ancak her
        // 6 taramada bir (~60 sn) onlar da taranır: bir uygulamanın ilk penceresi
        // için üç AX bildirimi birden kaçırılsa bile durum yine de yakalanır.
        let fullSweep = sweepCount % 6 == 0
        // watchers, removeWatcher tarafından değiştirilebileceği için kopya üzerinde gez.
        for watcher in Array(watchers.values) {
            // isTerminated ucuz bir özellik okumasıdır; sonlanmış uygulamaları
            // (kaçırılmış terminate bildirimi yedeği olarak) her zaman temizle.
            if watcher.app.isTerminated {
                removeWatcher(pid: watcher.pid)
                continue
            }
            // Pahalı kısım evaluate()'in AX pencere taramasıdır.
            // Her uygulama için ayrı autoreleasepool: AX'in ürettiği geçici
            // nesneler tek tek serbest kalır, tepe bellek kullanımı düşük kalır.
            if watcher.hadWindow || fullSweep {
                autoreleasepool { watcher.evaluate() }
            }
        }
    }
}
