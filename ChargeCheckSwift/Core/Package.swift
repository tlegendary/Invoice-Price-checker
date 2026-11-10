// swift-tools-version: 5.9
import PackageDescription

// The "brain" of ChargeCheck: price list, matching, money maths and backups.
// Pure Swift (Foundation only) so it can be tested on its own.
let package = Package(
    name: "ChargeCheckCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "ChargeCheckCore", targets: ["ChargeCheckCore"])
    ],
    targets: [
        .target(name: "ChargeCheckCore"),
        .testTarget(name: "ChargeCheckCoreTests", dependencies: ["ChargeCheckCore"])
    ]
)
