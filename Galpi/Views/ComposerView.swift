import SwiftUI

struct ComposerView: View {
  @Environment(AppModel.self) private var model
  @State private var selectedModel = ""
  @State private var selectedEffort = ""
  @FocusState private var focused: Bool

  private var currentModel: CodexModel? { model.codex.models.first(where: { $0.id == selectedModel }) }
  private var isGenerating: Bool { model.codex.isGenerating }
  private var hasText: Bool { !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var queuedCount: Int { model.session?.queuedPrompts.count ?? 0 }
  private var canSend: Bool {
    hasText && model.codex.state == .connected && !isGenerating
  }

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 8) {
      if let session = model.session, !session.queuedPrompts.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(session.queuedPrompts.enumerated()), id: \.offset) { index, prompt in
            HStack(spacing: 6) {
              Image(systemName: "clock").font(.caption2).foregroundStyle(.secondary)
              Text(prompt).font(.callout).lineLimit(1)
              Spacer()
              Button { session.queuedPrompts.remove(at: index) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
              }
              .buttonStyle(.borderless)
              .help("대기열에서 제거")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
      TextField("질문을 입력하세요 (Enter 전송, Option+Enter 줄바꿈)", text: $model.composerText, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...12)
        .font(.body)
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .focused($focused)
        .onSubmit(send)

      HStack(spacing: 12) {
        Picker("모델", selection: $selectedModel) {
          ForEach(model.codex.models) { m in Text(m.id).tag(m.id) }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
        .disabled(model.codex.models.isEmpty)

        if let currentModel, !currentModel.efforts.isEmpty {
          Picker("추론", selection: $selectedEffort) {
            Text("기본").tag("")
            ForEach(currentModel.efforts, id: \.self) { Text(effortLabel($0)).tag($0) }
          }
          .labelsHidden()
          .frame(maxWidth: 110)
        }

        if model.session == nil {
          Toggle(isOn: $model.nextChatPrivate) { Label("기록 안 남기기", systemImage: "eye.slash") }
            .toggleStyle(.checkbox)
        }

        Spacer()

        if let session = model.session, session.isGenerating {
          if queuedCount > 0 {
            Text("대기 \(queuedCount)개 · 빈 입력에서 Enter: 중단하고 바로 보내기")
              .font(.caption).foregroundStyle(.secondary)
          }
          Button("중단", systemImage: "stop.fill") { model.stop() }
            .keyboardShortcut(".", modifiers: .command)
          Button(hasText ? "대기열에 추가" : "지금 보내기", systemImage: hasText ? "text.badge.plus" : "paperplane.fill") { send() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!hasText && queuedCount == 0)
        } else if isGenerating {
          // 다른 대화가 생성 중이다. 전송은 완료 후 가능하다.
          Button("중단", systemImage: "stop.fill") { model.stop() }
            .keyboardShortcut(".", modifiers: .command)
        } else {
          Button("보내기", systemImage: "paperplane.fill") { send() }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
        }
      }
      .font(.callout)
    }
    .padding(12)
    .onAppear { syncDefaults() }
    .onChange(of: model.composerFocusTick) { _, _ in focused = true }
    .onChange(of: model.codex.models.count) { _, _ in syncDefaults() }
    .onChange(of: model.codex.state) { _, _ in syncDefaults() }
    .onChange(of: model.session?.id) { _, _ in syncFromSession() }
    .onChange(of: selectedModel) { _, new in
      guard let m = model.codex.models.first(where: { $0.id == new }) else { return }
      if !m.efforts.contains(selectedEffort) { selectedEffort = "" }
    }
  }

  private func send() {
    model.send(model: selectedModel, effort: selectedEffort.isEmpty ? nil : selectedEffort)
    focused = true
  }

  private func syncDefaults() {
    if selectedModel.isEmpty || !model.codex.models.contains(where: { $0.id == selectedModel }) {
      selectedModel = model.defaultModel
      selectedEffort = model.defaultEffort ?? ""
    }
    syncFromSession()
  }

  private func syncFromSession() {
    guard let session = model.session else { return }
    if let m = session.conversation.model, model.codex.models.contains(where: { $0.id == m }) { selectedModel = m }
    selectedEffort = session.conversation.effort ?? ""
  }

  private func effortLabel(_ effort: String) -> String {
    switch effort {
    case "low": return "낮음"
    case "medium": return "보통"
    case "high": return "높음"
    case "xhigh": return "매우 높음"
    default: return effort
    }
  }
}
