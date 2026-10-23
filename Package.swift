// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Menu du Jour",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Pure, framework-light logic that is unit-testable in isolation.
        .target(
            name: "MenuDuJourCore",
            path: "Sources/MenuDuJourCore",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "Menu du Jour",
            dependencies: ["MenuDuJourCore"],
            path: "Sources/MacMenu",
            linkerSettings: [
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "MenuDuJourCoreTests",
            dependencies: ["MenuDuJourCore"],
            path: "Tests/MenuDuJourCoreTests"
        ),
    ]
)
