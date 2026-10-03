// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mako",
    platforms: [.macOS("26.0")],
    targets: [
        .systemLibrary(name: "MakoCore", path: "core/include"),
        .executableTarget(
            name: "Mako",
            dependencies: ["MakoCore"],
            path: "app/Sources/Mako",
            linkerSettings: [.unsafeFlags(["-Lcore/target/release"])]
        ),
    ]
)
