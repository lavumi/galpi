# 갈피(Galpi)

macOS에서 Codex와 나눈 기술 대화를 로컬에 저장하고, Markdown과 코드 중심으로 다시 읽고 관리하는 첫 버전입니다.

## 실행

필요한 환경은 macOS 26 이상, Xcode 27 이상, xcodegen, 그리고 로그인된 Codex CLI입니다.

```sh
brew install xcodegen
codex login
./run.sh
```

`run.sh`는 `project.yml`로 `Galpi.xcodeproj`를 생성한 뒤(이미 있고 변경이 없으면 건너뜀) xcodebuild로 `Galpi.app`을 만들어 실행합니다. 이미 실행 중인 갈피가 있으면 기존 창을 활성화합니다. 빌드만 하려면 다음처럼 실행합니다.

```sh
GALPI_NO_LAUNCH=1 ./run.sh
```

Spotlight나 런처(Tinycast 등)에서 찾으려면 `/Applications`에 설치합니다. Release 빌드를 복사하고 기존 버전은 휴지통으로 보냅니다.

```sh
./run.sh install
```

Xcode에서 열려면 `xcodegen generate` 후 `Galpi.xcodeproj`를 엽니다. 생성된 프로젝트는 커밋하지 않습니다.

처음 빌드할 때 Xcode가 SwiftStreamingMarkdown이 쓰는 `Equatable` 매크로를 승인하라고 묻습니다. "Trust & Enable"을 한 번 누르면 이후 `xcodebuild build`도 플래그 없이 통과합니다. 승인 전에 터미널에서 빌드하려면 `-skipMacroValidation`을 붙입니다(`run.sh`는 이미 붙입니다).

## 구조

- `project.yml`: xcodegen 프로젝트 정의. 의존성과 빌드 설정이 여기 있습니다.
- `Galpi/`: 앱 소스. `App`(진입점), `Codex`(app-server 연결), `Store`(SQLite), `Model`, `Views`.
- `GalpiTests/`: 단위 테스트.
- `spike/MarkdownSpike`: Markdown 스트리밍 렌더링을 검증한 POC.
- `plan.md`: 제품 계획과 단계별 통과 조건.

## 현재 사용할 수 있는 기능

- Codex app-server 연결, 계정·모델·사용량 표시
- 질문 전송, 스트리밍 답변, 중단, 실패한 답변 다시 보내기
- SwiftStreamingMarkdown 기반 Markdown, 표, 코드 블록, 구문 강조, 코드 복사
- 대화 제목·본문 검색
- 대화 내부 찾기와 일치 위치 이동 (Cmd+F, Enter/Cmd+G 다음, Cmd+Shift+G 이전, Esc 닫기), 목록 검색 포커스 (Cmd+Shift+F)
- 생성 중 다음 질문 큐잉: Enter 로 대기열에 추가, 빈 입력에서 한 번 더 Enter(1초 뒤)면 중단하고 즉시 전송
- 전역 핫키 빠른 질문: 어느 앱에서든 Cmd+Shift+Space 로 입력 패널을 열고 Enter 로 전송. 항상 기록 안 남기기로 시작하며 저장은 대화 화면에서 선택 (갈피 실행 중일 때)
- 첨부: 이미지(클립보드 붙여넣기·파일), PDF·텍스트 파일을 입력창에 붙여넣거나 드래그. 이미지는 모델에 직접 전달하고 PDF·텍스트는 추출한 내용을 프롬프트에 포함
- 메뉴 바 전용 앱: Dock 에 나타나지 않고 상단바 책갈피 아이콘으로 열기·빠른 질문·설정·종료. 설정의 "Dock 아이콘 표시"로 되돌릴 수 있음
- 즐겨찾기, 보관, 휴지통, 복구, 이름 변경
- 답변과 질문 복사, 질문을 새 대화에서 수정해 이어가기
- 기존 대화의 문맥을 복사한 private 대화
- private 대화를 나중에 저장하거나 버리기
- 입력 토큰 사용량과 문맥 예산 표시

### 단축키

| 단축키 | 동작 |
| --- | --- |
| Cmd+N / Cmd+Shift+N | 새 대화 / 기록 안 남기는 새 대화 |
| Enter | 보내기 (생성 중에는 대기열에 추가) |
| Cmd+Enter / Option+Enter | 줄바꿈 |
| Cmd+. | 답변 중단 |
| Cmd+F / Cmd+Shift+F | 대화에서 찾기 / 목록 검색 포커스 |
| Cmd+G / Cmd+Shift+G | 다음 / 이전 찾기 결과 |
| Cmd+L | 입력창으로 이동 |
| Cmd+Shift+C | 마지막 답변 복사 |
| Cmd+D, Cmd+E, Cmd+Shift+Delete | 즐겨찾기, 보관, 휴지통 이동 |
| Cmd+1~4 | 전체 / 즐겨찾기 / 보관함 / 휴지통 |
| Cmd+Option+↑/↓ | 이전 / 다음 대화 |
| Cmd+Shift+Space | (전역) 빠른 질문 패널 |
| Cmd+Shift+R | Codex 다시 연결 |

대화 기록은 `~/Library/Application Support/Galpi/galpi.sqlite`에 저장됩니다. Codex의 인증과 기존 사용자 설정은 기존 Codex 환경을 사용하고, 갈피가 시작한 app-server의 상태·로그 DB는 `~/Library/Application Support/Galpi/codex-state`에 둡니다.

## 개발 확인

```sh
xcodebuild -project Galpi.xcodeproj -scheme Galpi -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode test
```

Markdown 렌더링만 확인하려면 `spike/MarkdownSpike/run.sh`를 실행합니다.

## 첫 버전의 범위

Codex app-server 요청은 승인 없이 읽기 전용 샌드박스로 실행합니다. 파일 편집 도구나 승인 대기 UI는 아직 제공하지 않습니다. 폴더·태그, 다중 선택 일괄 처리, 백업·Markdown 내보내기는 다음 개발 범위입니다.
