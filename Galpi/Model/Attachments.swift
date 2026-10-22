import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// 입력창에 붙은 전송 전 첨부. 이미지는 파일 경로로 모델에 전달하고,
/// PDF·텍스트 파일은 추출한 내용을 프롬프트에 포함한다.
struct ComposerAttachment: Identifiable, Equatable {
  enum Kind { case image, document }
  let id: String
  let kind: Kind
  let filename: String
  /// 이미지: 전송할 파일 경로. 붙여넣은 이미지는 임시 디렉토리에 먼저 저장된다.
  var path: String
  /// PDF·텍스트 파일에서 추출한 내용.
  let extractedText: String?
}

extension AppModel {
  private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"]
  private static let maxExtractedChars = 60_000

  private var stagingDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("GalpiAttachments", isDirectory: true)
  }

  /// 클립보드 내용(파일 URL 또는 이미지 비트맵)을 첨부로 추가한다.
  func pasteAttachmentsFromPasteboard() {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
      for url in urls where url.isFileURL { addAttachment(fileURL: url) }
      return
    }
    if let data = pasteboard.data(forType: .png) {
      addAttachment(imageData: data)
    } else if let tiff = pasteboard.data(forType: .tiff),
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) {
      addAttachment(imageData: png)
    }
  }

  /// 클립보드에서 온 이미지 비트맵. 전송 전까지 임시 디렉토리에 둔다.
  func addAttachment(imageData: Data) {
    do {
      try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
      let id = UUID().uuidString
      let url = stagingDirectory.appendingPathComponent("\(id).png")
      try imageData.write(to: url)
      pendingAttachments.append(ComposerAttachment(id: id, kind: .image, filename: "클립보드 이미지.png", path: url.path, extractedText: nil))
    } catch {
      lastError = "이미지를 임시 저장하지 못했습니다: \(error.localizedDescription)"
    }
  }

  func addAttachment(fileURL: URL) {
    let ext = fileURL.pathExtension.lowercased()
    let name = fileURL.lastPathComponent
    if Self.imageExtensions.contains(ext) {
      pendingAttachments.append(ComposerAttachment(id: UUID().uuidString, kind: .image, filename: name, path: fileURL.path, extractedText: nil))
      return
    }
    if ext == "pdf" {
      guard let document = PDFDocument(url: fileURL) else {
        lastError = "PDF를 열지 못했습니다: \(name)"
        return
      }
      let content = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
      pendingAttachments.append(ComposerAttachment(id: UUID().uuidString, kind: .document, filename: name, path: fileURL.path, extractedText: Self.capped(content)))
      return
    }
    // 그 외에는 텍스트 파일로 시도한다.
    if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
      pendingAttachments.append(ComposerAttachment(id: UUID().uuidString, kind: .document, filename: name, path: fileURL.path, extractedText: Self.capped(content)))
    } else {
      lastError = "지원하지 않는 파일 형식입니다: \(name)"
    }
  }

  func removeAttachment(id: String) {
    pendingAttachments.removeAll { $0.id == id }
  }

  private static func capped(_ text: String) -> String {
    text.count > maxExtractedChars ? String(text.prefix(maxExtractedChars)) + "\n…(잘림)" : text
  }

  /// 전송 직전 호출. 저장 대화의 붙여넣은 이미지는 앱 데이터 폴더로 옮겨 영구 보관한다.
  /// 기록 안 남기기 대화는 임시 디렉토리 경로를 그대로 써서 디스크에 흔적을 늘리지 않는다.
  func finalizeAttachments(_ attachments: [ComposerAttachment], ephemeral: Bool) -> [ComposerAttachment] {
    guard !ephemeral else { return attachments }
    let store = supportDirectory.appendingPathComponent("attachments", isDirectory: true)
    return attachments.map { attachment in
      guard attachment.kind == .image, attachment.path.hasPrefix(stagingDirectory.path) else { return attachment }
      var moved = attachment
      do {
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let destination = store.appendingPathComponent((attachment.path as NSString).lastPathComponent)
        try FileManager.default.moveItem(atPath: attachment.path, toPath: destination.path)
        moved.path = destination.path
      } catch {
        // 옮기지 못하면 임시 경로 그대로 보낸다. 전송은 막지 않는다.
      }
      return moved
    }
  }

  /// 저장·재주입용 본문. 이미지 마커와 문서 내용을 프롬프트 뒤에 붙인다.
  static func composeText(prompt: String, attachments: [ComposerAttachment]) -> String {
    var text = prompt
    for attachment in attachments {
      switch attachment.kind {
      case .image:
        text += "\n\n[이미지 첨부: \(attachment.path)]"
      case .document:
        text += "\n\n[첨부: \(attachment.filename)]\n\u{60}\u{60}\u{60}\n\(attachment.extractedText ?? "")\n\u{60}\u{60}\u{60}"
      }
    }
    return text
  }

  /// 본문에서 이미지 마커를 찾아 경로 목록을 돌려준다.
  static func imageAttachmentPaths(in text: String) -> [String] {
    text.split(separator: "\n").compactMap { line in
      guard line.hasPrefix("[이미지 첨부: "), line.hasSuffix("]") else { return nil }
      return String(line.dropFirst("[이미지 첨부: ".count).dropLast())
    }
  }

  /// 이미지 마커 줄을 뺀 표시용 본문.
  static func displayText(of text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !($0.hasPrefix("[이미지 첨부: ") && $0.hasSuffix("]")) }
      .joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
