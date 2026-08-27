// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ThermoFan",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ThermoFan", targets: ["ThermoFan"]),
        .executable(name: "ThermoFanHelper", targets: ["ThermoFanHelper"])
    ],
    targets: [
        .target(
            name: "FanSafetyPolicy",
            path: "Sources/FanSafetyPolicy",
            publicHeadersPath: "include"
        ),
        .target(
            name: "FanControlEngine",
            dependencies: ["FanSafetyPolicy"],
            path: "Helpers/ThermoFanHelper",
            exclude: ["main.c"],
            sources: ["ThermoFanEngine.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("THERMOFAN_ENGINE_LIBRARY")
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedLibrary("proc")
            ]
        ),
        .target(
            name: "FanControlXPC",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "ThermoFan",
            dependencies: ["FanControlXPC"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "ThermoFanHelper",
            dependencies: ["FanControlEngine", "FanControlXPC"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .testTarget(
            name: "ThermoFanTests",
            dependencies: ["ThermoFan", "FanSafetyPolicy", "FanControlXPC"]
        )
    ]
)
