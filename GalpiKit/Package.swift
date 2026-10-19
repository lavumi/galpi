// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "GalpiKit",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "GalpiKit", targets: ["GalpiKit"]),
  ],
  dependencies: [
    // 상위 패키지가 HighlightSwift를 커밋 고정으로 의존하므로 버전 범위 대신 v0.7.0 커밋을 고정한다.
    .package(url: "https://github.com/microsoft/SwiftStreamingMarkdown", revision: "5f7c04e0558df6146f90d482edb62cb456986bda"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
  ],
  targets: [
    .target(
      name: "GalpiKit",
      dependencies: [
        .product(name: "SwiftStreamingMarkdown", package: "SwiftStreamingMarkdown"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "GalpiKitTests",
      dependencies: ["GalpiKit"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
