import Foundation

/// Çalışma modu: tüm uygulamaları yönet (kara liste hariç) ya da yalnızca seçili liste.
public enum QuitMode: Int {
    case allApps = 0
    case whitelistOnly = 1
}

/// Paylaşılan UserDefaults suite destekli ayar deposu.
/// Hem arka plan çekirdeği hem ayar penceresi aynı suite'i kullanır;
/// böylece ayrı bir IPC katmanına gerek kalmaz.
public final class Preferences {

    public static let shared = Preferences()

    /// İlk açılışta gömülü gelen kara liste. Kullanıcı sonradan düzenleyebilir.
    public static let defaultBlacklist: [String] = [
        "com.apple.finder",
        "com.apple.Preview",
        // Pencere kapansa da arka planda ses/medya çalmaya devam eden uygulamalar:
        "com.apple.Music",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.spotify.client",
        "com.if.Amphetamine",
        "com.adobe.bridge",
        "com.hnc.discord",
        "com.teamviewer.TeamViewer",
        "com.nordvpn.macos",
        "com.nordvpn.nordvpn",
        "com.privateinternetaccess.vpn",
        "com.cyberghostsrl.cyberghostmac",
        "net.torguard.TorGuardDesktopQt",
        "com.ipvanish.IPVanish",
        "com.simplexsolutionsinc.vpnguardMac",
        "com.expressvpn.ExpressVPN",
        "com.surfshark.vpnclient.macos.direct",
        "com.windscribe.gui.macos",
        "com.anchorfree.hss-mac",
        "com.pvpn.privatevpn-macos",
        "com.apphousekitchen.aldente-pro",
        "com.objective-see.lulu.app"
    ]

    /// Kapatma gecikmesi için izin verilen aralık (saniye).
    public static let minQuitDelay: TimeInterval = 0
    public static let maxQuitDelay: TimeInterval = 30

    private enum Key {
        static let enabled = "enabled"
        static let mode = "mode"
        static let quitDelay = "quitDelay"
        static let blacklist = "blacklist"
        static let whitelist = "whitelist"
        static let didSeed = "didSeedBlacklist"
        static let userDisabledAgent = "userDisabledAgent"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let installedCoreVersion = "installedCoreVersion"
    }

    private let defaults: UserDefaults

    private init() {
        // Suite oluşturulamazsa standard'a düş (tek süreçte yine de çalışır).
        defaults = UserDefaults(suiteName: kPrefsSuiteName) ?? .standard
        defaults.register(defaults: [
            Key.enabled: true,
            Key.mode: QuitMode.allApps.rawValue,
            Key.quitDelay: 2.0
        ])
        if !defaults.bool(forKey: Key.didSeed) {
            defaults.set(Preferences.defaultBlacklist, forKey: Key.blacklist)
            defaults.set(true, forKey: Key.didSeed)
        }
    }

    public var enabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    public var mode: QuitMode {
        get { QuitMode(rawValue: defaults.integer(forKey: Key.mode)) ?? .allApps }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    /// Son pencere kapandıktan sonra kapatmaya kadar beklenen süre (saniye).
    public var quitDelay: TimeInterval {
        get { defaults.double(forKey: Key.quitDelay) }
        set {
            let clamped = min(max(newValue, Preferences.minQuitDelay), Preferences.maxQuitDelay)
            defaults.set(clamped, forKey: Key.quitDelay)
        }
    }

    public var blacklist: [String] {
        get { defaults.stringArray(forKey: Key.blacklist) ?? [] }
        set { defaults.set(Array(Set(newValue)).sorted(), forKey: Key.blacklist) }
    }

    public var whitelist: [String] {
        get { defaults.stringArray(forKey: Key.whitelist) ?? [] }
        set { defaults.set(Array(Set(newValue)).sorted(), forKey: Key.whitelist) }
    }

    /// Kullanıcı "Girişte başlat"ı bilerek KAPATTI mı? GUI her açılışta çekirdeği
    /// kurmayı dener; yalnızca bu bayrak true ise (kullanıcı açıkça kapattıysa)
    /// kurmaz. Eski `didInstall` bayrağı, uygulama silinip yeniden kurulunca
    /// (paylaşılan ayarlar diskte kaldığı için) takılı kalıp çekirdeğin yeniden
    /// kurulmasını engelliyordu — bu mantık onu giderir.
    public var userDisabledAgent: Bool {
        get { defaults.bool(forKey: Key.userDisabledAgent) }
        set { defaults.set(newValue, forKey: Key.userDisabledAgent) }
    }

    /// Çekirdek menü çubuğunda bir simge göstersin mi? Açıkken çekirdek
    /// NSApplication ile çalışır (~10 MB); kapalıyken hafif moddadır (~2,3 MB).
    /// Değiştiğinde çekirdeğin yeniden başlatılması gerekir (CoreAgent.restart).
    public var showMenuBarIcon: Bool {
        get { defaults.bool(forKey: Key.showMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.showMenuBarIcon) }
    }

    /// Kayıtlı LaunchAgent'ın işaret ettiği uygulamanın derleme numarası.
    /// Yerinde güncellemeyi (yol aynı, binary yeni) saptamak için kullanılır:
    /// CoreAgent.synchronize() bu değer mevcut sürümle uyuşmazsa yeniden kaydeder.
    public var installedCoreVersion: String {
        get { defaults.string(forKey: Key.installedCoreVersion) ?? "" }
        set { defaults.set(newValue, forKey: Key.installedCoreVersion) }
    }

    /// Bekleyen ayar yazımlarını diske zorlar. Çekirdek süreci yeniden
    /// başlatılmadan hemen önce çağrılır; aksi halde çekirdek relaunch olunca
    /// henüz diske inmemiş eski değeri okuyabilir (iki süreç ayrı önbellek tutar).
    public func flush() {
        defaults.synchronize()
    }

    /// Verilen bundle kimliği QuitLite tarafından otomatik kapatılmalı mı?
    public func shouldManage(bundleID: String) -> Bool {
        guard enabled else { return false }
        guard bundleID != kGUIBundleID else { return false }
        switch mode {
        case .allApps:
            return !blacklist.contains(bundleID)
        case .whitelistOnly:
            return whitelist.contains(bundleID)
        }
    }
}
