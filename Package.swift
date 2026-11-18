// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

// swift-tools-version: 6.2
import PackageDescription

// Elsewhere, such as on Linux, a copy of the parts of Foundation Models this package uses stands
// in for Apple's. App Attest needs Apple's frameworks, so it's left out there.
#if canImport(Darwin)
let linuxDependencies: [Package.Dependency] = []
let linuxTargetDependencies: [Target.Dependency] = []
#else
let linuxDependencies: [Package.Dependency] = [
  .package(url: "https://github.com/imben123/FoundationModelsLinux", from: "0.2.0")
]
let linuxTargetDependencies: [Target.Dependency] = [
  .product(name: "FoundationModels", package: "FoundationModelsLinux")
]
#endif

let package = Package(
  name: "ClaudeForFoundationModels",
  // Every OS where Foundation Models supports server-side language models.
  // Spelled as strings because the .v27 constants require tools-version 6.4.
  platforms: [
    .iOS("27.0"), .macOS("27.0"), .visionOS("27.0"), .watchOS("27.0"),
  ],
  products: [
    .library(name: "ClaudeForFoundationModels", targets: ["ClaudeForFoundationModels"])
  ],
  dependencies: linuxDependencies,
  targets: [
    // Internal Messages API client. No FoundationModels dependency.
    .target(name: "ClaudeAPI"),

    // FoundationModels ↔ Messages API bridge.
    .target(
      name: "ClaudeForFoundationModels",
      dependencies: ["ClaudeAPI"] + linuxTargetDependencies
    ),

    // Runnable usage example (`swift run ClaudeExample`). Deliberately not a
    // product — it exists to document the SDK, not to be depended on.
    .executableTarget(
      name: "ClaudeExample",
      dependencies: ["ClaudeForFoundationModels"],
      path: "Examples/ClaudeExample"
    ),

    .testTarget(
      name: "ClaudeAPITests",
      dependencies: ["ClaudeAPI"]
    ),
    .testTarget(
      name: "ClaudeForFoundationModelsTests",
      dependencies: ["ClaudeForFoundationModels"]
    ),
  ]
)
