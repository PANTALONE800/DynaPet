// swift-tools-version: 6.0
import PackageDescription
import Foundation
#if arch(arm64)
let bridgeArchitecture = "arm64"
#else
let bridgeArchitecture = "x86_64"
#endif
let bridgeSearchPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/petbridge/\(bridgeArchitecture)/Frameworks").path
let shared: Target.Dependency = .product(name: "IPCProtocol", package: "SharedSpec")
let domain: Target.Dependency = .product(name: "PetCore", package: "SharedSpec")
let package = Package(name: "MacPetPlatform", platforms: [.macOS(.v14)], products: [
    .executable(name: "ipc-core-demo", targets: ["CoreDemo"]),
    .executable(name: "dynapet-mac-core", targets: ["MacCoreDemo"])
], dependencies: [.package(path: "SharedSpec")], targets: [
    .systemLibrary(name: "PetBridge", path: "MacPlatform/Bridge/PetBridge/include"),
    .target(name: "CSystem", path: "MacPlatform/Bridge/CSystem", publicHeadersPath: "include"),
    .target(name: "MacIPCTransport", dependencies: [shared, "CSystem"], path: "MacPlatform/Transport"),
    .target(name: "MacPetWindowing", dependencies: [shared, domain], path: "MacPlatform/AppKit"),
    .executableTarget(name: "CoreDemo", dependencies: [shared, "MacIPCTransport", "CSystem"], path: "MacPlatform/Runtime/IPCProbe"),
    .executableTarget(name: "MacCoreDemo", dependencies: [shared, "MacIPCTransport", "CSystem", "MacPetWindowing", "PetBridge"], path: "MacPlatform/Runtime/App",
        linkerSettings: [.linkedLibrary("petbridge"), .unsafeFlags(["-L", bridgeSearchPath, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
], swiftLanguageModes: [.v5])
