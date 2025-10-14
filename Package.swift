// swift-tools-version:5.6

import PackageDescription

var dependencies: [Package.Dependency] = []

var targetDeps: [Target.Dependency] = []

#if !os(Linux)
dependencies += [
  .package(
    url: "https://github.com/JWIMaster/Starscream", branch: "master"),
  .package(url: "https://github.com/JWIMaster/FoundationCompatKit.git", branch: "master")
]
  
targetDeps += ["Starscream", "FoundationCompatKit"]
#else
dependencies += [
  .package(
    url: "https://github.com/vapor/engine.git",
    .upToNextMajor(from: "2.0.0")
  )
]
  
targetDeps += ["URI", "WebSockets", "FoundationCompatKit"]
#endif

let package = Package(
  name: "Sword",
  platforms: [
        .iOS("7.0")
  ],
  products: [
    .library(name: "Sword", targets: ["Sword"])
  ],
  dependencies: dependencies,
  targets: [
    .target(
      name: "Sword",
      dependencies: targetDeps
    )
  ]
)
