// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "delucyx",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DelucyxBPF", targets: ["DelucyxBPF"]),
    ],
    targets: [
        .target(
            name: "DelucyxBPF_C",
            dependencies: [],
            linkerSettings: []
        ),
        .target(
            name: "DelucyxBPF",
            dependencies: ["DelucyxBPF_C"]
        ),
    ]
)
