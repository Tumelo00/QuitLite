// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuitLite",
    platforms: [.macOS(.v13)],
    targets: [
        // Tek binary, iki modda çalışır (bkz. main.swift):
        //   --core      → arka plan çekirdeği (NSApplication yok, ~2 MB)
        //   (varsayılan) → ayar penceresi
        .executableTarget(
            name: "QuitLite",
            path: "Sources/QuitLite",
            swiftSettings: [
                // Hız yerine boyut için derle: QuitLite sürekli çalışan küçük
                // bir arka plan aracıdır; binary boyutu (ve dolaylı olarak
                // bellek ayak izi) hız mikro-kazançlarından önemlidir.
                .unsafeFlags(["-Osize"], .when(configuration: .release))
            ],
            linkerSettings: [
                // Erişilemeyen sembol ve kod bölümlerini bağlama aşamasında at.
                .unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))
            ]
        )
    ]
)
