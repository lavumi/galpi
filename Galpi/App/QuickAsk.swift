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

  private func show() {
    guard let model else { return }
    if panel == nil {
      let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 96),
                           styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                           backing: .buffered, defer: false)
      p.titleVisibility = .hidden
      p.titlebarAppearsTransparent = true
      p.standardWindowButton(.closeButton)?.isHidden = true
      p.standardWindowButton(.miniaturizeButton)?.isHidden = true
      p.standardWindowButton(.zoomButton)?.isHidden = true
      p.level = .floating
      p.collectionBehavior = [.canJoinAllSpaces, .transient]
      p.isMovableByWindowBackground = true
      p.isReleasedWhenClosed = false
      panel = p
    }
    // 열 때마다 새 뷰를 만들어 입력과 포커스를 초기화한다.
    panel?.contentView = NSHostingView(rootView: QuickAskView(onClose: { [weak self] in self?.close() }).environment(model))
    if let screen = NSScreen.main, let panel {
      let frame = panel.frame
      let x = screen.visibleFrame.midX - frame.width / 2
      let y = screen.visibleFrame.minY + screen.visibleFrame.height * 0.68
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
          .lineLimit(1...4)
          .focused($focused)
          .onSubmit(submit)
      }
      Text("Enter: 기록 안 남기는 새 대화로 전송 · 저장은 대화 화면에서 · Esc: 닫기")
        .font(.caption).foregroundStyle(.tertiary)
    }
    .padding(16)
    .frame(width: 560)
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
    // 퀵챗은 항상 기록 안 남기기로 시작한다. 저장은 대화 화면의 "이 대화 저장" 으로 한다.
    model.newPrivateChat()
    model.composerText = prompt
    model.send(model: "", effort: nil)
    onClose()
    NSApp.activate(ignoringOtherApps: true)
    // NSApp.windows 전체를 올리면 숨어 있던 설정 창 등이 빈 창으로 딸려 나온다. 보이는 메인 창만 앞으로 가져온다.
    if let main = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible && $0.canBecomeMain }) {
      main.makeKeyAndOrderFront(nil)
    }
  }
}
