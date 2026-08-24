// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSMSMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TDSKit", targets: ["TDSKit"]),
        .library(name: "SQLServerKit", targets: ["SQLServerKit"]),
        .executable(name: "ssms-mac", targets: ["SSMSMac"]),
        .executable(name: "tdscli", targets: ["TDSCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0")
    ],
    targets: [
        .target(
            name: "TDSKit",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SQLServerKit",
            dependencies: ["TDSKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SSMSMac",
            dependencies: ["SQLServerKit", "TDSKit"],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(
            name: "TDSCLI",
            dependencies: ["SQLServerKit", "TDSKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TDSKitTests",
            dependencies: ["TDSKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
