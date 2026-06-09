// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BillingBear",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "BillingBear",
            targets: ["BillingBear"]
        )
    ],
    dependencies: [
        // Bundled so animated (Lottie) paywall backgrounds render plug-and-play — the consumer
        // installs only BillingBear; Lottie comes transitively (no manual extra dependency).
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0")
    ],
    targets: [
        .target(
            name: "BillingBear",
            dependencies: [
                .product(name: "Lottie", package: "lottie-ios")
            ],
            path: "Sources/BillingBear"
        ),
        .testTarget(
            name: "BillingBearTests",
            dependencies: ["BillingBear"],
            path: "Tests/BillingBearTests"
        )
    ]
)
