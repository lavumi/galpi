import SwiftStreamingMarkdown
import SwiftUI

struct ChatView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 0) {
      if let session = model.session {
        SessionHeader(session: session)
        Divider()
        MessageListView(session: session)
      } else {
        EmptyChatView()
      }
      Divider()
      ComposerView()
    }
    .navigationTitle(model.session?.conversation.title ?? "새 대화")
    .navigationSubtitle(model.session?.isEphemeral == true ? "기록 안 남기기" : "")
  }
}

struct EmptyChatView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: "bookmark").font(.system(size: 40)).foregroundStyle(.tertiary)
      Text("새 대화").font(.title3.weight(.medium))
      Text("기록은 이 Mac에 저장되며, 답변 생성을 위해 대화 내용이 AI 서비스에 전송됩니다.")
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
      if model.nextChatPrivate {
        Label("이 대화는 기록을 남기지 않습니다", systemImage: "eye.slash").font(.callout).foregroundStyle(.orange)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

struct SessionHeader: View {
  @Environment(AppModel.self) private var model
  let session: ChatSession

  var body: some View {
    HStack(spacing: 12) {
      if session.isEphemeral {
        Label("기록 안 남기기", systemImage: "eye.slash").foregroundStyle(.orange)
        Button("이 대화 저장") { model.saveEphemeral() }.disabled(session.isGenerating)
        Button("버리기", role: .destructive) { model.discardEphemeral() }
      } else {
        Label(session.conversation.model ?? "", systemImage: "cpu").foregroundStyle(.secondary)
        Button("기록 안 남기고 이어가기", systemImage: "eye.slash") { model.continuePrivately() }
          .disabled(session.isGenerating)
          .help("문맥을 복사한 새 임시 대화를 엽니다. 이 대화는 그대로 남습니다.")
      }
      Spacer()
      if let usage = session.contextUsageText {
        Text(usage).font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
    }
    .font(.callout)
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }
}

struct MessageListView: View {
  @Environment(AppModel.self) private var model
  let session: ChatSession

  private var config: MarkdownRenderConfig {
    MarkdownRenderConfig.default
      .withShouldAnimateText(value: true)
      .withCodeBlockConfig(value: CodeBlockConfig(theme: .xcode, backgroundColor: Color(nsColor: .textBackgroundColor)))
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 20) {
          if let notice = session.contextNotice {
            Label(notice, systemImage: "scissors").font(.caption).foregroundStyle(.secondary)
          }
          ForEach(session.messages) { message in
            MessageRowView(session: session, message: message, config: config) {
              proxy.scrollTo("bottom", anchor: .bottom)
            }
              .id(message.id)
          }
          if let error = session.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
              .textSelection(.enabled)
          }
          Color.clear.frame(height: 1).id("bottom")
        }
        .padding(20)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .onChange(of: session.messages.count) { _, _ in
        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
      }
      .onChange(of: session.streamingMessageId) { _, new in
        if new == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo("bottom", anchor: .bottom) } }
      }
      .onChange(of: model.pendingScrollMessageId) { _, target in
        guard let target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
          withAnimation { proxy.scrollTo(target, anchor: .center) }
          model.pendingScrollMessageId = nil
        }
      }
      .onAppear {
        if let target = model.pendingScrollMessageId {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            proxy.scrollTo(target, anchor: .center)
            model.pendingScrollMessageId = nil
          }
        } else {
          proxy.scrollTo("bottom", anchor: .bottom)
        }
      }
    }
  }
}

struct MessageRowView: View {
  @Environment(AppModel.self) private var model
  let session: ChatSession
  let message: Message
  let config: MarkdownRenderConfig
  let onGrow: () -> Void
  @State private var copied = false

  private var isStreamingThis: Bool { session.streamingMessageId == message.id && session.streaming != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(message.role == .user ? "나" : "답변").font(.caption.bold()).foregroundStyle(.secondary)
        if isStreamingThis { ProgressView().controlSize(.mini) }
        statusBadge
        Spacer()
        actions
      }
      if message.role == .user {
        Text(message.text)
          .textSelection(.enabled)
          .padding(12)
          .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
      } else if isStreamingThis, let streaming = session.streaming {
        StreamingBody(streaming: streaming, config: config, onGrow: onGrow)
      } else if message.text.isEmpty {
        Text(message.status == .failed ? "답변을 받지 못했습니다." : "비어 있는 답변").foregroundStyle(.secondary).italic()
      } else {
        MarkdownView(text: message.text, config: config)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var statusBadge: some View {
    switch message.status {
    case .interrupted: Text("중단됨").font(.caption2).foregroundStyle(.orange)
    case .failed: Text("실패").font(.caption2).foregroundStyle(.red)
    default: EmptyView()
    }
  }

  @ViewBuilder
  private var actions: some View {
    if !isStreamingThis {
      HStack(spacing: 4) {
        if message.role == .user {
          Button { model.editAsNewConversation(userMessageId: message.id) } label: { Image(systemName: "pencil") }
            .help("수정해서 새 대화로 이어가기")
            .disabled(session.isGenerating)
        } else {
          if message.status == .failed || (message.status == .interrupted && message.text.isEmpty) {
            Button { model.retry(messageId: message.id) } label: { Image(systemName: "arrow.clockwise") }
              .help("다시 보내기")
              .disabled(session.isGenerating)
          }
          Button { model.regenerateAsNewConversation(assistantMessageId: message.id) } label: { Image(systemName: "arrow.triangle.branch") }
            .help("새 대화에서 답변 재생성")
            .disabled(session.isGenerating)
        }
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(message.text, forType: .string)
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
          .help("메시지 복사")
      }
      .buttonStyle(.borderless)
      .foregroundStyle(.secondary)
    }
  }
}

struct StreamingBody: View {
  @ObservedObject var streaming: StreamingMessage
  let config: MarkdownRenderConfig
  let onGrow: () -> Void

  var body: some View {
    Group {
      if streaming.snapshot.isEmpty {
        Text("생각 중…").foregroundStyle(.secondary).italic()
      } else {
        StreamedMarkdownView(source: streaming, config: config)
      }
    }
    .onChange(of: streaming.snapshot.count) { _, _ in onGrow() }
  }
}
