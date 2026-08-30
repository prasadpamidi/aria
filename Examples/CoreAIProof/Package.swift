// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "CoreAIProof",
    platforms: [
        .iOS(.v27),
    ],
    dependencies: [
        .package(name: "aria", path: "../.."),
        .package(
            url: "https://github.com/apple/coreai-models.git",
            revision: "de31ba508895c7aa3bdcc57f8837a23f13316871"
        ),
    ],
    targets: [
        .testTarget(
            name: "CoreAIProofTests",
            dependencies: [
                .product(name: "Aria", package: "aria"),
                .product(name: "AriaApple", package: "aria"),
                .product(name: "AriaTesting", package: "aria"),
                .product(name: "CoreAILM", package: "coreai-models"),
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
