import Foundation

/// Codex 가 파일 출처를 표시할 때 내보내는 \u{60}:codex-file-citation{...}\u{60} 지시문을
/// 파일명이 보이는 마크다운 링크로 바꾼다. 공식 클라이언트는 이를 배지로 그리지만
/// 갈피는 일반 마크다운 렌더러를 쓰므로 여기서 치환한다.
enum Citations {
  private static let directive = try! NSRegularExpression(pattern: ":codex-file-citation\\{([^{}]*)\\}")
  private static let pathAttribute = try! NSRegularExpression(pattern: "path=\"([^\"]*)\"")
  private static let incompleteTail = try! NSRegularExpression(pattern: ":codex[a-z-]*(\\{[^{}]*)?$")

  static func render(_ text: String) -> String {
    guard text.contains(":codex-file-citation") else { return text }
    let ns = text as NSString
    var result = text
    // 뒤에서부터 치환해 앞 매치의 범위가 틀어지지 않게 한다.
    for match in directive.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
      let attributes = ns.substring(with: match.range(at: 1))
      let attributesNS = attributes as NSString
      guard let pathMatch = pathAttribute.firstMatch(in: attributes, range: NSRange(location: 0, length: attributesNS.length)) else { continue }
      let path = attributesNS.substring(with: pathMatch.range(at: 1))
      let name = (path as NSString).lastPathComponent
      let link = "[\(name)](\(URL(fileURLWithPath: path).absoluteString))"
      result = (result as NSString).replacingCharacters(in: match.range, with: link)
    }
    return result
  }

  /// 스트리밍 중 아직 닫히지 않은 지시문 꼬리를 감춘다. 다음 델타에서 완성되면 render 가 치환한다.
  static func trimmingIncompleteDirective(_ text: String) -> String {
    let ns = text as NSString
    guard let match = incompleteTail.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return text }
    return ns.substring(to: match.range.location)
  }
}
