// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "DynaPetNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PetCore", targets: ["PetCore"]),
        .library(name: "Windowing", targets: ["Windowing"]),
        .executable(name: "dynapet-x11", targets: ["DynaPetX11"])
    ],
    targets: [
        .target(name: "PetCore"),
        .systemLibrary(name: "CX11", pkgConfig: "x11", providers: [.apt(["libx11-dev", "libxrender-dev"])]),
        .systemLibrary(name: "CCairo", pkgConfig: "cairo", providers: [.apt(["libcairo2-dev"])]),
        .systemLibrary(name: "CGTK3", pkgConfig: "gtk+-3.0", providers: [.apt(["libgtk-3-dev"])]),
        .target(name: "Windowing", dependencies: ["PetCore", .target(name: "CX11", condition: .when(platforms: [.linux]))]),
        .executableTarget(name: "DynaPetX11", dependencies: ["PetCore", "Windowing", .target(name: "CX11", condition: .when(platforms: [.linux])), .target(name: "CCairo", condition: .when(platforms: [.linux])), .target(name: "CGTK3", condition: .when(platforms: [.linux]))]),
        .testTarget(name: "PetCoreTests", dependencies: ["PetCore"])
    ]
)
