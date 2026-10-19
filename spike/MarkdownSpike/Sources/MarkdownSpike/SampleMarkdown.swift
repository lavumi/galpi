import Foundation

enum SampleMarkdown {
  static let shortAnswer = #"""
세 가지 원칙으로 정리할 수 있어요.

1. **한 액터, 한 프로세스.** `AppServerProcess` 액터가 stdin/stdout 파이프를 소유합니다.
2. **요청 ID로 응답을 매칭.** `pending[id]` 에 continuation 을 넣고 응답이 오면 꺼냅니다.
3. **알림은 별도 스트림.** `AsyncStream<Notification>` 으로 뷰 모델에 전달합니다.

```swift
let client = AppServerProcess(executable: codexURL, workingDirectory: appDir)
try await client.start { method, params in
  print(method, params)
}
let result = try await client.request("initialize", params: .object([:]))
```

자세한 코드는 다음 답변에서 전체 예제로 이어가겠습니다.
"""#

  static let longAnswer = #"""
# codex app-server 스트리밍을 SwiftUI에 연결하기

핵심은 세 층으로 나누는 것입니다. **프로세스 어댑터**가 JSON-RPC를 읽고, **대화 상태 액터**가 요청 ID별로 이벤트를 라우팅하며, **뷰 모델**이 메인 스레드에서 스냅샷을 발행합니다. 아래는 각 층의 최소 구현입니다.

## 1. 프로세스 어댑터

```swift
import Foundation

actor AppServerProcess {
  private let process = Process()
  private let stdin = Pipe()
  private let stdout = Pipe()
  private var nextID = 0
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var notificationHandler: ((String, JSONValue) -> Void)?

  init(executable: URL, workingDirectory: URL) {
    process.executableURL = executable
    process.arguments = ["app-server"]
    process.currentDirectoryURL = workingDirectory
    process.standardInput = stdin
    process.standardOutput = stdout
  }

  func start(onNotification: @escaping (String, JSONValue) -> Void) throws {
    notificationHandler = onNotification
    try process.run()
    Task.detached { [weak self] in
      for try await line in self?.stdout.fileHandleForReading.bytes.lines ?? .init() {
        await self?.handle(line: line)
      }
    }
  }

  func request(_ method: String, params: JSONValue) async throws -> JSONValue {
    nextID += 1
    let id = nextID
    let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params.object]
    let data = try JSONSerialization.data(withJSONObject: payload)
    stdin.fileHandleForWriting.write(data + Data("\n".utf8))
    return try await withCheckedThrowingContinuation { pending[id] = $0 }
  }

  private func handle(line: String) {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
      cont.resume(returning: JSONValue(obj["result"] ?? [:]))
    } else if let method = obj["method"] as? String {
      notificationHandler?(method, JSONValue(obj["params"] ?? [:]))
    }
  }
}
```

여기서 중요한 점은 `pending` 딕셔너리가 액터 내부에 있으므로 응답과 알림이 섞여 도착해도 경쟁 조건이 없다는 것입니다.

## 2. 스레드 생성과 턴 실행

요청 순서는 다음과 같습니다.

1. `initialize` 로 프로토콜 버전을 교환한다.
2. `thread/start` 에 `ephemeral: true` 를 넣어 임시 스레드를 만든다.
3. `turn/start` 로 사용자 메시지를 보낸다.
4. `item/agentMessage/delta` 알림을 모아 답변을 만든다.

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "thread/start",
  "params": {
    "ephemeral": true,
    "model": "gpt-5.6-sol",
    "approvalPolicy": "never",
    "sandbox": "read-only"
  }
}
```

| 알림 | 의미 | 처리 |
| --- | --- | --- |
| `item/started` | 새 아이템이 시작됨 | 메시지 자리 확보 |
| `item/agentMessage/delta` | 본문 조각 | 버퍼에 추가 |
| `item/completed` | 아이템 완료 | 상태를 완료로 전환 |
| `turn/completed` | 턴 종료 | 토큰 사용량 저장 |
| `thread/tokenUsage/updated` | 문맥 크기 | 예산 계산에 사용 |

## 3. 뷰 모델

```swift
@MainActor
final class ConversationViewModel: ObservableObject, StreamedMarkdownSource {
  @Published var messages: [Message] = []
  let text: AsyncStream<String>
  private let continuation: AsyncStream<String>.Continuation
  private var buffer = ""

  init() {
    var c: AsyncStream<String>.Continuation!
    text = AsyncStream { c = $0 }
    continuation = c
  }

  func apply(delta: String) {
    buffer += delta
    continuation.yield(buffer)
  }

  func finish() {
    continuation.finish()
    messages.append(Message(role: .assistant, body: buffer))
  }
}
```

> 델타마다 전체 스냅샷을 다시 보내는 것이 낭비처럼 보이지만, `StreamedMarkdownView` 는 증분 파싱을 하므로 비용은 새로 추가된 꼬리 부분에만 든다.

## 4. 실행 확인

터미널에서 서버를 직접 띄워 보면 프로토콜을 눈으로 확인할 수 있습니다.

```bash
codex app-server 2>/dev/null <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"galpi","version":"0.1"}}}
EOF
```

## 5. 긴 코드 블록에서의 성능

아래는 일부러 길게 만든 블록입니다. 스트리밍 중 가로 스크롤과 강조가 유지되는지, 복사 버튼이 원문 그대로 넣는지 확인하세요.

```python
import asyncio
import json
import sys
from dataclasses import dataclass, field


@dataclass
class Turn:
    id: int
    prompt: str
    chunks: list[str] = field(default_factory=list)
    done: bool = False

    @property
    def text(self) -> str:
        return "".join(self.chunks)


class FakeServer:
    """codex app-server 를 흉내 내는 아주 작은 JSON-RPC 서버."""

    def __init__(self) -> None:
        self.turns: dict[int, Turn] = {}

    async def handle(self, line: str) -> list[dict]:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            return [{"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1}}]
        if method == "turn/start":
            turn = Turn(id=msg["id"], prompt=msg["params"]["text"])
            self.turns[turn.id] = turn
            out = [{"jsonrpc": "2.0", "id": msg["id"], "result": {"turnId": turn.id}}]
            for word in ("안녕하세요", " ", "스트리밍", " ", "테스트입니다."):
                turn.chunks.append(word)
                out.append({"jsonrpc": "2.0", "method": "item/agentMessage/delta",
                            "params": {"turnId": turn.id, "delta": word}})
            turn.done = True
            out.append({"jsonrpc": "2.0", "method": "turn/completed",
                        "params": {"turnId": turn.id, "usage": {"inputTokens": 42, "outputTokens": 7}}})
            return out
        return [{"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32601, "message": "unknown"}}]


async def main() -> None:
    server = FakeServer()
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin)
    while line := await reader.readline():
        for out in await server.handle(line.decode()):
            sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    asyncio.run(main())
```

## 6. 정리

- 응답과 알림은 액터 안에서만 분기한다.
- 뷰에는 항상 전체 스냅샷을 넘긴다.
- 완료된 메시지는 `MarkdownView` 로 고정해 재파싱을 멈춘다.

마지막으로 짧은 인라인 테스트 하나: `let x = try await client.request("thread/start", params: .object(["ephemeral": true]))` 처럼 긴 인라인 코드가 줄바꿈되는지도 보세요.
"""#
}

