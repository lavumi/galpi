import AppKit
import SwiftUI

@main
struct GalpiApp: App {
  @State private var model: AppModel
  @State private var startupError: String?

  init() {
    // 기본은 메뉴 바 전용. Info.plist 의 LSUIElement 가 Dock 등록 자체를 막고, 설정에서 켠 경우에만 승격한다.
    let showInDock = UserDefaults.standard.object(forKey: SettingsKey.showInDock) as? Bool ?? false
    if showInDock { NSApplication.shared.setActivationPolicy(.regular) }
    let boot = AppModel.bootstrap()
    _model = State(initialValue: boot.model)
    _startupError = State(initialValue: boot.startupError)
  }

  var body: some Scene {
    WindowGroup("갈피", id: "main") {
      MainView(startupError: startupError)
        .environment(model)
        .frame(minWidth: 900, minHeight: 560)
        .task {
          NSApplication.shared.activate(ignoringOtherApps: true)
          QuickAskController.shared.setup(model: model)
          await model.start()
        }
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("새 대화") { model.newChat() }
          .keyboardShortcut("n", modifiers: .command)
        Button("기록 안 남기는 새 대화") { model.newPrivateChat() }
          .keyboardShortcut("n", modifiers: [.command, .shift])
      }
      CommandGroup(after: .toolbar) {
        Button("Codex 다시 연결") { model.reconnect() }
          .keyboardShortcut("r", modifiers: [.command, .shift])
      }
      CommandGroup(after: .sidebar) {
        Divider()
        Button("전체 대화") { model.scope = .all }
          .keyboardShortcut("1", modifiers: .command)
        Button("즐겨찾기") { model.scope = .favorites }
          .keyboardShortcut("2", modifiers: .command)
        Button("보관함") { model.scope = .archived }
          .keyboardShortcut("3", modifiers: .command)
        Button("휴지통") { model.scope = .trash }
          .keyboardShortcut("4", modifiers: .command)
        Divider()
        Button("이전 대화") { model.selectAdjacentConversation(offset: -1) }
          .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        Button("다음 대화") { model.selectAdjacentConversation(offset: 1) }
          .keyboardShortcut(.downArrow, modifiers: [.command, .option])
      }
      CommandGroup(after: .textEditing) {
        Divider()
        Button("대화에서 찾기") { model.requestChatSearch() }
          .keyboardShortcut("f", modifiers: .command)
          .disabled(model.session == nil)
        Button("대화 목록 검색") { model.requestListSearch() }
          .keyboardShortcut("f", modifiers: [.command, .shift])
      }
      CommandMenu("대화") {
        Button("입력창으로 이동") { model.focusComposer() }
          .keyboardShortcut("l", modifiers: .command)
        Button("마지막 답변 복사") { model.copyLastAnswer() }
          .keyboardShortcut("c", modifiers: [.command, .shift])
          .disabled(model.session == nil)
        Divider()
        Button(model.session?.conversation.isFavorite == true ? "즐겨찾기 해제" : "즐겨찾기") { model.toggleFavoriteCurrent() }
          .keyboardShortcut("d", modifiers: .command)
          .disabled(model.session == nil || model.session?.isEphemeral == true)
        Button(model.session?.conversation.isArchived == true ? "보관 해제" : "보관") { model.toggleArchiveCurrent() }
          .keyboardShortcut("e", modifiers: .command)
          .disabled(model.session == nil || model.session?.isEphemeral == true)
        Button("휴지통으로 이동") { model.trashCurrent() }
          .keyboardShortcut(.delete, modifiers: .command)
          .disabled(model.session == nil || model.session?.isEphemeral == true)
      }
    }

    Settings {
      SettingsView()
        .environment(model)
    }

    MenuBarExtra("갈피", systemImage: "bookmark.fill") {
      MenuBarMenu()
        .environment(model)
    }
  }
}

struct MenuBarMenu: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("갈피 열기") {
      openWindow(id: "main")
      NSApp.activate(ignoringOtherApps: true)
    }
    Button("빠른 질문") { QuickAskController.shared.toggle() }
    Divider()
    SettingsLink { Text("설정…") }
    Divider()
    Button("갈피 종료") { NSApp.terminate(nil) }
  }
}
