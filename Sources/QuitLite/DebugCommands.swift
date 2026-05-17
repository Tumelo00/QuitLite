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

    /// Çalışan tüm .regular uygulamaların AX pencere ağacını döker — Electron
    /// (Discord vb.) uygulamalarının pencere algılama sorunlarını teşhis için.
    /// Raporu hem stdout'a basar hem /tmp/quitlite-diagnose.txt dosyasına yazar
    /// (SSH'tan sistem günlüğü okunamadığında dosya güvenilir kanaldır).
    static func diagnose() {
        var r = "QuitLite \(version) — AX pencere teşhis raporu\n"
        r += "AX izni: \(AXIsProcessTrusted() ? "verildi" : "YOK")\n"
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        r += "Çalışan .regular uygulama sayısı: \(apps.count)\n\n"
        for app in apps {
            guard let bid = app.bundleIdentifier else { continue }
            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 1.0)
            var winValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &winValue)
            let windows = (winValue as? [AXUIElement]) ?? []
            r += "▸ \(bid)  pid=\(pid)  "
            r += "shouldManage=\(Preferences.shared.shouldManage(bundleID: bid))\n"
            r += "   AX windows: status=\(status.rawValue) count=\(windows.count)\n"
            for (i, window) in windows.enumerated() {
                r += "   [\(i)] \(describeWindow(window))\n"
            }
            if windows.isEmpty { r += "   (AX pencere listesi boş)\n" }
            r += "\n"
        }
        let path = "/tmp/quitlite-diagnose.txt"
        try? r.write(toFile: path, atomically: true, encoding: .utf8)
        print(r)
        print("Rapor kaydedildi: \(path)")
    }

    /// Tek bir AX pencere öğesinin rol/alt-rol/minimize/başlık özetini verir.
    private static func describeWindow(_ window: AXUIElement) -> String {
        func string(_ attr: String) -> String {
            var value: CFTypeRef?
            let st = AXUIElementCopyAttributeValue(window, attr as CFString, &value)
            if st != .success { return "<hata \(st.rawValue)>" }
            return (value as? String) ?? "<string-değil>"
        }
        func flag(_ attr: String) -> String {
            var value: CFTypeRef?
            let st = AXUIElementCopyAttributeValue(window, attr as CFString, &value)
            if st != .success { return "<hata \(st.rawValue)>" }
            return ((value as? Bool) ?? false) ? "evet" : "hayır"
        }
        let role = string(kAXRoleAttribute as String)
        let subrole = string(kAXSubroleAttribute as String)
        let title = string(kAXTitleAttribute as String)
        let minimized = flag(kAXMinimizedAttribute as String)
        return "role=\(role) subrole=\(subrole) minimized=\(minimized) title=\"\(title)\""
    }
}
