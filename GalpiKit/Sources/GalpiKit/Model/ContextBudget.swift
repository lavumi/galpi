import Foundation

/// 토크나이저 없이 쓰는 보수적 추정. 한글 1자 ≈ 1토큰, 그 외 4자 ≈ 1토큰.
enum ContextBudget {
  static let fallbackContextWindow = 128_000
  static let usableRatio = 0.7

  static func estimateTokens(_ text: String) -> Int {
    var hangul = 0
    var other = 0
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
      default: other += 1
      }
    }
    return hangul + (other + 3) / 4
  }

  struct Selection {
    let items: [TurnHistoryItem]
    let droppedTurns: Int
    let estimatedTokens: Int
    let budget: Int
  }

  /// 완결된 최근 턴부터 예산 안에 넣고, 넘치면 오래된 턴을 제외한다. 사용자·답변 쌍 단위로 자른다.
  static func select(messages: [Message], prompt: String, contextWindow: Int?) -> Selection {
    let budget = Int(Double(contextWindow ?? fallbackContextWindow) * usableRatio)
    var remaining = budget - estimateTokens(prompt)
    // 뒤에서부터 user/assistant 쌍을 묶어 넣는다.
    var pairs: [[Message]] = []
    var current: [Message] = []
    for message in messages {
      if message.role == .user, !current.isEmpty {
        pairs.append(current)
        current = []
      }
      current.append(message)
    }
    if !current.isEmpty { pairs.append(current) }
    var selectedPairs: [[Message]] = []
    for pair in pairs.reversed() {
      let cost = pair.reduce(0) { $0 + estimateTokens($1.text) }
      guard cost <= remaining else { break }
      selectedPairs.insert(pair, at: 0)
      remaining -= cost
    }
    let items = selectedPairs.flatMap { $0 }.map { TurnHistoryItem(role: $0.role == .user ? .user : .assistant, text: $0.text) }
    return Selection(items: items, droppedTurns: pairs.count - selectedPairs.count, estimatedTokens: budget - remaining, budget: budget)
  }
}
