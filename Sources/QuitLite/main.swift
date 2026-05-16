import AppKit

// QuitLite tek bir binary'dir, iki modda çalışır:
//   --core       → arka plan çekirdeği. NSApplication oluşturulmaz; menü çubuğu,
//                  pencere, dock yok. Yalnızca pencere izleme + kapatma. ~2 MB.
//   (varsayılan) → ayar penceresi. Talep üzerine çalışır, pencere kapanınca sonlanır.
//
// İki mod aynı binary olduğu için tek bir Erişilebilirlik (TCC) kimliği paylaşır.
// Süreç boyunca canlı kalmaları gereken nesneler global tutulur: app.delegate
// zayıf (weak) bir referanstır; çekirdek ve zamanlayıcılar da güçlü bir sahip ister.
var coreController: CoreController?
var coreMenuController: CoreMenuController?
var appDelegate: AppDelegate?

if CommandLine.arguments.contains("--core") {
    let core = CoreController()
    coreController = core
    core.start()
    if Preferences.shared.showMenuBarIcon {
        // Kullanıcı menü çubuğu simgesi istedi → NSApplication gerekir (~10 MB).
        // Ayar değişince çekirdek yeniden başlatılır (CoreAgent.restart), bu yüzden
        // mod kararı her açılışta yeniden verilir.
        let app = NSApplication.shared
        coreMenuController = CoreMenuController()
        app.delegate = coreMenuController
        app.setActivationPolicy(.accessory)
        app.run()
    } else {
        // Hafif mod: NSApplication hiç yüklenmez (~2,3 MB).
        RunLoop.main.run()
    }
} else {
    let app = NSApplication.shared
    appDelegate = AppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
