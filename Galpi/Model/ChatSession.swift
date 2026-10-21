import Foundation
import Observation

/// 화면에 열린 대화 하나의 상태. 기록 안 남기기 대화는 DB 없이 메모리에만 존재한다.
@MainActor
@Observable
final class ChatSession: Identifiable {
  var conversation: Conversation
  var messages: [Message]
  let isEphemeral: Bool
  var streaming: StreamingMessage?
  var streamingMessageId: String?
  var errorMessage: String?
  var contextNotice: String?
  var lastInputTokens: Int?
  var contextWindow: Int?
  /// 이 대화가 쓰고 있는 Codex 임시 스레드. 앱이 떠 있는 동안만 유지하고 저장하지 않는다.
  /// nil 이면 다음 전송 때 새 스레드를 만들어 기록을 주입한다.
  var threadID: String?

  nonisolated var id: String { conversationId }
  private let conversationId: String

  init(conversation: Conversation, messages: [Message], isEphemeral: Bool) {
    self.conversation = conversation
    self.messages = messages
    self.isEphemeral = isEphemeral
    self.conversationId = conversation.id
    self.lastInputTokens = conversation.lastInputTokens
    self.contextWindow = conversation.contextWindow
  }

  var isGenerating: Bool { streaming != nil }

  var contextUsageText: String? {
    guard let lastInputTokens else { return nil }
    let window = contextWindow ?? ContextBudget.fallbackContextWindow
    let percent = min(100, Int(Double(lastInputTokens) / Double(window) * 100))
    return "문맥 \(lastInputTokens.formatted()) / \(window.formatted()) 토큰 (\(percent)%)"
  }
}
