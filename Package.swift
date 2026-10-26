// swift-tools-version: 5.9
// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import PackageDescription
let package = Package(name: "Longcable", platforms: [.macOS(.v13)], products: [
    .executable(name: "longcable-server", targets: ["longcable-server"]),
    .executable(name: "Longcable", targets: ["Longcable"])
], targets: [
    .target(name: "ExceptionGuard", publicHeadersPath: "include"),
    .target(name: "LongcableCore", dependencies: ["ExceptionGuard"], linkerSettings: [.linkedFramework("IOUSBHost"), .linkedFramework("IOKit")]),
    .executableTarget(name: "longcable-server", dependencies: ["LongcableCore"]),
    .executableTarget(name: "Longcable", dependencies: ["LongcableCore"]),
    .testTarget(name: "LongcableCoreTests", dependencies: ["LongcableCore"])
])
