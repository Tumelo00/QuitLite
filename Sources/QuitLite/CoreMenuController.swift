import AppKit

/// Çekirdek "menü çubuğu simgesi" modunda çalışırken durum çubuğu öğesini yönetir.
/// Yalnızca kullanıcı ayarlardan bu seçeneği açtığında oluşturulur — kapalıyken
/// çekirdek NSApplication'ı hiç yüklemez ve hafif modda kalır.
final class CoreMenuController: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "QuitLite")
        icon?.isTemplate = true
        item.button?.image = icon
        item.button?.toolTip = "QuitLite"

        let menu = NSMenu()
        menu.addItem(withTitle: "QuitLite çalışıyor", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ayarları Aç…", action: #selector(openSettings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "QuitLite'tan Çık", action: #selector(quitQuitLite), keyEquivalent: "")
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
    }

    /// Ayar penceresini açar. .app zaten (çekirdek olarak) çalıştığından sıradan
    /// `NSWorkspace.open` YENİ bir süreç başlatmaz — yalnızca penceresiz çekirdeği
    /// etkinleştirir ve hiçbir şey görünmez. `createsNewApplicationInstance` ile
    /// ayrı bir süreç başlatılır; argümansız açıldığı için ayar penceresi moduna girer.
    @objc private func openSettings() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: config,
                                           completionHandler: nil)
    }

    /// QuitLite'ı tamamen durdurur. LaunchAgent kaydı kaldırılmazsa KeepAlive=true
    /// olduğu için launchd çekirdeği hemen yeniden başlatır; bu yüzden önce kayıt
    /// kaldırılır (bootout çalışan süreci de sonlandırır).
    @objc private func quitQuitLite() {
        CoreAgent.unregister()
        NSApp.terminate(nil)
    }
}
