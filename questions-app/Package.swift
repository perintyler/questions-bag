// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Questions",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Questions", targets: ["Questions"])
    ],
    dependencies: [
        // Components carries the shared fonts (Inter / JetBrains Mono via
        // AppFont) and the palette every Barry surface uses. A second copy of
        // the type system would drift from the invariants pinned there.
        //
        // This directory is `questions-app`, not `app`: SwiftPM derives a
        // package's identity from its directory name, and a second package
        // called `app` collides with the sessions one — the dependency
        // resolves to itself and the product is reported missing.
        .package(path: "../../../barry/bags/sessions/sessions-macos/app")
    ],
    targets: [
        // Pure, UI-capable feature logic — the model, client and state. Split
        // from the executable so answering logic is testable without a window
        // or a live service.
        .target(
            name: "QuestionsFeature",
            dependencies: [
                .product(name: "Components", package: "app")
            ],
            path: "Features/Questions",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuestionsFeatureTests",
            dependencies: ["QuestionsFeature"],
            path: "Features/QuestionsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Questions",
            dependencies: ["QuestionsFeature"],
            path: "Sources/App",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
