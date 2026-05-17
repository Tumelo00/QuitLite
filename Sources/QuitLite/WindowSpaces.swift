import Foundation
import CoreGraphics

/// Bir uygulamanın pencerelerinin hangi Space'lerde (masaüstü / tam ekran)
/// bulunduğunu sorgular.
///
/// Neden gerekli: Discord gibi uygulamalar son pencere kapatılınca pencereyi
/// `orderOut` ile gizler — gizli pencere HİÇBİR Space'te değildir. Başka bir
/// masaüstündeki ya da arka planda tam ekran bir pencere ise bir Space'tedir.
/// CGWindowList ikisini de "ekranda değil" gösterir; yalnızca Space sorgusu
/// "gizli" ile "başka masaüstünde"yi ayırır — yani gerçekten kapatılması
/// gereken uygulamayı, kapatılmaması gerekenden.
///
/// macOS bunu açık (public) API ile sunmaz; özel CoreGraphics Services
/// sembollerine `dlsym` ile ÇALIŞMA ZAMANINDA bağlanılır. Sembol bir gün
/// kaybolursa derleme de çökme de olmaz — sorgu `nil` döner, çağıran taraf
/// güvenli (yanlış kapatmayan) eski davranışa düşer.
enum WindowSpaces {

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpacesForWindowsFn =
        @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// RTLD_DEFAULT — sürece yüklü tüm imajlarda sembol arar.
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static let mainConnection: MainConnectionFn? = {
        guard let symbol = dlsym(rtldDefault, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: MainConnectionFn.self)
    }()

    private static let copySpacesForWindows: SpacesForWindowsFn? = {
        guard let symbol = dlsym(rtldDefault, "CGSCopySpacesForWindows") else { return nil }
        return unsafeBitCast(symbol, to: SpacesForWindowsFn.self)
    }()

    /// CGS sembolleri bu macOS'ta bulunabildi mi?
    static var isAvailable: Bool {
        mainConnection != nil && copySpacesForWindows != nil
    }

    /// Verilen pencere ID'lerinin üzerinde bulunduğu Space sayısı.
    /// `nil`  = CGS kullanılamıyor (sembol yok) — çağıran güvenli tarafa düşmeli.
    /// `0`    = pencereler hiçbir Space'te değil → hepsi gizli (orderOut).
    /// `>0`   = en az biri bir Space'te → görünür ya da başka masaüstünde.
    static func spaceCount(ofWindowIDs ids: [CGWindowID]) -> Int? {
        guard let mainConnection, let copySpacesForWindows else { return nil }
        guard !ids.isEmpty else { return 0 }
        let cfIDs = ids.map { NSNumber(value: $0) } as CFArray
        // mask 0x7 = current | other | user — tüm Space türleri.
        guard let spaces = copySpacesForWindows(mainConnection(), 0x7, cfIDs) else { return 0 }
        return CFArrayGetCount(spaces.takeRetainedValue())
    }
}
