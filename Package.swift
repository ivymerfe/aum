// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "aum",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "MultitouchSupport",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks"])
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreFoundation"),
                .unsafeFlags([
                    "-framework", "MultitouchSupport", "-F/System/Library/PrivateFrameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "aum",
            dependencies: ["MultitouchSupport"],
            resources: [
                .process("Assets.xcassets")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-framework",
                    "-Xlinker", "MultitouchSupport",
                    "-Xlinker", "-framework",
                    "-Xlinker", "SkyLight",
                    "-Xlinker", "-F/System/Library/PrivateFrameworks",
                ])
            ],
        ),
    ]
)
