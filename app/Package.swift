// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinPhone",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WinPhoneCore", targets: ["WinPhoneCore"]),
        .executable(name: "winphone-probe", targets: ["winphone-probe"]),
        .executable(name: "WinPhone", targets: ["WinPhone"]),
    ],
    dependencies: [
        // Apple's protobuf runtime. Pinned to the version of the generator used for Generated/.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(
            name: "WinPhoneCore",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "winphone-probe",
            dependencies: ["WinPhoneCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WinPhone",
            dependencies: ["WinPhoneCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WinPhoneTests",
            dependencies: ["WinPhone", "WinPhoneCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WinPhoneCoreTests",
            dependencies: ["WinPhoneCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
