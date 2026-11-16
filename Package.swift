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
    .target(name: "LongcableMicCapture", dependencies: ["LongcableCore"], linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"), .linkedFramework("CoreMedia")]),
    .executableTarget(name: "longcable-server", dependencies: ["LongcableCore", "LongcableMicCapture"]),
    .executableTarget(name: "Longcable", dependencies: ["LongcableCore", "LongcableMicCapture"]),
    .testTarget(name: "LongcableCoreTests", dependencies: ["LongcableCore"]),
    .testTarget(name: "LongcableMicCaptureTests", dependencies: ["LongcableMicCapture", "LongcableCore"]),
    .testTarget(name: "LongcableAppTests", dependencies: ["Longcable", "LongcableMicCapture"])
])
