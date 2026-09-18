// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StaminaKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "StaminaKit", targets: ["StaminaKit"]),
    ],
    targets: [
        .target(
            name: "StaminaKit",
            path: "Sources/StaminaKit",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("AdSupport"),
                .linkedFramework("AppTrackingTransparency"),
                .linkedFramework("AdServices"),
            ]
        ),
        .testTarget(
            name: "StaminaKitTests",
            dependencies: ["StaminaKit"],
            path: "Tests/StaminaKitTests"
        ),
    ]
)
