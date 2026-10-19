import Foundation
import GRDB

/// 앱의 로컬 기록 저장소. 모든 쓰기는 트랜잭션으로 처리한다.
final class Database {
  let queue: DatabaseQueue

  init(path: String) throws {
    var config = Configuration()
    config.foreignKeysEnabled = true
    queue = try DatabaseQueue(path: path, configuration: config)
    try Self.migrator.migrate(queue)
  }

  static func inMemory() throws -> Database {
    try Database(path: ":memory:")
  }

  private static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in
      try db.create(table: "folder") { t in
        t.primaryKey("id", .text)
        t.column("name", .text).notNull()
        t.column("sortOrder", .integer).notNull().defaults(to: 0)
      }
      try db.create(table: "tag") { t in
        t.primaryKey("id", .text)
        t.column("name", .text).notNull().unique()
      }
      try db.create(table: "conversation") { t in
        t.primaryKey("id", .text)
        t.column("title", .text).notNull()
        t.column("folderId", .text).references("folder", onDelete: .setNull)
        t.column("createdAt", .datetime).notNull()
        t.column("updatedAt", .datetime).notNull()
        t.column("isFavorite", .boolean).notNull().defaults(to: false)
        t.column("isArchived", .boolean).notNull().defaults(to: false)
        t.column("deletedAt", .datetime)
        t.column("model", .text)
        t.column("effort", .text)
        t.column("originId", .text)
        t.column("lastInputTokens", .integer)
        t.column("contextWindow", .integer)
        t.column("preview", .text).notNull().defaults(to: "")
      }
      try db.create(indexOn: "conversation", columns: ["updatedAt"])
      try db.create(indexOn: "conversation", columns: ["deletedAt"])
      try db.create(table: "message") { t in
        t.primaryKey("id", .text)
        t.column("conversationId", .text).notNull().references("conversation", onDelete: .cascade)
        t.column("ordinal", .integer).notNull()
        t.column("role", .text).notNull()
        t.column("text", .text).notNull()
        t.column("status", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("inputTokens", .integer)
        t.column("outputTokens", .integer)
        t.column("model", .text)
      }
      try db.create(indexOn: "message", columns: ["conversationId", "ordinal"])
      try db.create(table: "conversationTag") { t in
        t.column("conversationId", .text).notNull().references("conversation", onDelete: .cascade)
        t.column("tagId", .text).notNull().references("tag", onDelete: .cascade)
        t.primaryKey(["conversationId", "tagId"])
      }
    }
    return migrator
  }

  // MARK: - Startup recovery

  /// 비정상 종료로 남은 수신 중 메시지를 중단 상태로 바꾼다.
  func recoverStreamingMessages() throws {
    try queue.write { db in
      try db.execute(sql: "UPDATE message SET status = ? WHERE status = ?",
                     arguments: [MessageStatus.interrupted.rawValue, MessageStatus.streaming.rawValue])
    }
  }

  // MARK: - Conversations

  enum Scope: Hashable {
    case all, favorites, archived, trash
  }

  func conversations(scope: Scope, query: String) throws -> [SearchHit] {
    try queue.read { db in
      var request = Conversation.all()
      switch scope {
      case .all:
        request = request.filter(Column("deletedAt") == nil && Column("isArchived") == false)
      case .favorites:
        request = request.filter(Column("deletedAt") == nil && Column("isFavorite") == true)
      case .archived:
        request = request.filter(Column("deletedAt") == nil && Column("isArchived") == true)
      case .trash:
        request = request.filter(Column("deletedAt") != nil)
      }
      let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        return try request.order(Column("updatedAt").desc).fetchAll(db).map { SearchHit(conversation: $0, snippet: nil, messageId: nil) }
      }
      let normalized = trimmed.precomposedStringWithCanonicalMapping
      let pattern = "%" + normalized.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
      let titleHits = try request
        .filter(sql: "title LIKE ? ESCAPE '\\'", arguments: [pattern])
        .order(Column("updatedAt").desc)
        .fetchAll(db)
      // 본문 일치: 대화당 가장 먼저 일치한 메시지 하나.
      let rows = try Row.fetchAll(db, sql: """
        SELECT c.*, m.id AS hitMessageId, m.text AS hitText
        FROM conversation c
        JOIN message m ON m.conversationId = c.id
        WHERE m.text LIKE ? ESCAPE '\\' AND m.id IN (
          SELECT id FROM message m2 WHERE m2.conversationId = c.id AND m2.text LIKE ? ESCAPE '\\' ORDER BY ordinal LIMIT 1
        )
        ORDER BY c.updatedAt DESC
        """, arguments: [pattern, pattern])
      var seen = Set(titleHits.map(\.id))
      var hits = titleHits.map { SearchHit(conversation: $0, snippet: nil, messageId: nil) }
      for row in rows {
        let conversation = try Conversation(row: row)
        guard Self.matches(conversation, scope: scope), !seen.contains(conversation.id) else { continue }
        seen.insert(conversation.id)
        let text: String = row["hitText"]
        hits.append(SearchHit(conversation: conversation, snippet: Self.snippet(of: text, around: normalized), messageId: row["hitMessageId"]))
      }
      return hits.sorted { $0.conversation.updatedAt > $1.conversation.updatedAt }
    }
  }

  private static func matches(_ c: Conversation, scope: Scope) -> Bool {
    switch scope {
    case .all: return c.deletedAt == nil && !c.isArchived
    case .favorites: return c.deletedAt == nil && c.isFavorite
    case .archived: return c.deletedAt == nil && c.isArchived
    case .trash: return c.deletedAt != nil
    }
  }

  static func snippet(of text: String, around query: String, radius: Int = 40) -> String {
    guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
      return String(text.prefix(radius * 2))
    }
    let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
    var result = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
    if start > text.startIndex { result = "…" + result }
    if end < text.endIndex { result += "…" }
    return result
  }

  func conversation(id: String) throws -> Conversation? {
    try queue.read { db in try Conversation.fetchOne(db, key: id) }
  }

  func messages(conversationId: String) throws -> [Message] {
    try queue.read { db in
      try Message.filter(Column("conversationId") == conversationId).order(Column("ordinal")).fetchAll(db)
    }
  }

  func save(_ conversation: Conversation) throws {
    try queue.write { db in try conversation.save(db) }
  }

  func save(_ message: Message, touching conversation: Conversation) throws {
    try queue.write { db in
      var c = conversation
      c.updatedAt = Date()
      c.preview = Self.preview(of: message.text)
      try c.save(db)
      try message.save(db)
    }
  }

  func update(messageId: String, text: String, status: MessageStatus, inputTokens: Int?, outputTokens: Int?) throws {
    try queue.write { db in
      try db.execute(sql: """
        UPDATE message SET text = ?, status = ?,
          inputTokens = COALESCE(?, inputTokens), outputTokens = COALESCE(?, outputTokens)
        WHERE id = ?
        """, arguments: [text, status.rawValue, inputTokens, outputTokens, messageId])
      try db.execute(sql: """
        UPDATE conversation SET preview = ?, updatedAt = ? WHERE id = (SELECT conversationId FROM message WHERE id = ?)
        """, arguments: [Self.preview(of: text), Date(), messageId])
    }
  }

  /// 목록용 미리보기: 코드 블록과 흔한 Markdown 기호를 걷어낸 한 줄.
  static func preview(of text: String) -> String {
    var s = text
    s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " [코드] ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"[`*_>#]+"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    return String(s.trimmingCharacters(in: .whitespaces).prefix(120))
  }

  func updateContext(conversationId: String, lastInputTokens: Int, contextWindow: Int?) throws {
    try queue.write { db in
      try db.execute(sql: "UPDATE conversation SET lastInputTokens = ?, contextWindow = COALESCE(?, contextWindow) WHERE id = ?",
                     arguments: [lastInputTokens, contextWindow, conversationId])
    }
  }

  // MARK: - Bulk operations (ID 집합 확정 후 한 트랜잭션)

  func setFavorite(_ value: Bool, ids: [String]) throws { try set("isFavorite", value: value, ids: ids) }
  func setArchived(_ value: Bool, ids: [String]) throws { try set("isArchived", value: value, ids: ids) }

  func moveToTrash(ids: [String]) throws {
    try queue.write { db in
      for id in ids {
        try db.execute(sql: "UPDATE conversation SET deletedAt = ? WHERE id = ? AND deletedAt IS NULL", arguments: [Date(), id])
      }
    }
  }

  func restore(ids: [String]) throws {
    try queue.write { db in
      for id in ids {
        try db.execute(sql: "UPDATE conversation SET deletedAt = NULL WHERE id = ?", arguments: [id])
      }
    }
  }

  func deletePermanently(ids: [String]) throws {
    try queue.write { db in
      for id in ids { _ = try Conversation.deleteOne(db, key: id) }
    }
  }

  func emptyTrash() throws -> Int {
    try queue.write { db in
      try Conversation.filter(Column("deletedAt") != nil).deleteAll(db)
    }
  }

  func rename(id: String, title: String) throws {
    try queue.write { db in
      try db.execute(sql: "UPDATE conversation SET title = ? WHERE id = ?", arguments: [title, id])
    }
  }

  func deletePermanentlyMessage(id: String) throws {
    try queue.write { db in _ = try Message.deleteOne(db, key: id) }
  }

  func counts() throws -> (all: Int, favorites: Int, archived: Int, trash: Int) {
    try queue.read { db in
      let all = try Conversation.filter(Column("deletedAt") == nil && Column("isArchived") == false).fetchCount(db)
      let fav = try Conversation.filter(Column("deletedAt") == nil && Column("isFavorite") == true).fetchCount(db)
      let arc = try Conversation.filter(Column("deletedAt") == nil && Column("isArchived") == true).fetchCount(db)
      let trash = try Conversation.filter(Column("deletedAt") != nil).fetchCount(db)
      return (all, fav, arc, trash)
    }
  }

  private func set(_ column: String, value: Bool, ids: [String]) throws {
    try queue.write { db in
      for id in ids {
        try db.execute(sql: "UPDATE conversation SET \(column) = ? WHERE id = ?", arguments: [value, id])
      }
    }
  }
}
