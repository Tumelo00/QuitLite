import Foundation

/// Çekirdek ve GUI süreçlerinin ortak kullandığı sabitler.

/// Paylaşılan UserDefaults suite — iki süreç de bu plist'i okur/yazar.
public let kPrefsSuiteName = "com.tumerustunel.QuitLite.shared"

/// Ayar penceresi uygulamasının bundle kimliği. Çekirdek bu uygulamayı
/// (kendi GUI'sini) asla kapatmaz.
public let kGUIBundleID = "com.tumerustunel.QuitLite"

/// GUI ayarları değiştirip diske yazınca gönderdiği Darwin bildiriminin adı.
/// Çekirdek bunu dinler ve ayarları yeniden başlatma olmadan canlı yükler.
public let kPrefsChangedNotification = "com.tumelo00.QuitLite.preferencesChanged"

/// `--debug` argümanıyla açılan ayrıntılı izleme. Kapalıyken (varsayılan) tek
/// bir Bool kontrolüdür; çalışma zamanı maliyeti ve boşta RAM etkisi sıfıra yakın.
public let kDebugMode = CommandLine.arguments.contains("--debug")
