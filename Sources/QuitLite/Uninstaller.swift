import AppKit

/// QuitLite'a ait HER ŞEYİ sistemden kaldırır — kullanıcının sisteminde iz
/// bırakmamak için. Hem ayar penceresindeki "Kaldır" düğmesi hem de
/// `--uninstall` komutu aynı bu mantığı çağırır.
enum Uninstaller {

    /// Kaldırma adımlarını uygular ve yapılan işlerin insan-okur özetini döndürür.
    @discardableResult
    static func run() -> [String] {
        var done: [String] = []

        // 1. Arka plan çekirdeğini durdur + LaunchAgent kaydını sil.
        CoreAgent.unregister()
        done.append("Arka plan çekirdeği durduruldu, açılıştan kaldırıldı")

        // 2. Paylaşılan ve standart ayar alanlarını sil. `defaults delete`
        //    cfprefsd'ye alanı unutturur — yalnızca plist dosyasını silmek
        //    yetmez, cfprefsd önbellekten yeniden yazabilir.
        for domain in [kPrefsSuiteName, kGUIBundleID] {
            runTool("/usr/bin/defaults", ["delete", domain])
        }
        done.append("Tüm ayarlar silindi")

        // 3. Önbellek, kaydedilmiş pencere durumu, HTTP deposu, artık plist'ler.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let leftovers = [
            "Library/Preferences/\(kPrefsSuiteName).plist",
            "Library/Preferences/\(kGUIBundleID).plist",
            "Library/Caches/\(kGUIBundleID)",
            "Library/HTTPStorages/\(kGUIBundleID)",
            "Library/Saved Application State/\(kGUIBundleID).savedState"
        ]
        for rel in leftovers {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(rel))
        }
        done.append("Önbellek ve kaydedilmiş durum silindi")

        // 4. Erişilebilirlik (TCC) izni kaydını sıfırla.
        runTool("/usr/bin/tccutil", ["reset", "Accessibility", kGUIBundleID])
        done.append("Erişilebilirlik izni kaydı sıfırlandı")

        // 5. QuitLite.app'i Çöp'e taşı. Çalışan süreç, paketi taşınsa da
        //    bellekteki sayfalarla çıkışa kadar yaşar.
        if (try? FileManager.default.trashItem(at: Bundle.main.bundleURL,
                                               resultingItemURL: nil)) != nil {
            done.append("QuitLite.app Çöp'e taşındı")
        } else {
            done.append("QuitLite.app taşınamadı — Çöp'e elle sürükleyin")
        }
        return done
    }

    /// Küçük bir komut satırı aracını sessizce çalıştırır (çıkışı yutar).
    private static func runTool(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Araç yoksa/çalışmazsa kaldırmanın geri kalanını sürdür.
        }
    }
}
