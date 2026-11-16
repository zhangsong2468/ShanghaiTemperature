// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShanghaiTemperatureCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WeatherCore", targets: ["WeatherCore"])],
    targets: [
        .target(name: "WeatherCore", path: "Shared", exclude: ["TemperatureChartView.swift"]),
        .testTarget(name: "WeatherCoreTests", dependencies: ["WeatherCore"], path: "Tests")
    ]
)
