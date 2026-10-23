# 벤더링 메모

- 원본: https://github.com/microsoft/SwiftStreamingMarkdown
- 기준 커밋: 5f7c04e0558df6146f90d482edb62cb456986bda
- 라이선스: MIT (LICENSE 파일 유지)

## 로컬 패치

1. `Package.swift`: 테스트 타깃과 swift-snapshot-testing 의존성 제거 (Tests 디렉토리를 복사하지 않음).
2. `Sources/MarkdownText/Inline/Markdown+InlineConvertible.swift`: 취소선 텍스트를 보조 라벨 색(회색)으로 표시해 지워진 부분이 본문과 구분되게 함. `// Galpi patch` 주석으로 표시.
3. `Sources/MarkdownText/Parser/MarkdownParserImpl.swift`: cmark-gfm 이 물결표 하나도 취소선으로 해석해 한국어 범위 표기(100~1,000Hz)가 깨지므로, 코드 밖의 외톨이 `~` 를 이스케이프해 `~~` 두 개일 때만 취소선이 되게 함.

업스트림을 올릴 때는 새 커밋을 복사한 뒤 위 패치를 다시 적용한다.
