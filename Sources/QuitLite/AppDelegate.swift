import AppKit

/// Ayar penceresi uygulamasının delegesi.
/// Menü çubuğu simgesi yoktur; tek işi ayar penceresini göstermektir.
/// Pencere kapanınca süreç sonlanır — arka planda yalnızca ~3 MB'lik çekirdek kalır.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Çekirdek kaydını eşitle. Zaten doğru kuruluysa çalışan çekirdeğe
        // dokunulmaz — gereksiz yeniden başlatma (ve bekleyen kapatmaların
        // kaybı) önlenir. Çekirdek kurulu değilse kurar; yalnızca kullanıcı
        // "Girişte başlat"ı bilerek kapattıysa kurmaz. Böylece uygulama silinip
        // yeniden kurulduğunda çekirdek yine otomatik kurulur.
        CoreAgent.synchronize(allowFirstInstall: !Preferences.shared.userDisabledAgent)
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
