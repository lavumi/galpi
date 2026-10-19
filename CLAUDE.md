# 갈피(Galpi) 저장소 규칙

macOS용 개인 AI 대화 앱. 설치된 Codex CLI 의 app-server 를 자식 프로세스로 띄워 ChatGPT 로그인을 그대로 쓰고, 대화 기록은 로컬 SQLite 에 둔다. 제품 방향과 단계별 통과 조건은 `plan.md` 에 있다. 기능 범위나 UX 를 판단해야 하면 그 문서를 먼저 읽는다.

## 구조

```
project.yml          xcodegen 정의. Galpi.xcodeproj 는 여기서 생성하며 커밋하지 않는다.
Galpi/               앱 타깃. @main 진입점과 Assets.xcassets 만 둔다. 로직을 넣지 않는다.
GalpiKit/            SwiftPM 라이브러리. 실제 앱 코드 전부와 테스트.
  Sources/GalpiKit/
    Codex/           app-server 프로세스, JSON-RPC, 연결 상태, 턴 실행
    Store/           GRDB 기반 Database 와 Record 타입, 마이그레이션
    Model/           AppModel(화면 조정자), ChatSession, StreamingMessage, ContextBudget
    Views/           SwiftUI 화면
  Tests/GalpiKitTests/
spike/               단계 0 렌더링 검증용 POC. 참고용으로만 두고 수정하지 않는다.
```

- 앱 타깃이 쓰는 `public` 표면은 `AppModel.bootstrap/start/newChat/reconnect`, `MainView`, `SettingsView` 뿐이다. 그 외는 `internal` 로 두고 테스트는 `@testable import GalpiKit` 으로 접근한다. 새 타입을 `public` 으로 열어야 하면 먼저 제안한다.
- 의존성은 GRDB 와 SwiftStreamingMarkdown 두 개다. SwiftStreamingMarkdown 은 상위가 HighlightSwift 를 커밋 고정으로 의존하므로 버전 범위 대신 커밋을 고정한다. 새 의존성 추가는 먼저 제안한다.

## 빌드와 테스트

```sh
brew install xcodegen      # 최초 1회
./run.sh                   # 프로젝트 생성(필요 시) + 빌드 + 실행
GALPI_NO_LAUNCH=1 ./run.sh # 빌드만
xcodegen generate          # Xcode 로 열기 전에 프로젝트 생성/갱신
cd GalpiKit && swift test  # 단위 테스트
```

- `project.yml` 이나 `GalpiKit/Package.swift` 를 바꾸면 `xcodegen generate` 를 다시 실행한다. `run.sh` 는 수정 시각을 보고 자동으로 한다.
- 앱 번들은 반드시 xcodebuild 로 만든다. `swift build` 는 의존 패키지의 .xcassets 를 컴파일하지 않아 색이 비어 나온다.
- 배포 대상은 `project.yml` 의 `deploymentTarget` 과 `GalpiKit/Package.swift` 의 `platforms` 두 곳에 있다. 둘을 같이 바꾼다. 현재는 Xcode 16.4 SDK 제약으로 15.0 이며, Xcode 26 설치 후 26.0 으로 올리는 것이 결정된 방향이다.
- `GalpiKit` 은 Swift 6 툴체인에서 언어 모드 5 로 빌드한다. 동시성 경고를 고치기 위해 `@unchecked Sendable` 이나 `nonisolated(unsafe)` 를 뿌리지 않는다.

## 코드 규칙

- 들여쓰기 2칸. 사용자에게 보이는 문자열과 주석은 한국어, 식별자는 영어.
- 상태 객체는 `@MainActor @Observable final class` 패턴을 따른다(`AppModel`, `CodexService`, `ChatSession`). 화면은 `@Environment(AppModel.self)` 로 받는다.
- DB 스키마 변경은 `Database.migrator` 에 새 마이그레이션을 추가한다. 기존 마이그레이션은 수정하지 않는다. 여러 행을 바꾸는 작업은 ID 집합을 먼저 확정하고 트랜잭션 하나로 처리한다.
- Codex 프로토콜 처리는 `Codex/` 안에서 끝낸다. 응답 필드 이름이나 JSON-RPC 세부가 `Model/`, `Views/` 로 새지 않게 한다. 턴 이벤트는 요청 식별자로 대상 대화를 확인한 뒤 반영한다.
- 앱이 만드는 스레드는 `ephemeral`, `approvalPolicy: never`, 읽기 전용 샌드박스를 유지한다. 영구 스레드나 API 키 경로로 바꾸지 않는다.

## 데이터와 로그 규칙

- 기록 안 남기기(private) 대화는 `AppModel.ephemeralSessions` 메모리에만 산다. DB, 검색 색인, 백업, 로그 어디에도 쓰지 않는다. 사용자가 "이 대화 저장" 을 고른 경우에만 DB 에 넣는다.
- 진단 로그와 오류 메시지에 대화 본문이나 코드 조각을 넣지 않는다. 메시지 ID, 길이, 상태 전이, 오류 코드, 토큰 수만 남긴다.
- 인증 토큰, `~/.codex` 내용, 계정 자격 증명을 읽거나 저장하거나 복사하지 않는다. 인증은 Codex 에 맡긴다.
- 휴지통 이동은 복구 가능한 상태 변경이고 영구 삭제만 행을 지운다. 폴더·태그 삭제를 대화 삭제와 결합하지 않는다.
- 기록 DB 는 `~/Library/Application Support/Galpi/galpi.sqlite`, 앱이 띄운 app-server 상태는 같은 폴더의 `codex-state` 에 둔다.

## 문서

- 코드와 문서가 어긋나면 코드가 정본이다. 같은 작업에서 문서를 고친다.
- `plan.md` 는 계획 문서다. 기능이 구현되면 README 의 "현재 사용할 수 있는 기능" 을 갱신하고, 설계가 바뀌면 plan.md 의 해당 절을 고친다.

## 커밋

- 사용자가 명시적으로 지시할 때만 커밋한다.
- 메시지 형식은 `{gitmoji} {Short English summary}` 한 줄이다. gitmoji 는 `:tada:` 처럼 코드 표기로 쓰고, 요약은 영어 명령형으로 쓴다. 예: `:sparkles: Add bulk move to folder`, `:bug: Fix late deltas leaking into another conversation after interrupt`, `:recycle: Split Codex turn event parsing`.
- 필요하면 빈 줄 뒤에 이유를 영어로 덧붙인다.
