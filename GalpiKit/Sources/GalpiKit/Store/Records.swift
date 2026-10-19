import Foundation
import GRDB

enum MessageRole: String, Codable {
  case user, assistant
}

enum MessageStatus: String, Codable {
  case complete, streaming, interrupted, failed
}

struct Conversation: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "conversation"

  var id: String
  var title: String
  var folderId: String?
  var createdAt: Date
  var updatedAt: Date
  var isFavorite: Bool
  var isArchived: Bool
  var deletedAt: Date?
  var model: String?
  var effort: String?
  var originId: String?
  var lastInputTokens: Int?
  var contextWindow: Int?
  var preview: String

  static func new(title: String, model: String?, effort: String?) -> Conversation {
    let now = Date()
    return Conversation(
      id: UUID().uuidString, title: title, folderId: nil, createdAt: now, updatedAt: now,
      isFavorite: false, isArchived: false, deletedAt: nil, model: model, effort: effort,
      originId: nil, lastInputTokens: nil, contextWindow: nil, preview: "")
  }
}

struct Message: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "message"

  var id: String
  var conversationId: String
  var ordinal: Int
  var role: MessageRole
  var text: String
  var status: MessageStatus
  var createdAt: Date
  var inputTokens: Int?
  var outputTokens: Int?
  var model: String?

  static func new(conversationId: String, ordinal: Int, role: MessageRole, text: String, status: MessageStatus, model: String?) -> Message {
    Message(id: UUID().uuidString, conversationId: conversationId, ordinal: ordinal, role: role, text: text,
            status: status, createdAt: Date(), inputTokens: nil, outputTokens: nil, model: model)
  }
}

struct Folder: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "folder"
  var id: String
  var name: String
  var sortOrder: Int
}

struct Tag: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "tag"
  var id: String
  var name: String
}

struct ConversationTag: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "conversationTag"
  var conversationId: String
  var tagId: String
}

/// 검색 결과 한 줄: 대화와 일치한 메시지 일부.
struct SearchHit: Identifiable, Hashable {
  var id: String { conversation.id }
  let conversation: Conversation
  let snippet: String?
  let messageId: String?
}
