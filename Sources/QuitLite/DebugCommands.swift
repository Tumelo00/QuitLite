import AppKit
import ApplicationServices

/// Tek seferlik tanı komutları (`--dump-state`, `--self-test`, `--dry-run`).
/// Hepsi yazdırıp çıkar; yerleşik çekirdekte kod yolu ya da durum bırakmaz —
/// boşta RAM/CPU/uyanma etkisi sıfırdır. Terminal'den çalıştırılır:
///   /Applications/QuitLite.app/Contents/MacOS/QuitLite --dump-state
enum DebugCommands {

    private static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// Mevcut yapılandırmayı özetler. Çalışan çekirdek AYRI bir süreç olduğundan
    /// onun watcher/pending sayıları buradan görünmez — yalnızca bu bilgi için
    /// IPC eklemek (XPC vb.) ağır olur; bilinçli olarak gösterilmez.
    static func dumpState() {
        let p = Preferences.shared
        print("QuitLite \(version) — durum dökümü")
        print("  enabled        : \(p.enabled ? "evet" : "hayır")")
        print("  mode           : \(p.mode == .allApps ? "tüm uygulamalar" : "yalnızca whitelist")")
        print("  blacklist      : \(p.blacklist.count) giriş")
        print("  whitelist      : \(p.whitelist.count) giriş")
        print("  quitDelay      : \(p.quitDelay) sn")
        print("  showMenuBarIcon: \(p.showMenuBarIcon ? "evet" : "hayır")")
        print("  AX izni        : \(AXIsProcessTrusted() ? "verildi" : "YOK")")
        print("  LaunchAgent    : \(CoreAgent.isRegistered ? "kayıtlı" : "kayıtlı değil")")
        print("  /Applications  : \(CoreAgent.isInApplicationsFolder ? "evet" : "HAYIR")")
    }

    /// Temel sağlık kontrolleri. Yapısal kontroller geçerse 0 (true) döner;
    /// AX/LaunchAgent yalnızca bilgi amaçlı raporlanır (ortama bağlıdır).
    static func selfTest() -> Bool {
        print("QuitLite \(version) — kendi kendine test")
        let prefsOK = UserDefaults(suiteName: kPrefsSuiteName) != nil
        let normOK = Preferences.normalized("  COM.HNC.Discord ") == "com.hnc.discord"
        print("  ayarlar okunabilir : \(prefsOK ? "GEÇTİ" : "KALDI")")
        print("  ID normalleştirme  : \(normOK ? "GEÇTİ" : "KALDI")")
        print("  AX izni            : \(AXIsProcessTrusted() ? "verildi" : "yok (bilgi)")")
        print("  LaunchAgent        : \(CoreAgent.isRegistered ? "kayıtlı" : "kayıtlı değil (bilgi)")")
        let ok = prefsOK && normOK
        print(ok ? "Sonuç: yapısal kontroller geçti." : "Sonuç: BAŞARISIZ.")
        return ok
    }

    /// Hangi uygulamaların yönetileceğini hiçbir şeyi kapatmadan listeler.
    /// `terminate()` asla çağrılmaz.
    static func dryRun() {
        print("QuitLite \(version) — dry-run (hiçbir uygulama kapatılmaz)")
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        for app in apps {
            guard let bid = app.bundleIdentifier else { continue }
            let manage = Preferences.shared.shouldManage(bundleID: bid)
            print("  \(manage ? "[yönetilir]" : "[atlanır]  ") \(bid)")
        }
    }
}
