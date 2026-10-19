import AppKit
import SwiftUI

@main
struct MarkdownSpikeApp: App {
  init() {
    // SwiftPM 실행 파일은 앱 번들이 아니므로 직접 일반 앱으로 승격해야 창과 메뉴가 뜬다.
    NSApplication.shared.setActivationPolicy(.regular)
  }

  var body: some Scene {
    WindowGroup("Markdown Spike") {
      ContentView()
        .frame(minWidth: 720, minHeight: 600)
        .onAppear {
          NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
    .defaultSize(width: 900, height: 800)
  }
}
