import AppKit
import Carbon.HIToolbox
import SwiftUI

/// .nonactivatingPanel 스타일은 기본적으로 key window 가 되지 못해 입력 포커스를 받지 못한다.
private final class KeyablePanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// Cmd+Shift+Space 전역 핫키로 여닫는 빠른 질문 패널.
/// Carbon 핫키는 접근성 권한 없이 동작한다. 앱이 실행 중일 때만 유효하다.
@MainActor
final class QuickAskController {
  static let shared = QuickAskController()
  private var panel: NSPanel?
  private var hotKeyRef: EventHotKeyRef?
  private weak var model: AppModel?
  /// 메인 창이 닫혀 있을 때 다시 열기 위한 openWindow 액션. MainView 가 등록한다.
  var openMainWindow: (() -> Void)?

  func setup(model: AppModel) {
    guard self.model == nil else { return }
    self.model = model
    var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
      Task { @MainActor in QuickAskController.shared.toggle() }
      return noErr
    }, 1, &eventType, nil, nil)
    let hotKeyID = EventHotKeyID(signature: OSType(0x47_50_4C_51), id: 1) // "GPLQ"
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
  }

  func toggle() {
    if let panel, panel.isVisible {
      close()
    } else {
      show()
    }
  }

  func close() {
    panel?.orderOut(nil)
  }

  /// 입력 줄 수에 맞춰 패널을 키운다. 아래 모서리를 고정하고 위로 자란다.
  func resize(to size: CGSize) {
    guard let panel, panel.isVisible, size.height > 0 else { return }
    var frame = panel.frame
    guard abs(frame.height - size.height) > 0.5 || abs(frame.width - size.width) > 0.5 else { return }
    frame.origin.x += (frame.width - size.width) / 2
    frame.size = size
    panel.setFrame(frame, display: true)
  }

  private func show() {
    guard let model else { return }
    if panel == nil {
      // 테두리 없는 패널. titled 스타일은 타이틀바 안전 영역이 콘텐츠 위에 큰 여백을 만든다.
      let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 80),
                           styleMask: [.nonactivatingPanel, .borderless],
                           backing: .buffered, defer: false)
      p.level = .floating
      p.collectionBehavior = [.canJoinAllSpaces, .transient]
      p.isMovableByWindowBackground = true
      p.isReleasedWhenClosed = false
      p.backgroundColor = .clear
      p.isOpaque = false
      p.hasShadow = true
      panel = p
    }
    // 열 때마다 새 뷰를 만들어 입력과 포커스를 초기화한다.
    let hosting = NSHostingView(rootView: QuickAskView(onClose: { [weak self] in self?.close() }).environment(model))
    panel?.contentView = hosting
    panel?.setContentSize(hosting.fittingSize)
    if let screen = NSScreen.main, let panel {
      let frame = panel.frame
      let x = screen.visibleFrame.midX - frame.width / 2
      // 화면 하단 중앙에 고정한다.
      let y = screen.visibleFrame.minY + 32
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    NSApp.activate(ignoringOtherApps: true)
    panel?.makeKeyAndOrderFront(nil)
  }
}

struct QuickAskView: View {
  @Environment(AppModel.self) private var model
  let onClose: () -> Void
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Image(systemName: "bookmark.fill").foregroundStyle(.tint)
        TextField("갈피에 질문하기", text: $text, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.title3)
          .lineLimit(1...15)
          .focused($focused)
          .onSubmit(submit)
          .commandReturnInsertsNewline()
      }
      Text("Enter: 기록 안 남기는 새 대화로 전송 · Cmd+Enter: 줄바꿈 · Esc: 닫기")
        .font(.caption).foregroundStyle(.tertiary)
    }
    .padding(16)
    .frame(width: 560)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    .onGeometryChange(for: CGSize.self) { proxy in
      proxy.size
    } action: { size in
      QuickAskController.shared.resize(to: size)
    }
    .onExitCommand(perform: onClose)
    .onAppear {
      text = ""
      // 창이 key 가 된 다음에 포커스를 줘야 먹는다.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
    }
  }

  private func submit() {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    if let generating = model.generatingSession {
      // 생성 중이면 현재 세션을 건드리지 않고 그 대화의 대기열에 쌓는다. 턴이 끝나면 자동 전송된다.
      generating.queuedPrompts.append(prompt)
      generating.lastEnqueuedAt = Date()
      if generating.isEphemeral {
        model.session = generating
      } else {
        model.selectedId = generating.id
      }
    } else {
      // 퀵챗은 항상 기록 안 남기기로 시작한다. 저장은 대화 화면의 "이 대화 저장" 으로 한다.
      model.newPrivateChat()
      model.composerText = prompt
      model.send(model: "", effort: nil)
    }
    onClose()
    NSApp.activate(ignoringOtherApps: true)
    // NSApp.windows 전체를 올리면 숨어 있던 설정 창 등이 빈 창으로 딸려 나온다. 보이는 메인 창만 앞으로 가져온다.
    if let main = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }) {
      main.makeKeyAndOrderFront(nil)
    } else {
      QuickAskController.shared.openMainWindow?()
    }
  }
}
