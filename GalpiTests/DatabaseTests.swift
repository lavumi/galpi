import XCTest
import SwiftStreamingMarkdown
@testable import Galpi

final class MarkdownTildeTests: XCTestCase {
  func testCitationDirectiveBecomesFileLink() {
    let input = "명시되어 있습니다. :codex-file-citation{path=\"/Users/lavumi/Downloads/MRP-2000 사용자 설명서v1.3.pdf\" purpose=\"source\"}"
    let output = Citations.render(input)
    XCTAssertFalse(output.contains(":codex-file-citation"))
    XCTAssertTrue(output.contains("[MRP-2000 사용자 설명서v1.3.pdf](file:///Users/lavumi/Downloads/MRP-2000%20"))
    XCTAssertEqual(Citations.trimmingIncompleteDirective("본문 :codex-file-citation{path=\"/a"), "본문 ")
    XCTAssertEqual(Citations.trimmingIncompleteDirective("1~2 범위"), "1~2 범위")
  }

  func testLoneTildeIsEscapedButCodeAndStrikethroughAreKept() {
    XCTAssertEqual(
      MarkdownParserImpl.escapingLoneTildes(in: "보통 100~1,000Hz로, GPS의 1~20Hz보다 높다"),
      "보통 100\\~1,000Hz로, GPS의 1\\~20Hz보다 높다")
    XCTAssertEqual(
      MarkdownParserImpl.escapingLoneTildes(in: "\u{60}~/.codex\u{60} 는 그대로, ~~지움~~ 도 그대로"),
      "\u{60}~/.codex\u{60} 는 그대로, ~~지움~~ 도 그대로")
    XCTAssertEqual(
      MarkdownParserImpl.escapingLoneTildes(in: "\u{60}\u{60}\u{60}\na ~ b\n\u{60}\u{60}\u{60}\n범위 1~2"),
      "\u{60}\u{60}\u{60}\na ~ b\n\u{60}\u{60}\u{60}\n범위 1\\~2")
  }
}

final class DatabaseTests: XCTestCase {
  func testTrashRestoreAndSearch() throws {
    let db = try Database.inMemory()
    var a = Conversation.new(title: "Swift 액터 설계", model: "m", effort: nil)
    var b = Conversation.new(title: "두 번째", model: "m", effort: nil)
    try db.save(a); try db.save(b)
    let m = Message.new(conversationId: b.id, ordinal: 0, role: .assistant, text: "SQLite 트라이그램 검색 설명", status: .complete, model: nil)
    try db.save(m, touching: b)

    XCTAssertEqual(try db.conversations(scope: .all, query: "").count, 2)
    let hits = try db.conversations(scope: .all, query: "트라이그램")
    XCTAssertEqual(hits.count, 1)
    XCTAssertEqual(hits.first?.conversation.id, b.id)
    XCTAssertNotNil(hits.first?.snippet)
    XCTAssertEqual(try db.conversations(scope: .all, query: "액터").first?.conversation.id, a.id)

    try db.moveToTrash(ids: [a.id])
    XCTAssertEqual(try db.conversations(scope: .all, query: "").count, 1)
    XCTAssertEqual(try db.conversations(scope: .trash, query: "").count, 1)
    XCTAssertEqual(try db.conversations(scope: .all, query: "액터").count, 0)
    try db.restore(ids: [a.id])
    XCTAssertEqual(try db.conversations(scope: .all, query: "").count, 2)
    try db.deletePermanently(ids: [b.id])
    XCTAssertEqual(try db.messages(conversationId: b.id).count, 0)
    a.title = "x"; b.title = "y"
  }

  func testStreamingRecovery() throws {
    let db = try Database.inMemory()
    let c = Conversation.new(title: "t", model: nil, effort: nil)
    try db.save(c)
    try db.save(Message.new(conversationId: c.id, ordinal: 0, role: .assistant, text: "부분", status: .streaming, model: nil), touching: c)
    try db.recoverStreamingMessages()
    XCTAssertEqual(try db.messages(conversationId: c.id).first?.status, .interrupted)
  }

  func testContextBudgetDropsOldestPairs() {
    let long = String(repeating: "가", count: 1000)
    var messages: [Message] = []
    for i in 0..<10 {
      messages.append(Message.new(conversationId: "c", ordinal: i * 2, role: .user, text: long, status: .complete, model: nil))
      messages.append(Message.new(conversationId: "c", ordinal: i * 2 + 1, role: .assistant, text: long, status: .complete, model: nil))
    }
    let selection = ContextBudget.select(messages: messages, prompt: "q", contextWindow: 10_000)
    XCTAssertGreaterThan(selection.droppedTurns, 0)
    XCTAssertEqual(selection.items.first?.role, .user)
    XCTAssertLessThanOrEqual(selection.estimatedTokens, selection.budget)
  }

  func testBranchTitle() {
    XCTAssertEqual(AppModel.branchTitle("제목"), "제목 (2)")
    XCTAssertEqual(AppModel.branchTitle("제목 (2)"), "제목 (3)")
  }
}
