import Foundation

/// Arka plan çekirdeğini (QuitLiteCore) launchd üzerinden yöneten LaunchAgent
/// sarmalayıcısı.
///
/// SMAppService yerine klasik `~/Library/LaunchAgents` + `launchctl` yöntemi
/// kullanılır: SMAppService geçerli bir Developer ID imzası ister; QuitLite ise
/// açık kaynak ve ad-hoc imzalıdır. Manuel LaunchAgent imza gerektirmez.
enum CoreAgent {

    private static let label = "com.tumerustunel.QuitLite.Core"

    /// launchctl yeniden deneme işleri için seri arka plan kuyruğu. İlk bootstrap
    /// denemesi başarısız olursa kalan denemeler burada yapılır — böylece bekleme
    /// (Thread.sleep) ana thread'i (GUI / ayar penceresi) dondurmaz.
    private static let launchctlQueue =
        DispatchQueue(label: "com.tumerustunel.QuitLite.launchctl")

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

    /// Çalışmakta olan uygulamanın derleme numarası (CFBundleVersion).
    private static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
    }

    /// Uygulama bir Applications klasöründe mi çalışıyor? Çekirdek yalnızca
    /// burada kurulmalıdır: DMG'den, İndirilenler'den ya da Gatekeeper'ın
    /// taşıdığı (App Translocation) geçici/salt-okunur yoldan kurulursa, o yol
    /// kaybolduğunda LaunchAgent kalıcı olarak bozuk bir binary'yi gösterir.
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") { return true }
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        return path.hasPrefix(userApps + "/")
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
    /// - Kayıt var ama sürüm değişmiş (yerinde güncelleme) → yeniden kaydet;
    ///   aksi halde çalışan çekirdek hâlâ eski binary'yi belleğinde tutar.
    /// - Kayıt var, yol ve sürüm doğru → DOKUNMA (bekleyen kapatmalar korunur).
    /// Geriye çekirdeğin kurulu olup olmadığını döner.
    @discardableResult
    static func synchronize(allowFirstInstall: Bool) -> Bool {
        if isRegistered {
            if installedBinaryPath != mainBinaryPath
                || Preferences.shared.installedCoreVersion != currentVersion {
                register()
            }
            return true
        }
        if allowFirstInstall {
            // register() sonucunu döndür: /Applications dışından kurulum
            // reddedilirse synchronize() false döner, didInstall işaretlenmez,
            // kullanıcı uygulamayı taşıyıp yeniden açınca kurulum tekrar denenir.
            return register()
        }
        return false
    }

    @discardableResult
    static func register() -> Bool {
        // /Applications dışından (DMG, İndirilenler, translocated yol) kuruluma
        // izin verme — çekirdek o yol kaybolunca kalıcı olarak bozulur.
        guard isInApplicationsFolder else {
            NSLog("QuitLite: /Applications dışından kurulum reddedildi — \(Bundle.main.bundlePath)")
            return false
        }
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
            // Hafif "safe mode": çekirdek bir çökme döngüsüne (crash-loop)
            // girerse launchd onu ThrottleInterval'dan daha sık başlatmaz.
            // Özel crash sayacı / çalışma-zamanı durumu YOK — bu tamamen
            // launchd'in yerleşik korumasıdır (ek kod yok, RAM/CPU etkisi yok).
            // 30 sn: varsayılan 10 sn'den daha nazik (çöküyorsa sistemi 3 kat
            // daha az uyandırır), ama tek seferlik bir çökmeden sonra kurtarmayı
            // da ciddi geciktirmez — çekirdek normalde hiç çıkmaz.
            "ThrottleInterval": 30,
            // Adaptive: boştayken düşük öncelikli, izlenecek iş çıkınca sistem
            // süreci yükseltir. Background tier'ı, ~10 sn'de tepki vermesi
            // gereken bir izleyici için fazla agresif throttle uygular.
            "ProcessType": "Adaptive",
            // Nadir disk yazımları (UserDefaults) ön plandaki I/O ile yarışmasın.
            "LowPriorityBackgroundIO": true,
            // Giriş Öğeleri arayüzünde ajanı uygulamayla grupla (macOS 13+).
            // Bu anahtarın türü dizidir; tek kimlik de dizi içinde verilir.
            "AssociatedBundleIdentifiers": [kGUIBundleID]
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
        let path = plistURL.path
        // Olası eski kaydı temizle (uygulamanın yolu değişmiş olabilir), sonra yükle.
        _ = runLaunchctl(["bootout", domain, path])
        // İlk bootstrap denemesi senkron — olağan durumda hemen başarılı olur.
        if runLaunchctl(["bootstrap", domain, path]) {
            Preferences.shared.installedCoreVersion = currentVersion
            return true
        }
        // İlk deneme başarısız (bootout/bootstrap yarışı): kalan denemeleri ana
        // thread'i BLOKLAMADAN, seri arka plan kuyruğunda yap. Plist diskte
        // olduğu için en kötü ihtimalde çekirdek bir sonraki girişte yüklenir.
        launchctlQueue.async {
            for _ in 0..<4 {
                Thread.sleep(forTimeInterval: 0.4)
                if runLaunchctl(["bootstrap", domain, path]) {
                    Preferences.shared.installedCoreVersion = currentVersion
                    return
                }
            }
            NSLog("QuitLite: çekirdek bootstrap denemeleri başarısız — girişte yeniden denenecek")
        }
        return true
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
