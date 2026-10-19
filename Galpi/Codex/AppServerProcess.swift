import Foundation

/// `codex app-server` 자식 프로세스와 stdio JSON-RPC 로 통신한다.
/// 응답은 요청 ID로 매칭하고, 알림은 `notifications` 스트림으로 흘려보낸다.
@MainActor
final class AppServerProcess {
  enum ProcessError: LocalizedError {
    case notRunning
    case launchFailed(String)
    case exited(status: Int32, stderr: String)
    case rpc(code: Int, message: String)
    case malformed(String)

    var errorDescription: String? {
      switch self {
      case .notRunning: return "Codex 프로세스가 실행 중이 아닙니다."
      case .launchFailed(let detail): return "Codex를 시작하지 못했습니다: \(detail)"
      case .exited(let status, let stderr):
        let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
        return "Codex 프로세스가 종료되었습니다 (code \(status)). \(tail)"
      case .rpc(_, let message): return message
      case .malformed(let detail): return "Codex 응답을 해석하지 못했습니다: \(detail)"
      }
    }
  }

  struct Notification {
    let method: String
    let params: JSON
  }

  let notifications: AsyncStream<Notification>
  private let notificationContinuation: AsyncStream<Notification>.Continuation

  private var process: Process?
  private var stdinHandle: FileHandle?
  private var stdoutBuffer = Data()
  private var stderrBuffer = Data()
  private var nextID = 1
  private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
  private(set) var isRunning = false

  init() {
    var cont: AsyncStream<Notification>.Continuation!
    notifications = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
    notificationContinuation = cont
  }

  /// 사용자 환경(CODEX_HOME, config.toml)은 그대로 쓰되, 상태·로그 DB만 앱 디렉토리로 돌린다.
  func launch(executable: URL, workingDirectory: URL, sqliteHome: URL, path: String) throws {
    if isRunning { return }
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sqliteHome, withIntermediateDirectories: true)

    let process = Process()
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.executableURL = executable
    process.arguments = [
      "-c", "check_for_update_on_startup=false",
      "-c", "sqlite_home=\"\(sqliteHome.path)\"",
      "-c", "history.persistence=\"none\"",
      "-c", "analytics.enabled=false",
      "app-server",
    ]
    process.currentDirectoryURL = workingDirectory
    var env = ProcessInfo.processInfo.environment
    // GUI 앱은 셸 PATH를 물려받지 않으므로 로그인 셸에서 얻은 PATH를 넘긴다 (npm 래퍼가 node를 찾아야 한다).
    env["PATH"] = path
    process.environment = env
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in self?.consumeStdout(data) }
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { @MainActor in self?.consumeStderr(data) }
    }
    process.terminationHandler = { [weak self] proc in
      let status = proc.terminationStatus
      Task { @MainActor in self?.didExit(status: status) }
    }
    do {
      try process.run()
    } catch {
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      throw ProcessError.launchFailed(error.localizedDescription)
    }
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    self.process = process
    self.stdinHandle = stdin.fileHandleForWriting
    isRunning = true
  }

  func terminate() {
    guard let process else { return }
    process.terminationHandler = nil
    process.terminate()
    didExit(status: 0)
  }

  @discardableResult
  func request(_ method: String, params: [String: Any] = [:]) async throws -> JSON {
    guard isRunning, let stdinHandle else { throw ProcessError.notRunning }
    let id = nextID
    nextID += 1
    let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do {
        try stdinHandle.write(contentsOf: data + Data("\n".utf8))
      } catch {
        pending.removeValue(forKey: id)
        continuation.resume(throwing: ProcessError.launchFailed(error.localizedDescription))
      }
    }
  }

  func notify(_ method: String, params: [String: Any] = [:]) throws {
    guard isRunning, let stdinHandle else { throw ProcessError.notRunning }
    let payload: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
    let data = try JSONSerialization.data(withJSONObject: payload)
    try stdinHandle.write(contentsOf: data + Data("\n".utf8))
  }

  // MARK: - Private

  private func consumeStdout(_ data: Data) {
    stdoutBuffer.append(data)
    while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
      let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
      stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
      guard !line.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
      dispatch(JSON(object))
    }
  }

  private func consumeStderr(_ data: Data) {
    stderrBuffer.append(data)
    if stderrBuffer.count > 16_384 { stderrBuffer.removeFirst(stderrBuffer.count - 16_384) }
  }

  private func dispatch(_ message: JSON) {
    if let id = message["id"].int, let continuation = pending.removeValue(forKey: id) {
      if !message["error"].isNull {
        let code = message["error"]["code"].int ?? -1
        let text = message["error"]["message"].string ?? "알 수 없는 오류"
        continuation.resume(throwing: ProcessError.rpc(code: code, message: text))
      } else {
        continuation.resume(returning: message["result"])
      }
      return
    }
    if let method = message["method"].string {
      if !message["id"].isNull {
        // 서버 → 클라이언트 요청(승인 등)은 첫 버전에서 받지 않으므로 모두 거절한다.
        respondToServerRequest(id: message["id"].raw, method: method)
        return
      }
      notificationContinuation.yield(Notification(method: method, params: message["params"]))
    }
  }

  private func respondToServerRequest(id: Any?, method: String) {
    guard let id, let stdinHandle else { return }
    let error: [String: Any] = ["code": -32601, "message": "갈피는 \(method) 요청을 처리하지 않습니다."]
    let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": error]
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
      try? stdinHandle.write(contentsOf: data + Data("\n".utf8))
    }
  }

  private func didExit(status: Int32) {
    guard isRunning else { return }
    isRunning = false
    process = nil
    stdinHandle = nil
    let stderrText = String(decoding: stderrBuffer, as: UTF8.self)
    for (_, continuation) in pending {
      continuation.resume(throwing: ProcessError.exited(status: status, stderr: stderrText))
    }
    pending.removeAll()
    notificationContinuation.yield(Notification(method: "galpi/processExited", params: JSON(["status": Int(status), "stderr": stderrText])))
  }
}
