import Foundation
import SwiftStreamingMarkdown

/// 수신 중인 답변 버퍼. 뷰가 다시 만들어져도 구독할 수 있도록 구독마다 새 스트림을 만들고 현재 스냅샷을 먼저 보낸다.
final class StreamingMessage: ObservableObject, StreamedMarkdownSource, @unchecked Sendable {
  @Published private(set) var snapshot = ""
  /// 수신한 원문. 스냅샷은 인용 지시문을 치환한 결과라 원문을 따로 쌓는다.
  private var raw = ""
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]
  private var finished = false

  var text: AsyncStream<String> {
    AsyncStream { continuation in
      let id = UUID()
      lock.lock()
      let current = snapshot
      let done = finished
      if !current.isEmpty { continuation.yield(current) }
      if done {
        continuation.finish()
      } else {
        continuations[id] = continuation
      }
      lock.unlock()
      continuation.onTermination = { [weak self] _ in self?.remove(id) }
    }
  }

  @MainActor
  func append(_ delta: String) {
    raw += delta
    snapshot = Citations.render(Citations.trimmingIncompleteDirective(raw))
    let value = snapshot
    lock.lock()
    let targets = Array(continuations.values)
    lock.unlock()
    for c in targets { c.yield(value) }
  }

  @MainActor
  func finish() {
    snapshot = Citations.render(raw)
    lock.lock()
    finished = true
    let targets = Array(continuations.values)
    continuations.removeAll()
    lock.unlock()
    for c in targets { c.finish() }
  }

  private func remove(_ id: UUID) {
    lock.lock()
    continuations.removeValue(forKey: id)
    lock.unlock()
  }
}
