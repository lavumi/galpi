import Foundation

/// JSONSerialization 결과([String: Any])를 안전하게 읽기 위한 얇은 래퍼.
struct JSON {
  let raw: Any?

  init(_ raw: Any?) { self.raw = raw }

  subscript(key: String) -> JSON {
    JSON((raw as? [String: Any])?[key])
  }

  subscript(index: Int) -> JSON {
    guard let array = raw as? [Any], array.indices.contains(index) else { return JSON(nil) }
    return JSON(array[index])
  }

  var string: String? { raw as? String }
  var int: Int? {
    if let i = raw as? Int { return i }
    if let d = raw as? Double { return Int(d) }
    return nil
  }
  var double: Double? {
    if let d = raw as? Double { return d }
    if let i = raw as? Int { return Double(i) }
    return nil
  }
  var bool: Bool? { raw as? Bool }
  var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
  var object: [String: Any]? { raw as? [String: Any] }
  var isNull: Bool { raw == nil || raw is NSNull }
}
