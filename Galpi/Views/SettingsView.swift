import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @AppStorage(SettingsKey.codexPath) private var codexPath = ""
  @AppStorage(SettingsKey.defaultModel) private var defaultModel = ""
  @AppStorage(SettingsKey.defaultEffort) private var defaultEffort = ""
  @AppStorage(SettingsKey.newChatsPrivate) private var newChatsPrivate = false
  @AppStorage(SettingsKey.showInDock) private var showInDock = false

  var body: some View {
    Form {
      Section("연결") {
        LabeledContent("상태", value: model.codex.state.label)
        if let path = model.codex.executablePath { LabeledContent("실행 파일", value: path) }
        if let version = model.codex.version { LabeledContent("버전", value: version) }
        TextField("codex 경로 (비우면 자동 탐색)", text: $codexPath)
        Button("다시 연결") { model.reconnect() }
      }
      Section("기본값") {
        Picker("기본 모델", selection: $defaultModel) {
          Text("계정 기본값").tag("")
          ForEach(model.codex.models) { Text($0.id).tag($0.id) }
        }
        Picker("기본 추론 강도", selection: $defaultEffort) {
          Text("모델 기본값").tag("")
          ForEach(["low", "medium", "high", "xhigh"], id: \.self) { Text($0).tag($0) }
        }
        Toggle("새 대화는 항상 기록 안 남기기", isOn: $newChatsPrivate)
          .onChange(of: newChatsPrivate) { _, new in model.nextChatPrivate = new }
      }
      Section("표시") {
        Toggle("Dock 아이콘 표시", isOn: $showInDock)
          .onChange(of: showInDock) { _, new in
            NSApp.setActivationPolicy(new ? .regular : .accessory)
            NSApp.activate(ignoringOtherApps: true)
          }
      }
      Section("저장 위치") {
        LabeledContent("기록 DB", value: model.supportDirectory.appendingPathComponent("galpi.sqlite").path)
        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([model.supportDirectory]) }
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .padding()
  }
}
