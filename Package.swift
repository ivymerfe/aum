// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "aum",
    targets: [
        .target(
            name: "MultitouchSupport",
            publicHeadersPath: "include",
            cSettings: [
                // Путь к приватным фреймворкам macOS для поиска заголовков
                .unsafeFlags(["-F/System/Library/PrivateFrameworks"])
            ],
            linkerSettings: [
                // Подключаем публичные и приватные фреймворки
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreFoundation"),
                .unsafeFlags(["-framework", "MultitouchSupport", "-F/System/Library/PrivateFrameworks"])
            ]
        ),
        .executableTarget(
            name: "aum",
            dependencies: ["MultitouchSupport"],
            resources: [
                .process("Assets.xcassets")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-framework",
                    "-Xlinker", "MultitouchSupport",
                    "-Xlinker", "-F/System/Library/PrivateFrameworks"
                ])
            ],
        ),
    ]
)
