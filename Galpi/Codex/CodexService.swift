import Foundation
import GRDB
import Observation
import os

struct CodexModel: Identifiable, Hashable {
  let id: String
  let displayName: String
  let isDefault: Bool
  let efforts: [String]
  let defaultEffort: String?
}

struct CodexAccount: Equatable {
  let email: String?
  let plan: String?
}

struct RateLimitWindow: Equatable {
  let usedPercent: Int
  let resetsAt: Date?
  let windowMinutes: Int?
}

struct RateLimits: Equatable {
  let primary: RateLimitWindow?
  let secondary: RateLimitWindow?
  let reached: Bool
}

enum ConnectionState: Equatable {
  case idle
  case starting
  case notInstalled
  case needsLogin
  case connected
  case failed(String)

  var label: String {
    switch self {
    case .idle: return "연결 안 됨"
    case .starting: return "연결 중"
    case .notInstalled: return "Codex 미설치"
    case .needsLogin: return "로그인 필요"
    case .connected: return "연결됨"
    case .failed: return "연결 불가"
    }
  }
}

/// 한 턴을 실행하는 동안 UI로 흘러가는 이벤트.
enum TurnEvent {
  /// `reused` 가 true 면 대화가 쓰던 스레드에 턴만 추가한 것이고, false 면 새 스레드를 만들어 기록을 주입한 것이다.
  case started(threadID: String, turnID: String, reused: Bool)
  case delta(String)
  case usage(inputTokens: Int, outputTokens: Int, contextWindow: Int?)
  case completed
  case interrupted
}

struct TurnHistoryItem {
  enum Role { case user, assistant }
  let role: Role
  let text: String
}

enum TurnError: LocalizedError {
  case failed(String)
  case busy

  var errorDescription: String? {
    switch self {
    case .failed(let message): return message
    case .busy: return "다른 답변이 생성 중입니다. 완료되거나 중단된 뒤 보내세요."
    }
  }
}

@MainActor
@Observable
final class CodexService {
  private(set) var state: ConnectionState = .idle
  private(set) var account: CodexAccount?
  private(set) var rateLimits: RateLimits?
  private(set) var models: [CodexModel] = []
  private(set) var executablePath: String?
  private(set) var version: String?

  var isGenerating: Bool { activeTurn != nil }

  private let process = AppServerProcess()
  private let workspace: URL
  private let sqliteHome: URL
  private var listenerTask: Task<Void, Never>?
  /// 단계별 소요 시간만 남긴다. 본문·프롬프트는 절대 넣지 않는다.
  private let log = Logger(subsystem: "com.lavumi.galpi", category: "turn")

  private final class ActiveTurn {
    let continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation
    var threadID: String?
    var turnID: String?
    var interruptRequested = false
    var reused = false
    var turnStartedAt: ContinuousClock.Instant?
    var firstDeltaAt: ContinuousClock.Instant?
    var deltaCount = 0
    var outputChars = 0
    init(continuation: AsyncThrowingStream<TurnEvent, Error>.Continuation) { self.continuation = continuation }
  }
  private var activeTurn: ActiveTurn?

  init(supportDirectory: URL) {
    workspace = supportDirectory.appendingPathComponent("workspace", isDirectory: true)
    sqliteHome = supportDirectory.appendingPathComponent("codex-state", isDirectory: true)
  }

  // MARK: - Connection

  func connect(executableOverride: String?) async {
    guard state != .starting else { return }
    state = .starting
    process.terminate()
    let located = await CodexLocator.locate(override: executableOverride)
    guard let executable = located.executable else {
      state = .notInstalled
      executablePath = nil
      return
    }
    executablePath = executable.path
    do {
      try process.launch(executable: executable, workingDirectory: workspace, sqliteHome: sqliteHome, path: located.path)
      startListening()
      let initResult = try await process.request("initialize", params: [
        "clientInfo": ["name": "galpi", "title": "Galpi", "version": "0.1"],
        "capabilities": ["experimentalApi": false],
      ])
      version = initResult["userAgent"].string
      try process.notify("initialized")
      try await refreshAccount()
      try await refreshModels()
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func disconnect() {
    listenerTask?.cancel()
    listenerTask = nil
    process.terminate()
    state = .idle
  }

  func refreshAccount() async throws {
    let result = try await process.request("account/read", params: ["refreshToken": false])
    let accountJSON = result["account"]
    if accountJSON.isNull {
      account = nil
      state = .needsLogin
      return
    }
    account = CodexAccount(email: accountJSON["email"].string, plan: accountJSON["planType"].string)
    state = .connected
    await refreshRateLimits()
  }

  func refreshRateLimits() async {
    guard let result = try? await process.request("account/rateLimits/read") else { return }
    rateLimits = Self.parseRateLimits(result["rateLimits"])
  }

  func refreshModels() async throws {
    let result = try await process.request("model/list", params: ["includeHidden": false])
    models = result["data"].array.compactMap { item in
      guard let id = item["id"].string else { return nil }
      let efforts = item["supportedReasoningEfforts"].array.compactMap { $0["reasoningEffort"].string }
      return CodexModel(
        id: id,
        displayName: item["displayName"].string ?? id,
        isDefault: item["isDefault"].bool ?? false,
        efforts: efforts,
        defaultEffort: item["defaultReasoningEffort"].string
      )
    }
  }

  // MARK: - Turns

  /// 대화가 쓰던 스레드(`threadID`)가 있으면 거기에 턴만 추가한다. 없거나 실패하면 새 임시 스레드를 만들고
  /// `history` 를 주입한 뒤 턴을 시작한다. 동시 생성은 한 개로 제한한다.
  func runTurn(reusingThread threadID: String?, history: [TurnHistoryItem], prompt: String, model: String, effort: String?) -> AsyncThrowingStream<TurnEvent, Error> {
    AsyncThrowingStream { continuation in
      guard activeTurn == nil else {
        continuation.finish(throwing: TurnError.busy)
        return
      }
      let turn = ActiveTurn(continuation: continuation)
      activeTurn = turn
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          guard let self, self.activeTurn === turn else { return }
          self.activeTurn = nil
        }
      }
      Task { await self.start(turn, reusing: threadID, history: history, prompt: prompt, model: model, effort: effort) }
    }
  }

  func interrupt() {
    guard let turn = activeTurn else { return }
    turn.interruptRequested = true
    guard let threadID = turn.threadID, let turnID = turn.turnID else { return }
    Task { _ = try? await process.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID]) }
  }

  /// 기록 안 남기기 대화가 끝나면 앱 전용 sqlite_home 의 Codex 로그에서 해당 스레드 행을 지운다.
  func purgeLogs(threadID: String) {
    let logsPath = sqliteHome.appendingPathComponent("logs_2.sqlite").path
    Task.detached(priority: .utility) {
      guard FileManager.default.fileExists(atPath: logsPath) else { return }
      guard let queue = try? GRDB.DatabaseQueue(path: logsPath) else { return }
      _ = try? queue.write { db in
        try db.execute(sql: "DELETE FROM logs WHERE thread_id = ?", arguments: [threadID])
      }
    }
  }

  private func start(_ turn: ActiveTurn, reusing existing: String?, history: [TurnHistoryItem], prompt: String, model: String, effort: String?) async {
    do {
      guard state == .connected else { throw TurnError.failed("Codex에 연결되어 있지 않습니다.") }

      if let existing {
        turn.threadID = existing
        if turn.interruptRequested { finish(turn, with: .interrupted); return }
        do {
          try await startTurn(turn, threadID: existing, prompt: prompt, model: model, effort: effort, reused: true)
          return
        } catch {
          // 스레드가 사라졌거나(app-server 재시작 등) 상태가 틀어진 경우. 새 스레드로 한 번 더 간다.
          log.notice("turn/start on reused thread failed, falling back to a fresh thread: \(error.localizedDescription, privacy: .public)")
          turn.threadID = nil
          turn.turnID = nil
        }
      }

      let clock = ContinuousClock()
      var mark = clock.now
      let threadResult = try await process.request("thread/start", params: [
        "model": model,
        "cwd": workspace.path,
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "ephemeral": true,
      ])
      guard let threadID = threadResult["thread"]["id"].string else {
        throw TurnError.failed("Codex가 스레드를 만들지 못했습니다.")
      }
      turn.threadID = threadID
      log.notice("thread/start \(Self.ms(since: mark, clock: clock)) ms")
      if turn.interruptRequested { finish(turn, with: .interrupted); return }

      if !history.isEmpty {
        mark = clock.now
        let items: [[String: Any]] = history.map { item in
          let role = item.role == .user ? "user" : "assistant"
          let type = item.role == .user ? "input_text" : "output_text"
          return ["type": "message", "role": role, "content": [["type": type, "text": item.text]]]
        }
        try await process.request("thread/inject_items", params: ["threadId": threadID, "items": items])
        log.notice("thread/inject_items \(Self.ms(since: mark, clock: clock)) ms, \(items.count) items")
      }

      try await startTurn(turn, threadID: threadID, prompt: prompt, model: model, effort: effort, reused: false)
    } catch {
      finish(turn, throwing: error)
    }
  }

  private func startTurn(_ turn: ActiveTurn, threadID: String, prompt: String, model: String, effort: String?, reused: Bool) async throws {
    var params: [String: Any] = [
      "threadId": threadID,
      "model": model,
      "approvalPolicy": "never",
      "sandboxPolicy": ["type": "readOnly"],
      "input": [["type": "text", "text": prompt]],
    ]
    if let effort { params["effort"] = effort }
    turn.reused = reused
    turn.turnStartedAt = ContinuousClock.now
    let turnResult = try await process.request("turn/start", params: params)
    log.notice("turn/start ack \(Self.ms(since: turn.turnStartedAt!)) ms, reusedThread=\(reused), model=\(model, privacy: .public), effort=\(effort ?? "default", privacy: .public)")
    if let turnID = turnResult["turn"]["id"].string, turn.turnID == nil {
      turn.turnID = turnID
      turn.continuation.yield(.started(threadID: threadID, turnID: turnID, reused: reused))
    }
    if turn.interruptRequested { interrupt() }
  }

  private static func ms(since start: ContinuousClock.Instant, clock: ContinuousClock = ContinuousClock()) -> Int {
    let d = start.duration(to: clock.now)
    return Int(d.components.seconds * 1000) + Int(d.components.attoseconds / 1_000_000_000_000_000)
  }

  private func finish(_ turn: ActiveTurn, with event: TurnEvent) {
    turn.continuation.yield(event)
    turn.continuation.finish()
    if activeTurn === turn { activeTurn = nil }
  }

  private func finish(_ turn: ActiveTurn, throwing error: Error) {
    turn.continuation.finish(throwing: error)
    if activeTurn === turn { activeTurn = nil }
  }

  // MARK: - Notifications

  private func startListening() {
    listenerTask?.cancel()
    listenerTask = Task { [weak self] in
      guard let self else { return }
      for await notification in self.process.notifications {
        if Task.isCancelled { return }
        self.handle(notification)
      }
    }
  }

  private func handle(_ notification: AppServerProcess.Notification) {
    let params = notification.params
    switch notification.method {
    case "galpi/processExited":
      let stderr = params["stderr"].string ?? ""
      state = .failed("Codex 프로세스가 종료되었습니다. " + stderr.split(separator: "\n").suffix(2).joined(separator: " "))
      if let turn = activeTurn { finish(turn, throwing: TurnError.failed("Codex 연결이 끊겼습니다.")) }
      return
    case "account/rateLimits/updated":
      rateLimits = Self.parseRateLimits(params["rateLimits"])
      return
    case "account/updated":
      Task { try? await refreshAccount() }
      return
    default:
      break
    }

    guard let turn = activeTurn, let threadID = params["threadId"].string, threadID == turn.threadID else { return }
    switch notification.method {
    case "turn/started":
      if let turnID = params["turn"]["id"].string, turn.turnID == nil {
        turn.turnID = turnID
        turn.continuation.yield(.started(threadID: threadID, turnID: turnID, reused: turn.reused))
        if turn.interruptRequested { interrupt() }
      }
    case "item/agentMessage/delta":
      if let delta = params["delta"].string, !delta.isEmpty {
        if turn.firstDeltaAt == nil {
          turn.firstDeltaAt = ContinuousClock.now
          if let t0 = turn.turnStartedAt { log.notice("first delta \(Self.ms(since: t0)) ms after turn/start") }
        }
        turn.deltaCount += 1
        turn.outputChars += delta.count
        turn.continuation.yield(.delta(delta))
      }
    case "thread/tokenUsage/updated":
      let usage = params["tokenUsage"]
      turn.continuation.yield(.usage(
        inputTokens: usage["last"]["inputTokens"].int ?? 0,
        outputTokens: usage["last"]["outputTokens"].int ?? 0,
        contextWindow: usage["modelContextWindow"].int))
    case "turn/completed":
      if let t0 = turn.turnStartedAt {
        log.notice("turn/completed \(Self.ms(since: t0)) ms, status=\(params["turn"]["status"].string ?? "?", privacy: .public), deltas=\(turn.deltaCount), chars=\(turn.outputChars)")
      }
      switch params["turn"]["status"].string {
      case "completed": finish(turn, with: .completed)
      case "failed":
        finish(turn, throwing: TurnError.failed(params["turn"]["error"]["message"].string ?? "Codex가 답변을 완료하지 못했습니다."))
      default: finish(turn, with: .interrupted)
      }
    case "error":
      guard params["willRetry"].bool != true else { return }
      finish(turn, throwing: TurnError.failed(params["error"]["message"].string ?? "Codex 오류"))
    default:
      break
    }
  }

  // MARK: - Parsing

  private static func parseRateLimits(_ json: JSON) -> RateLimits? {
    guard !json.isNull else { return nil }
    func window(_ j: JSON) -> RateLimitWindow? {
      guard let used = j["usedPercent"].int else { return nil }
      let resets = j["resetsAt"].double.map { Date(timeIntervalSince1970: $0) }
      return RateLimitWindow(usedPercent: used, resetsAt: resets, windowMinutes: j["windowDurationMins"].int)
    }
    return RateLimits(
      primary: window(json["primary"]),
      secondary: window(json["secondary"]),
      reached: !json["rateLimitReachedType"].isNull
    )
  }
}
