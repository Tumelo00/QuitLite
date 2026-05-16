// QuitLite uygulama ikonunu programatik olarak üretir.
// build.sh tarafından `swift Tools/makeicon.swift <iconset-klasörü>` ile çağrılır;
// 10 boyutta PNG yazar, build.sh ardından `iconutil` ile .icns paketler.
//
// Tasarım: maviden lacivete dikey degrade köşeli-kare (macOS app ikonu biçimi),
// üzerinde beyaz bir pencere ve başlık çubuğunda üç trafik ışığı noktası —
// QuitLite "pencere kapanınca uygulamayı kapatır" aracıdır.

import AppKit

let iconsetDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(size)

    // --- Arka plan: degrade köşeli kare ---
    let margin = s * 0.085
    let bg = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let bgRadius = bg.width * 0.2237
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: bg, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil))
    cg.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 0.40, green: 0.58, blue: 0.96, alpha: 1),
                 CGColor(red: 0.17, green: 0.31, blue: 0.78, alpha: 1)] as CFArray,
        locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    cg.restoreGState()

    // --- Pencere: gölgeli beyaz köşeli dikdörtgen ---
    let wW = s * 0.54, wH = s * 0.44
    let wX = (s - wW) / 2, wY = (s - wH) / 2
    let wRect = CGRect(x: wX, y: wY, width: wW, height: wH)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.035,
                 color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    cg.addPath(CGPath(roundedRect: wRect, cornerWidth: s * 0.052, cornerHeight: s * 0.052, transform: nil))
    cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    cg.fillPath()
    cg.restoreGState()

    // --- Başlık çubuğu trafik ışıkları ---
    let dotR = wH * 0.085
    let dotY = wY + wH - wH * 0.15
    let firstX = wX + wW * 0.13
    let gap = dotR * 3.0
    let dotColors = [
        CGColor(red: 1.00, green: 0.37, blue: 0.34, alpha: 1),
        CGColor(red: 1.00, green: 0.74, blue: 0.18, alpha: 1),
        CGColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1)
    ]
    for (index, color) in dotColors.enumerated() {
        let cx = firstX + CGFloat(index) * gap
        cg.setFillColor(color)
        cg.fillEllipse(in: CGRect(x: cx - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
    }

    return rep.representation(using: .png, properties: [:])!
}

// iconutil'in beklediği dosya adları (bazı boyutlar iki kez kullanılır).
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
var cache: [Int: Data] = [:]
for variant in variants {
    let data = cache[variant.size] ?? render(variant.size)
    cache[variant.size] = data
    let path = (iconsetDir as NSString).appendingPathComponent("\(variant.name).png")
    try! data.write(to: URL(fileURLWithPath: path))
}
print("İkon yazıldı: \(iconsetDir)")
