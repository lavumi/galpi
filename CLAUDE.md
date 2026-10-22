# 갈피(Galpi) 저장소 규칙

macOS용 개인 AI 대화 앱. 설치된 Codex CLI 의 app-server 를 자식 프로세스로 띄워 ChatGPT 로그인을 그대로 쓰고, 대화 기록은 로컬 SQLite 에 둔다. 제품 방향과 단계별 통과 조건은 `plan.md` 에 있다. 기능 범위나 UX 를 판단해야 하면 그 문서를 먼저 읽는다.

## 구조

```
project.yml          xcodegen 정의. 타깃, 의존성, 빌드 설정이 전부 여기 있다. Galpi.xcodeproj 는 생성물이라 커밋하지 않는다.
Galpi/               앱 타깃 하나. 모듈을 나누지 않는다.
  App/               @main 진입점
  Codex/             app-server 프로세스, JSON-RPC, 연결 상태, 턴 실행
  Store/             GRDB 기반 Database 와 Record 타입, 마이그레이션
  Model/             AppModel(화면 조정자), ChatSession, StreamingMessage, ContextBudget
  Views/             SwiftUI 화면
  Assets.xcassets/
GalpiTests/          단위 테스트. @testable import Galpi
spike/               단계 0 렌더링 검증용 POC. 참고용으로만 두고 수정하지 않는다.
```

- 단일 모듈이므로 접근 제어는 `private`/`internal` 만 쓴다. `public` 은 필요 없다.
- 의존성은 GRDB 와 SwiftStreamingMarkdown 두 개이며 `project.yml` 의 `packages` 에 선언한다. SwiftStreamingMarkdown 은 상위가 HighlightSwift 를 커밋 고정으로 의존하므로 버전 범위 대신 커밋을 고정한다. 새 의존성 추가는 먼저 제안한다.
- 코드가 커져 모듈 분리가 필요해지면 그때 로컬 패키지로 뽑는다. 미리 나누지 않는다.

## 빌드와 테스트

```sh
brew install xcodegen      # 최초 1회
./run.sh                   # 프로젝트 생성(필요 시) + 빌드 + 실행
GALPI_NO_LAUNCH=1 ./run.sh # 빌드만
xcodegen generate          # Xcode 로 열기 전에 프로젝트 생성/갱신
xcodebuild -project Galpi.xcodeproj -scheme Galpi -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode test
```

- `project.yml` 을 바꾸면 `xcodegen generate` 를 다시 실행한다. `run.sh` 는 수정 시각을 보고 자동으로 한다.
- 터미널 빌드에는 `-skipMacroValidation` 을 붙인다. 의존 패키지의 `Equatable` 매크로가 Xcode 에서 승인되지 않은 환경에서는 이 플래그 없이는 빌드가 실패한다.
- 배포 대상은 `project.yml` 의 `deploymentTarget` 한 곳이며 26.0 이다. Xcode 27 이상으로 빌드한다.
- Swift 6 툴체인에서 언어 모드 5(`SWIFT_VERSION: 5.0`)로 빌드한다. 동시성 경고를 고치기 위해 `@unchecked Sendable` 이나 `nonisolated(unsafe)` 를 뿌리지 않는다.

## 코드 규칙

- 들여쓰기 2칸. 사용자에게 보이는 문자열과 주석은 한국어, 식별자는 영어.
- 상태 객체는 `@MainActor @Observable final class` 패턴을 따른다(`AppModel`, `CodexService`, `ChatSession`). 화면은 `@Environment(AppModel.self)` 로 받는다.
- DB 스키마 변경은 `Database.migrator` 에 새 마이그레이션을 추가한다. 기존 마이그레이션은 수정하지 않는다. 여러 행을 바꾸는 작업은 ID 집합을 먼저 확정하고 트랜잭션 하나로 처리한다.
- Codex 프로토콜 처리는 `Codex/` 안에서 끝낸다. 응답 필드 이름이나 JSON-RPC 세부가 `Model/`, `Views/` 로 새지 않게 한다. 턴 이벤트는 요청 식별자로 대상 대화를 확인한 뒤 반영한다.
- 앱이 만드는 스레드는 `ephemeral`, `approvalPolicy: never`, 읽기 전용 샌드박스를 유지한다. 영구 스레드나 API 키 경로로 바꾸지 않는다.
- 대화 하나는 앱이 떠 있는 동안 임시 스레드 하나를 재사용한다(`ChatSession.threadID`, 메모리 전용). 스레드가 없거나 `turn/start` 가 실패하면 새 스레드를 만들어 문맥 예산 안의 기록을 주입한다. 재시도·실패 뒤에는 `threadID` 를 nil 로 돌려 새 스레드에서 시작한다.
- 턴 단계별 시간은 `Logger(subsystem: "com.lavumi.galpi", category: "turn")` 로 남긴다. 본문·프롬프트·모델 응답은 넣지 않는다.

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
