// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WinUSB",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WinUSB", targets: ["WinUSB"]),
        .executable(name: "winusb-cli", targets: ["winusb-cli"]),
    ],
    targets: [
        .target(name: "WinUSBCore"),
        .executableTarget(name: "WinUSB", dependencies: ["WinUSBCore"]),
        .executableTarget(name: "winusb-cli", dependencies: ["WinUSBCore"]),
    ]
)
