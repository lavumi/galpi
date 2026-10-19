// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MarkdownSpike",
  platforms: [.macOS(.v15)],
  dependencies: [
    // 상위 패키지가 HighlightSwift를 커밋 고정으로 의존하므로 버전 범위 대신 v0.7.0 커밋을 고정한다.
    .package(url: "https://github.com/microsoft/SwiftStreamingMarkdown", revision: "5f7c04e0558df6146f90d482edb62cb456986bda")
  ],
  targets: [
    .executableTarget(
      name: "MarkdownSpike",
      dependencies: [
        .product(name: "SwiftStreamingMarkdown", package: "SwiftStreamingMarkdown")
      ],
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
