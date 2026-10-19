import Foundation
import SwiftStreamingMarkdown

/// 완성된 Markdown 문자열을 청크 단위로 잘라 흘려보내는 가짜 스트림.
/// 실제 앱에서는 codex app-server의 delta 이벤트가 이 자리를 대신한다.
final class StreamSimulator: ObservableObject, StreamedMarkdownSource {
  let text: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private var task: Task<Void, Never>?

  @Published private(set) var snapshot: String = ""
  @Published private(set) var isFinished = false
  @Published private(set) var elapsed: TimeInterval = 0

  init() {
    var cont: AsyncStream<String>.Continuation!
    text = AsyncStream { cont = $0 }
    continuation = cont
  }

  func start(full: String, chunkSize: Int, intervalMs: Int) {
    task?.cancel()
    let start = Date()
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      var index = full.startIndex
      while index < full.endIndex {
        if Task.isCancelled { break }
        let next = full.index(index, offsetBy: chunkSize, limitedBy: full.endIndex) ?? full.endIndex
        index = next
        let current = String(full[full.startIndex..<index])
        self.snapshot = current
        self.elapsed = Date().timeIntervalSince(start)
        self.continuation.yield(current)
        try? await Task.sleep(for: .milliseconds(intervalMs))
      }
      self.elapsed = Date().timeIntervalSince(start)
      self.isFinished = true
      self.continuation.finish()
    }
  }

  func stop() {
    task?.cancel()
    isFinished = true
    continuation.finish()
  }

  deinit {
    task?.cancel()
    continuation.finish()
  }
}
