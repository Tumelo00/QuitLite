import Foundation

/// Arka plan çekirdeğini (QuitLiteCore) launchd üzerinden yöneten LaunchAgent
/// sarmalayıcısı.
///
/// SMAppService yerine klasik `~/Library/LaunchAgents` + `launchctl` yöntemi
/// kullanılır: SMAppService geçerli bir Developer ID imzası ister; QuitLite ise
/// açık kaynak ve ad-hoc imzalıdır. Manuel LaunchAgent imza gerektirmez.
enum CoreAgent {

    private static let label = "com.tumerustunel.QuitLite.Core"

    /// LaunchAgent plist'inin yazıldığı yol. Buradaki plist'ler her girişte
    /// launchd tarafından otomatik yüklenir.
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// .app paketi içindeki binary'nin mutlak yolu. Çekirdek modu için
    /// bu binary "--core" argümanıyla çalıştırılır (tek binary, iki mod).
    private static var mainBinaryPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/QuitLite"
    }

    static var isRegistered: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Kayıtlı LaunchAgent plist'inde yazılı olan binary yolu (kayıt yoksa nil).
    private static var installedBinaryPath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any],
              let args = dict["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    /// Çekirdek kaydını mevcut duruma göre eşitler — çalışan çekirdeği gereksiz
    /// yere durdurup yeniden başlatmadan:
    /// - Kayıt yok + ilk kuruluma izin var → kaydet.
    /// - Kayıt var ama uygulama taşınmış (yol değişmiş) → yeniden kaydet.
    /// - Kayıt var ve yol doğru → DOKUNMA (bekleyen kapatmalar korunur).
    /// Geriye çekirdeğin kurulu olup olmadığını döner.
    @discardableResult
    static func synchronize(allowFirstInstall: Bool) -> Bool {
        if isRegistered {
            if installedBinaryPath != mainBinaryPath {
                register()
            }
            return true
        }
        if allowFirstInstall {
            register()
            return true
        }
        return false
    }

    @discardableResult
    static func register() -> Bool {
        let binary = mainBinaryPath
        guard FileManager.default.fileExists(atPath: binary) else {
            NSLog("QuitLite: binary bulunamadı: \(binary)")
            return false
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary, "--core"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            // Nadir disk yazımları (UserDefaults) ön plandaki I/O ile yarışmasın.
            "LowPriorityBackgroundIO": true,
            // Giriş Öğeleri arayüzünde ajanı uygulamayla grupla (macOS 13+).
            "AssociatedBundleIdentifiers": kGUIBundleID
        ]
        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            NSLog("QuitLite: LaunchAgent plist yazılamadı — \(error.localizedDescription)")
            return false
        }

        let domain = "gui/\(getuid())"
        // Olası eski kaydı temizle (uygulamanın yolu değişmiş olabilir), sonra yükle.
        _ = runLaunchctl(["bootout", domain, plistURL.path])
        return runLaunchctl(["bootstrap", domain, plistURL.path])
    }

    @discardableResult
    static func unregister() -> Bool {
        // Plist'i ÖNCE sil: bootout bu süreci (çekirdek kendini durduruyorsa)
        // sonlandırabilir; plist diskte kalırsa sonraki girişte çekirdek
        // yeniden başlar. Bu sıralama "tamamen durdur"u güvenilir kılar.
        try? FileManager.default.removeItem(at: plistURL)
        // Etiketle bootout: plist dosyası artık yok, bu yüzden domain/label biçimi.
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        return true
    }

    /// Çalışan çekirdeği durdurup yeniden başlatır (KeepAlive sayesinde launchd
    /// hemen yeniden başlatır). Ayar değişikliğini (örn. menü çubuğu simgesi)
    /// çekirdeğe uygulamak için kullanılır. Kayıt yoksa hiçbir şey yapmaz.
    @discardableResult
    static func restart() -> Bool {
        guard isRegistered else { return false }
        return runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            NSLog("QuitLite: launchctl çalıştırılamadı — \(error.localizedDescription)")
            return false
        }
    }
}
