import AppKit

/// Ayar penceresi uygulamasının delegesi.
/// Menü çubuğu simgesi yoktur; tek işi ayar penceresini göstermektir.
/// Pencere kapanınca süreç sonlanır — arka planda yalnızca ~2 MB'lik çekirdek kalır.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Çekirdek kaydını eşitle. Zaten doğru kuruluysa çalışan çekirdeğe
        // dokunulmaz — gereksiz yeniden başlatma (ve bekleyen kapatmaların
        // kaybı) önlenir. Kullanıcı "girişte başlat"ı bilerek kapattıysa
        // (kayıt yok ama daha önce kurulmuş) ilk kurulum yapılmaz.
        if CoreAgent.synchronize(allowFirstInstall: !Preferences.shared.didInstall) {
            Preferences.shared.didInstall = true
        }
        openSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    /// Ayar penceresi kapanınca GUI süreci sonlansın — arka planda yalnızca
    /// çekirdek kalır. AppKit'in kendi temiz kapanış yolu kullanılır.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }
}
