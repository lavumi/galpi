import AppKit
import GalpiKit
import SwiftUI

@main
struct GalpiApp: App {
  @State private var model: AppModel
  @State private var startupError: String?

  init() {
    NSApplication.shared.setActivationPolicy(.regular)
    let boot = AppModel.bootstrap()
    _model = State(initialValue: boot.model)
    _startupError = State(initialValue: boot.startupError)
  }

  var body: some Scene {
    WindowGroup("갈피") {
      MainView(startupError: startupError)
        .environment(model)
        .frame(minWidth: 900, minHeight: 560)
        .task {
          NSApplication.shared.activate(ignoringOtherApps: true)
          await model.start()
        }
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("새 대화") { model.newChat() }
          .keyboardShortcut("n", modifiers: .command)
      }
      CommandGroup(after: .toolbar) {
        Button("Codex 다시 연결") { model.reconnect() }
          .keyboardShortcut("r", modifiers: [.command, .shift])
      }
    }

    Settings {
      SettingsView()
        .environment(model)
    }
  }
}
