import SwiftStreamingMarkdown
import SwiftUI

struct ChatMessage: Identifiable {
  enum Role { case user, assistant }
  let id = UUID()
  let role: Role
  let text: String
}

struct ContentView: View {
  @State private var messages: [ChatMessage] = [
    ChatMessage(role: .user, text: "Swift 액터로 codex app-server JSON-RPC 클라이언트를 어떻게 설계하면 좋을까?"),
    ChatMessage(role: .assistant, text: SampleMarkdown.shortAnswer),
    ChatMessage(role: .user, text: "좋아. 스트리밍 응답을 SwiftUI에 어떻게 연결하는지 전체 예제로 보여줘."),
  ]
  @State private var streamer: StreamSimulator?
  @State private var streamID = UUID()
  @State private var chunkSize: Double = 12
  @State private var intervalMs: Double = 20
  @State private var animateText = true

  private var config: MarkdownRenderConfig {
    MarkdownRenderConfig.default
      .withShouldAnimateText(value: animateText)
      .withCodeBlockConfig(value: CodeBlockConfig(theme: .xcode, backgroundColor: Color(nsColor: .textBackgroundColor)))
  }

  var body: some View {
    VStack(spacing: 0) {
      controls
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(messages) { message in
              MessageRow(message: message, config: config)
            }
            if let streamer {
              StreamingRow(streamer: streamer, config: config) {
                proxy.scrollTo("bottom", anchor: .bottom)
              }
                .id(streamID)
            }
            Color.clear.frame(height: 1).id("bottom")
          }
          .padding(24)
        }
      }
    }
    .onAppear {
      // 자동화 확인용: SPIKE_AUTOSTART=1 이면 실행 직후 스트리밍을 시작한다.
      if ProcessInfo.processInfo.environment["SPIKE_AUTOSTART"] == "1" {
        startStream()
      }
    }
  }

  private var controls: some View {
    HStack(spacing: 16) {
      if let streamer {
        StreamControls(streamer: streamer, onStart: startStream)
      } else {
        Button("스트리밍 시작", action: startStream)
          .keyboardShortcut(.return, modifiers: .command)
      }

      Button("완료 메시지로 고정") {
        finalizeStream()
      }
      .disabled(streamer == nil)

      LabeledContent("청크") {
        Slider(value: $chunkSize, in: 1...80, step: 1).frame(width: 120)
        Text("\(Int(chunkSize))자").monospacedDigit().frame(width: 40, alignment: .trailing)
      }
      LabeledContent("간격") {
        Slider(value: $intervalMs, in: 5...200, step: 5).frame(width: 120)
        Text("\(Int(intervalMs))ms").monospacedDigit().frame(width: 50, alignment: .trailing)
      }
      Toggle("페이드 애니메이션", isOn: $animateText)
      Spacer()
      if let streamer {
        StreamStatus(streamer: streamer)
      }
    }
    .padding(12)
  }

  private func startStream() {
    let s = StreamSimulator()
    streamer = s
    streamID = UUID()
    s.start(full: SampleMarkdown.longAnswer, chunkSize: Int(chunkSize), intervalMs: Int(intervalMs))
  }

  private func finalizeStream() {
    guard let streamer else { return }
    streamer.stop()
    messages.append(ChatMessage(role: .assistant, text: streamer.snapshot))
    self.streamer = nil
  }
}

// ContentView 는 streamer 를 @State 로만 들고 있어 변경을 관찰하지 않는다.
// 상태에 따라 바뀌는 컨트롤은 @ObservedObject 서브뷰로 분리한다.
struct StreamControls: View {
  @ObservedObject var streamer: StreamSimulator
  let onStart: () -> Void

  var body: some View {
    Button(streamer.isFinished ? "스트리밍 시작" : "중단") {
      if streamer.isFinished { onStart() } else { streamer.stop() }
    }
    .keyboardShortcut(.return, modifiers: .command)
  }
}

struct StreamStatus: View {
  @ObservedObject var streamer: StreamSimulator

  var body: some View {
    Text("\(streamer.snapshot.count) / \(SampleMarkdown.longAnswer.count)자  \(String(format: "%.1f", streamer.elapsed))s")
      .monospacedDigit()
      .foregroundStyle(.secondary)
  }
}

struct MessageRow: View {
  let message: ChatMessage
  let config: MarkdownRenderConfig

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(message.role == .user ? "나" : "답변")
        .font(.caption.bold())
        .foregroundStyle(.secondary)
      if message.role == .user {
        Text(message.text)
          .textSelection(.enabled)
          .padding(12)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      } else {
        MarkdownView(text: message.text, config: config)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct StreamingRow: View {
  @ObservedObject var streamer: StreamSimulator
  let config: MarkdownRenderConfig
  let onGrow: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("답변").font(.caption.bold()).foregroundStyle(.secondary)
        if !streamer.isFinished {
          ProgressView().controlSize(.mini)
        }
      }
      StreamedMarkdownView(source: streamer, config: config)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: streamer.snapshot.count) { _, _ in onGrow() }
  }
}
