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
        var r = "QuitLite \(version) — AX + CG pencere teşhis raporu\n"
        r += "AX izni: \(AXIsProcessTrusted() ? "verildi" : "YOK")\n"
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        r += "Çalışan .regular uygulama sayısı: \(apps.count)\n\n"
        // CoreGraphics pencere listeleri (sistem geneli) bir kez alınır.
        // [] (boş seçenek) = TÜM pencereler (ekran dışı / başka Space dahil);
        // .optionOnScreenOnly = yalnızca o an ekranda görünenler.
        let cgAll = (CGWindowListCopyWindowInfo([], kCGNullWindowID)
                     as? [[String: Any]]) ?? []
        let cgScreen = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                        as? [[String: Any]]) ?? []
        for app in apps {
            guard let bid = app.bundleIdentifier else { continue }
            let pid = Int(app.processIdentifier)
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 1.0)
            var winValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &winValue)
            let windows = (winValue as? [AXUIElement]) ?? []
            r += "▸ \(bid)  pid=\(pid)  "
            r += "shouldManage=\(Preferences.shared.shouldManage(bundleID: bid))\n"
            r += "   AX windows: status=\(status.rawValue) count=\(windows.count)\n"
            for (i, window) in windows.enumerated() {
                r += "   AX[\(i)] \(describeWindow(window))\n"
            }
            let mine = cgAll.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
            let mineScreen = cgScreen.filter {
                ($0[kCGWindowOwnerPID as String] as? Int) == pid
            }
            r += "   CG windows: tüm=\(mine.count) ekranda=\(mineScreen.count)\n"
            for (i, w) in mine.enumerated() {
                let layer = w[kCGWindowLayer as String] as? Int ?? -999
                let num = w[kCGWindowNumber as String] as? Int ?? -1
                let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
                let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
                r += "   CG[\(i)] num=\(num) layer=\(layer) "
                r += "onscreen=\(onscreen) alpha=\(alpha)\n"
            }
            r += "\n"
        }
        let path = "/tmp/quitlite-diagnose.txt"
        try? r.write(toFile: path, atomically: true, encoding: .utf8)
        print(r)
        print("Rapor kaydedildi: \(path)")
    }

    /// Tek bir AX pencere öğesinin özetini verir: rol, alt-rol, minimize,
    /// konum, boyut, başlık.
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
        func geom(_ attr: String, _ type: AXValueType) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attr as CFString, &value) == .success,
                  let v = value, CFGetTypeID(v) == AXValueGetTypeID() else { return "?" }
            let axv = v as! AXValue
            if type == .cgPoint {
                var p = CGPoint.zero
                if AXValueGetValue(axv, .cgPoint, &p) {
                    return "(\(Int(p.x)),\(Int(p.y)))"
                }
            } else {
                var s = CGSize.zero
                if AXValueGetValue(axv, .cgSize, &s) {
                    return "(\(Int(s.width))x\(Int(s.height)))"
                }
            }
            return "?"
        }
        let role = string(kAXRoleAttribute as String)
        let subrole = string(kAXSubroleAttribute as String)
        let title = string(kAXTitleAttribute as String)
        let minimized = flag(kAXMinimizedAttribute as String)
        let fullscreen = flag("AXFullScreen")
        let pos = geom(kAXPositionAttribute as String, .cgPoint)
        let size = geom(kAXSizeAttribute as String, .cgSize)
        return "role=\(role) subrole=\(subrole) minimized=\(minimized) "
            + "fullscreen=\(fullscreen) pos=\(pos) size=\(size) title=\"\(title)\""
    }
}
