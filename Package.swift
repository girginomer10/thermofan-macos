// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ThermoFan",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ThermoFan", targets: ["ThermoFan"])
    ],
    targets: [
        .executableTarget(
            name: "ThermoFan",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "ThermoFanTests",
            dependencies: ["ThermoFan"]
        )
    ]
)
