import Foundation

/// GUI 앱은 로그인 셸의 PATH를 물려받지 않으므로, 사용자 셸에서 PATH와 codex 위치를 한 번 알아낸다.
enum CodexLocator {
  struct Result {
    let executable: URL?
    let path: String
  }

  nonisolated static func locate(override: String?) async -> Result {
    await Task.detached(priority: .userInitiated) {
      let shellPath = loginShellPath()
      if let override, !override.isEmpty {
        let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        return Result(executable: FileManager.default.isExecutableFile(atPath: url.path) ? url : nil, path: shellPath)
      }
      for dir in shellPath.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("codex")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
          return Result(executable: candidate, path: shellPath)
        }
      }
      return Result(executable: nil, path: shellPath)
    }.value
  }

  private nonisolated static func loginShellPath() -> String {
    let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.npm-global/bin", "/usr/bin", "/bin"].joined(separator: ":")
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lc", "printf %s \"$PATH\""]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return fallback
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? fallback : path + ":" + fallback
  }
}
