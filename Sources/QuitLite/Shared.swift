import Foundation

/// Çekirdek ve GUI süreçlerinin ortak kullandığı sabitler.

/// Paylaşılan UserDefaults suite — iki süreç de bu plist'i okur/yazar.
public let kPrefsSuiteName = "com.tumerustunel.QuitLite.shared"

/// Ayar penceresi uygulamasının bundle kimliği. Çekirdek bu uygulamayı
/// (kendi GUI'sini) asla kapatmaz.
public let kGUIBundleID = "com.tumerustunel.QuitLite"
