// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SharedSpec", products: [
    .library(name: "PetCore", targets: ["PetCore"]),
    .library(name: "IPCProtocol", targets: ["IPCProtocol"])
], targets: [
    .target(name: "PetCore", path: "Swift/PetCore"),
    .target(name: "IPCProtocol", dependencies: ["PetCore"], path: "Swift/Core"),
    .executableTarget(name: "SpecChecks", dependencies: ["IPCProtocol", "PetCore"], path: "Tests/Swift")
], swiftLanguageModes: [.v5])
