//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License. See LICENSE in the project root for license information.
//

import Markdown

/// The built-in `MarkdownParser` implementation.
public final class MarkdownParserImpl: MarkdownParser {

  private let rewriters: [MarkupPostParsingRewriter] = [
    PartialStrongMarkupPostParsingRewriter(),
    PartialTableMarkupPostParsingRewriter()
  ]

  private let imageBlockRewriter = ImageBlockMarkupPostParsingRewriter()

  private let latexPreprocessor: LaTexPreProcessor

  /// Create a new parser instance using the default LaTeX preprocessor.
  public init() {
    self.latexPreprocessor = LaTexPreProcessorImpl()
  }

  /// Parse `text` into a `MarkdownParseResult`. See `MarkdownParser.parse(text:option:)`.
  public func parse(text: String, option: MarkdownParseOption) async -> MarkdownParseResult {
    let targetString = Self.escapingLoneTildes(
      in: latexPreprocessor.process(input: text, matchingRules: option.latexMatchingRules))

    var result: MarkdownParseResult = MarkdownParseResult(
      document: Document(parsing: targetString),
      speculativeRewritten: false
    )

    if option.speculativeRewrite {
      for rewriter in rewriters {
        if let rewrittenDoc = rewriter.rewriteIfApplicable(document: result.document) {
          result = MarkdownParseResult(document: rewrittenDoc, speculativeRewritten: true)
        }
      }
    }

    if option.imageSupport {
      if let rewrittenDoc = imageBlockRewriter.rewriteIfApplicable(document: result.document) {
        result = MarkdownParseResult(
          document: rewrittenDoc,
          speculativeRewritten: result.speculativeRewritten
        )
      }
    }
    return result
  }

  // Galpi patch: cmark-gfm 은 물결표 하나도 취소선 구분자로 받아서
  // 한국어 범위 표기(100~1,000Hz)가 취소선으로 깨진다. 코드 펜스와 인라인 코드 밖의
  // 외톨이 ~ 를 이스케이프해 취소선은 ~~ 두 개일 때만 적용되게 한다.
  public static func escapingLoneTildes(in markdown: String) -> String {
    guard markdown.contains("~") else { return markdown }
    var result: [String] = []
    var fenceDelimiter: Character?
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.drop(while: { $0 == " " })
      if let delimiter = fenceDelimiter {
        result.append(String(line))
        if trimmed.hasPrefix(String(repeating: String(delimiter), count: 3)) { fenceDelimiter = nil }
        continue
      }
      if trimmed.hasPrefix("\u{60}\u{60}\u{60}") || trimmed.hasPrefix("~~~") {
        fenceDelimiter = trimmed.first
        result.append(String(line))
        continue
      }
      result.append(Self.escapeLoneTildesOutsideInlineCode(String(line)))
    }
    return result.joined(separator: "\n")
  }

  private static func escapeLoneTildesOutsideInlineCode(_ line: String) -> String {
    guard line.contains("~") else { return line }
    var output = ""
    var index = line.startIndex
    var codeDelimiterLength = 0
    while index < line.endIndex {
      let character = line[index]
      if character == "\u{60}" {
        var runEnd = index
        var runLength = 0
        while runEnd < line.endIndex, line[runEnd] == "\u{60}" {
          runLength += 1
          runEnd = line.index(after: runEnd)
        }
        output += String(repeating: "\u{60}", count: runLength)
        if codeDelimiterLength == 0 {
          codeDelimiterLength = runLength
        } else if runLength == codeDelimiterLength {
          codeDelimiterLength = 0
        }
        index = runEnd
        continue
      }
      if character == "~", codeDelimiterLength == 0 {
        var runEnd = index
        var runLength = 0
        while runEnd < line.endIndex, line[runEnd] == "~" {
          runLength += 1
          runEnd = line.index(after: runEnd)
        }
        output += runLength == 1 ? "\\~" : String(repeating: "~", count: runLength)
        index = runEnd
        continue
      }
      output.append(character)
      index = line.index(after: index)
    }
    return output
  }
}
