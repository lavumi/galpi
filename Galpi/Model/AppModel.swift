import Foundation
import Observation
import SwiftUI

enum SettingsKey {
  static let codexPath = "codexPath"
  static let defaultModel = "defaultModel"
  static let defaultEffort = "defaultEffort"
  static let newChatsPrivate = "newChatsPrivate"
  static let showInDock = "showInDock"
  static let lastModel = "lastModel"
  static let lastEffort = "lastEffort"
}

@MainActor
@Observable
final class AppModel {
  let codex: CodexService
  let db: Database
  let supportDirectory: URL

  var scope: Database.Scope = .all {
    didSet { reloadList() }
  }
  var query = "" {
    didSet { reloadList() }
  }
  var hits: [SearchHit] = []
  var counts: (all: Int, favorites: Int, archived: Int, trash: Int) = (0, 0, 0, 0)
  var selectedId: String? {
    didSet { if oldValue != selectedId { open(id: selectedId) } }
  }
  var session: ChatSession?
  var composerText = ""
  var nextChatPrivate: Bool
  var pendingScrollMessageId: String?
  var lastError: String?
  /// Cmd+F 대화 내부 찾기 바 표시 여부.
  var chatSearchVisible = false
  /// 메뉴 커맨드가 뷰 포커스를 건드릴 수 없으므로 틱 증가를 신호로 쓴다.
  var chatSearchFocusTick = 0
  var listSearchFocusTick = 0
  var composerFocusTick = 0
  /// Cmd+Shift+N: 설정과 무관하게 다음 새 대화 한 번만 기록 안 남기기.
  var nextChatPrivateOnce = false
  /// 지금 답변을 생성 중인 세션. 퀵챗이 큐잉 대상을 찾을 때 쓴다.
  private(set) var generatingSession: ChatSession?
  /// 입력창에 붙어 있는 전송 전 첨부.
  var pendingAttachments: [ComposerAttachment] = []

  /// 기록 안 남기기 대화는 여기만 산다. 앱을 끄면 사라진다.
  private var ephemeralSessions: [String: ChatSession] = [:]
  private var persistTask: Task<Void, Never>?

  init(supportDirectory: URL, db: Database, codex: CodexService) {
    self.supportDirectory = supportDirectory
    self.db = db
    self.codex = codex
    self.nextChatPrivate = UserDefaults.standard.bool(forKey: SettingsKey.newChatsPrivate)
    reloadList()
  }

  static func live() throws -> AppModel {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Galpi", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let db = try Database(path: base.appendingPathComponent("galpi.sqlite").path)
    try db.recoverStreamingMessages()
    return AppModel(supportDirectory: base, db: db, codex: CodexService(supportDirectory: base))
  }

  /// 앱 시작 시 호출한다. 기록 DB를 열지 못하면 메모리 DB로라도 띄우고 그 사유를 함께 돌려준다.
  static func bootstrap() -> (model: AppModel, startupError: String?) {
    do {
      return (try live(), nil)
    } catch {
      let fallback = try! Database.inMemory()
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("Galpi")
      let model = AppModel(supportDirectory: base, db: fallback, codex: CodexService(supportDirectory: base))
      return (model, "기록 저장소를 열지 못했습니다: \(error.localizedDescription)")
    }
  }

  func start() async {
    await codex.connect(executableOverride: UserDefaults.standard.string(forKey: SettingsKey.codexPath))
  }

  func reconnect() {
    Task { await start() }
  }

  // MARK: - Settings

  var defaultModel: String {
    if let saved = UserDefaults.standard.string(forKey: SettingsKey.defaultModel), codex.models.contains(where: { $0.id == saved }) {
      return saved
    }
    // 설정에서 고정하지 않았으면 마지막으로 사용한 모델을 이어 쓴다.
    if let last = UserDefaults.standard.string(forKey: SettingsKey.lastModel), codex.models.contains(where: { $0.id == last }) {
      return last
    }
    return codex.models.first(where: \.isDefault)?.id ?? codex.models.first?.id ?? ""
  }

  var defaultEffort: String? {
    if let saved = UserDefaults.standard.string(forKey: SettingsKey.defaultEffort), !saved.isEmpty { return saved }
    if let last = UserDefaults.standard.string(forKey: SettingsKey.lastEffort), !last.isEmpty { return last }
    return nil
  }

  // MARK: - List

  func reloadList() {
    do {
      hits = try db.conversations(scope: scope, query: query)
      counts = try db.counts()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func open(id: String?) {
    guard let id else {
      session = nil
      return
    }
    nextChatPrivateOnce = false
    if session?.id == id { return }
    if let ephemeral = ephemeralSessions[id] {
      session = ephemeral
      return
    }
    do {
      guard let conversation = try db.conversation(id: id) else { session = nil; return }
      let messages = try db.messages(conversationId: id)
      session = ChatSession(conversation: conversation, messages: messages, isEphemeral: false)
    } catch {
      lastError = error.localizedDescription
    }
  }

  func newChat() {
    showAllScope()
    selectedId = nil
    session = nil
    composerText = ""
    nextChatPrivateOnce = false
  }

  func newPrivateChat() {
    newChat()
    nextChatPrivateOnce = true
    focusComposer()
  }

  func requestChatSearch() {
    guard session != nil else { return }
    chatSearchVisible = true
    chatSearchFocusTick += 1
  }

  func requestListSearch() {
    listSearchFocusTick += 1
  }

  func focusComposer() {
    composerFocusTick += 1
  }

  /// 새 대화는 어느 범위에서 시작하든 전체 대화에서 보인다.
  private func showAllScope() {
    if scope != .all { scope = .all }
  }

  // MARK: - 현재 대화 단축키 동작

  func toggleFavoriteCurrent() {
    guard let session, !session.isEphemeral else { return }
    setFavorite(!session.conversation.isFavorite, ids: [session.id])
  }

  func toggleArchiveCurrent() {
    guard let session, !session.isEphemeral else { return }
    setArchived(!session.conversation.isArchived, ids: [session.id])
  }

  func trashCurrent() {
    guard let session, !session.isEphemeral, session.conversation.deletedAt == nil else { return }
    moveToTrash(ids: [session.id])
  }

  func copyLastAnswer() {
    guard let text = session?.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  /// 목록에서 현재 대화 기준 위/아래 대화를 연다. 선택이 없으면 끝에서 시작한다.
  func selectAdjacentConversation(offset: Int) {
    let ids = hits.map(\.conversation.id)
    guard !ids.isEmpty else { return }
    if let current = selectedId.flatMap({ ids.firstIndex(of: $0) }) {
      selectedId = ids[min(max(current + offset, 0), ids.count - 1)]
    } else {
      selectedId = offset > 0 ? ids[0] : ids[ids.count - 1]
    }
  }

  // MARK: - Sending

  func send(model: String, effort: String?) {
    let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)

    // 현재 대화가 생성 중이면: 입력이 있으면 큐에 쌓고, 빈 Enter 는 1초 안전 갭 뒤 중단 후 즉시 전송.
    if let session, session.isGenerating {
      guard pendingAttachments.isEmpty else {
        lastError = "첨부는 답변이 끝난 뒤 보낼 수 있습니다."
        return
      }
      if !prompt.isEmpty {
        session.queuedPrompts.append(prompt)
        session.lastEnqueuedAt = Date()
        composerText = ""
      } else if !session.queuedPrompts.isEmpty,
                let enqueued = session.lastEnqueuedAt,
                Date().timeIntervalSince(enqueued) >= 1 {
        // 중단되면 run 의 완료 경로가 큐를 즉시 이어 보낸다.
        codex.interrupt()
      }
      return
    }

    // 유휴 상태에서 큐가 남아 있으면(직전 턴 실패 등) 빈 Enter 로 재개한다.
    if prompt.isEmpty, pendingAttachments.isEmpty, let session, !session.queuedPrompts.isEmpty {
      let model = model.isEmpty ? defaultModel : model
      guard !model.isEmpty, codex.state == .connected, !codex.isGenerating else { return }
      let next = session.queuedPrompts.removeFirst()
      dispatch(prompt: next, session: session, model: model, effort: effort)
      return
    }

    guard !prompt.isEmpty || !pendingAttachments.isEmpty else { return }
    guard !codex.isGenerating else {
      lastError = TurnError.busy.localizedDescription
      return
    }
    guard codex.state == .connected else {
      lastError = "Codex에 연결된 뒤 보낼 수 있습니다. (\(codex.state.label))"
      return
    }
    // 모델 목록이 늦게 와서 선택이 비어 있으면 기본 모델로 보낸다.
    let model = model.isEmpty ? defaultModel : model
    guard !model.isEmpty else {
      lastError = "사용할 수 있는 모델이 없습니다. 연결 상태를 확인하세요."
      return
    }
    let titleSource = prompt.isEmpty ? pendingAttachments.map(\.filename).joined(separator: ", ") : prompt
    let session = self.session ?? makeSession(firstPrompt: titleSource, model: model, effort: effort,
                                              ephemeral: nextChatPrivate || nextChatPrivateOnce)
    nextChatPrivateOnce = false
    let attachments = finalizeAttachments(pendingAttachments, ephemeral: session.isEphemeral)
    let fullText = Self.composeText(prompt: prompt, attachments: attachments)
    composerText = ""
    pendingAttachments = []
    dispatch(prompt: fullText, session: session, model: model, effort: effort,
             images: attachments.filter { $0.kind == .image }.map(\.path))
  }

  /// 확정된 대화에 사용자 메시지를 추가하고 턴을 시작한다.
  private func dispatch(prompt: String, session: ChatSession, model: String, effort: String?, images: [String] = []) {
    // 다음 새 대화가 같은 모델·강도를 이어 쓰도록 마지막 사용값을 기억한다.
    UserDefaults.standard.set(model, forKey: SettingsKey.lastModel)
    UserDefaults.standard.set(effort ?? "", forKey: SettingsKey.lastEffort)
    session.errorMessage = nil
    session.conversation.model = model
    session.conversation.effort = effort

    let userMessage = Message.new(conversationId: session.id, ordinal: nextOrdinal(session), role: .user, text: prompt, status: .complete, model: nil)
    session.messages.append(userMessage)
    persist(session, message: userMessage)

    run(session, prompt: prompt, model: model, effort: effort, images: images)
  }

  func stop() {
    codex.interrupt()
  }

  /// 실패했거나 비어 있는 답변을 지우고 같은 질문을 다시 보낸다.
  func retry(messageId: String) {
    guard let session, let index = session.messages.firstIndex(where: { $0.id == messageId }),
          session.messages[index].role == .assistant, index > 0, !session.isGenerating else { return }
    let prompt = session.messages[index - 1].text
    let failed = session.messages.remove(at: index)
    if !session.isEphemeral { try? db.deletePermanentlyMessage(id: failed.id) }
    // 기존 스레드에는 실패한 턴의 질문이 이미 들어가 있으므로 새 스레드에서 기록을 다시 주입한다.
    session.threadID = nil
    run(session, prompt: prompt, model: resolvedModel(session), effort: session.conversation.effort)
  }

  /// 해당 답변 직전까지 복사한 새 대화를 만들고 거기서 다시 생성한다. 원본은 그대로 둔다.
  func regenerateAsNewConversation(assistantMessageId: String) {
    guard let source = session, let index = source.messages.firstIndex(where: { $0.id == assistantMessageId }), index > 0,
          !codex.isGenerating else { return }
    let prompt = source.messages[index - 1].text
    let copied = Array(source.messages[..<(index - 1)])
    let branch = branchSession(from: source, messages: copied)
    let userMessage = Message.new(conversationId: branch.id, ordinal: nextOrdinal(branch), role: .user, text: prompt, status: .complete, model: nil)
    branch.messages.append(userMessage)
    persist(branch, message: userMessage)
    run(branch, prompt: prompt, model: resolvedModel(branch), effort: branch.conversation.effort)
  }

  /// 사용자 메시지 직전까지 복사한 새 대화를 열고 입력창에 원문을 넣는다.
  func editAsNewConversation(userMessageId: String) {
    guard let source = session, let index = source.messages.firstIndex(where: { $0.id == userMessageId }),
          !codex.isGenerating else { return }
    let original = source.messages[index].text
    let copied = Array(source.messages[..<index])
    _ = branchSession(from: source, messages: copied)
    composerText = original
  }

  /// 저장 중인 대화에서 기록 안 남기기로 전환: 문맥을 메모리로 복사한 새 임시 대화를 연다.
  func continuePrivately() {
    guard let source = session, !source.isEphemeral, !codex.isGenerating else { return }
    var conversation = Conversation.new(title: source.conversation.title, model: source.conversation.model, effort: source.conversation.effort)
    conversation.originId = source.id
    let messages = source.messages.enumerated().map { offset, m in
      Message(id: UUID().uuidString, conversationId: conversation.id, ordinal: offset, role: m.role, text: m.text,
              status: m.status, createdAt: m.createdAt, inputTokens: m.inputTokens, outputTokens: m.outputTokens, model: m.model)
    }
    let session = ChatSession(conversation: conversation, messages: messages, isEphemeral: true)
    session.contextWindow = source.contextWindow
    ephemeralSessions[session.id] = session
    self.session = session
    selectedId = nil
  }

  /// 임시 대화를 DB에 저장한다. 사용자가 명시적으로 선택한 경우에만 호출한다.
  func saveEphemeral() {
    guard let source = session, source.isEphemeral, !source.isGenerating else { return }
    do {
      let saved = ChatSession(conversation: source.conversation, messages: source.messages, isEphemeral: false)
      saved.conversation.updatedAt = Date()
      saved.conversation.preview = Database.preview(of: source.messages.last?.text ?? "")
      try db.save(saved.conversation)
      for message in saved.messages { try db.save(message, touching: saved.conversation) }
      ephemeralSessions.removeValue(forKey: source.id)
      session = saved
      showAllScope()
      reloadList()
      selectedId = saved.id
    } catch {
      lastError = error.localizedDescription
    }
  }

  func discardEphemeral() {
    guard let source = session, source.isEphemeral else { return }
    if source.isGenerating { codex.interrupt() }
    ephemeralSessions.removeValue(forKey: source.id)
    session = nil
  }

  // MARK: - Conversation management

  func rename(id: String, title: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    if let session, session.id == id { session.conversation.title = trimmed }
    if ephemeralSessions[id] == nil {
      try? db.rename(id: id, title: trimmed)
      reloadList()
    }
  }

  func setFavorite(_ value: Bool, ids: Set<String>) { mutate(ids) { try db.setFavorite(value, ids: $0) } }
  func setArchived(_ value: Bool, ids: Set<String>) { mutate(ids) { try db.setArchived(value, ids: $0) } }
  func moveToTrash(ids: Set<String>) {
    if let session, ids.contains(session.id), session.isGenerating { codex.interrupt() }
    mutate(ids) { try db.moveToTrash(ids: $0) }
    if let session, ids.contains(session.id) { self.session = nil; selectedId = nil }
  }
  func restore(ids: Set<String>) { mutate(ids) { try db.restore(ids: $0) } }
  func deletePermanently(ids: Set<String>) {
    mutate(ids) { try db.deletePermanently(ids: $0) }
    if let session, ids.contains(session.id) { self.session = nil; selectedId = nil }
  }
  func emptyTrash() {
    do { _ = try db.emptyTrash() } catch { lastError = error.localizedDescription }
    if let session, session.conversation.deletedAt != nil { self.session = nil; selectedId = nil }
    reloadList()
  }

  private func mutate(_ ids: Set<String>, _ op: ([String]) throws -> Void) {
    let persisted = ids.filter { ephemeralSessions[$0] == nil }
    guard !persisted.isEmpty else { return }
    do { try op(Array(persisted)) } catch { lastError = error.localizedDescription }
    if let session, persisted.contains(session.id), let fresh = try? db.conversation(id: session.id) {
      session.conversation = fresh
    }
    reloadList()
  }

  // MARK: - Private helpers

  private func makeSession(firstPrompt: String, model: String, effort: String?, ephemeral: Bool) -> ChatSession {
    let title = Self.title(from: firstPrompt)
    let conversation = Conversation.new(title: title, model: model, effort: effort)
    let session = ChatSession(conversation: conversation, messages: [], isEphemeral: ephemeral)
    if ephemeral {
      ephemeralSessions[session.id] = session
    } else {
      try? db.save(conversation)
    }
    self.session = session
    if !ephemeral {
      showAllScope()
      selectedId = session.id
    }
    return session
  }

  private func branchSession(from source: ChatSession, messages: [Message]) -> ChatSession {
    var conversation = Conversation.new(title: Self.branchTitle(source.conversation.title), model: source.conversation.model, effort: source.conversation.effort)
    conversation.originId = source.id
    conversation.folderId = source.conversation.folderId
    conversation.isFavorite = source.conversation.isFavorite
    let copied = messages.enumerated().map { offset, m in
      Message(id: UUID().uuidString, conversationId: conversation.id, ordinal: offset, role: m.role, text: m.text,
              status: m.status, createdAt: m.createdAt, inputTokens: m.inputTokens, outputTokens: m.outputTokens, model: m.model)
    }
    let session = ChatSession(conversation: conversation, messages: copied, isEphemeral: source.isEphemeral)
    session.contextWindow = source.contextWindow
    if source.isEphemeral {
      ephemeralSessions[session.id] = session
      self.session = session
      selectedId = nil
    } else {
      do {
        try db.save(conversation)
        for message in copied { try db.save(message, touching: conversation) }
      } catch { lastError = error.localizedDescription }
      self.session = session
      showAllScope()
      reloadList()
      selectedId = session.id
    }
    return session
  }

  nonisolated static func title(from prompt: String) -> String {
    let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
    return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
  }

  nonisolated static func branchTitle(_ title: String) -> String {
    if let match = title.range(of: #" \((\d+)\)$"#, options: .regularExpression) {
      let number = Int(title[match].filter(\.isNumber)) ?? 1
      return String(title[..<match.lowerBound]) + " (\(number + 1))"
    }
    return title + " (2)"
  }

  private func nextOrdinal(_ session: ChatSession) -> Int {
    (session.messages.map(\.ordinal).max() ?? -1) + 1
  }

  private func resolvedModel(_ session: ChatSession) -> String {
    if let m = session.conversation.model, !m.isEmpty { return m }
    return defaultModel
  }

  private func persist(_ session: ChatSession, message: Message) {
    guard !session.isEphemeral else { return }
    do {
      try db.save(message, touching: session.conversation)
      reloadList()
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func run(_ session: ChatSession, prompt: String, model: String, effort: String?, images: [String] = []) {
    let selection = ContextBudget.select(messages: session.messages.dropLast().filter { $0.status != .failed },
                                         prompt: prompt, contextWindow: session.contextWindow)
    session.contextNotice = nil

    let assistant = Message.new(conversationId: session.id, ordinal: nextOrdinal(session), role: .assistant, text: "", status: .streaming, model: model)
    session.messages.append(assistant)
    persist(session, message: assistant)
    let buffer = StreamingMessage()
    session.streaming = buffer
    session.streamingMessageId = assistant.id
    generatingSession = session

    Task { [weak self] in
      guard let self else { return }
      var lastPersist = Date()
      var usage: (input: Int, output: Int, window: Int?)?
      var finalStatus: MessageStatus = .complete
      do {
        for try await event in codex.runTurn(reusingThread: session.threadID, history: selection.items, prompt: prompt, images: images, model: model, effort: effort) {
          switch event {
          case .started(let tid, _, let reused):
            session.threadID = tid
            // 기존 스레드를 이어 쓸 때는 Codex 가 문맥을 관리하므로 예산 안내는 새 스레드에 주입한 경우에만 뜬다.
            if !reused, selection.droppedTurns > 0 {
              session.contextNotice = "문맥 예산을 넘어 오래된 \(selection.droppedTurns)개 턴은 이번 요청에 포함되지 않았습니다."
            }
          case .delta(let delta):
            buffer.append(delta)
            if !session.isEphemeral, Date().timeIntervalSince(lastPersist) > 1 {
              lastPersist = Date()
              try? db.update(messageId: assistant.id, text: buffer.snapshot, status: .streaming, inputTokens: nil, outputTokens: nil)
            }
          case .usage(let input, let output, let window):
            usage = (input, output, window)
          case .completed:
            finalStatus = .complete
          case .interrupted:
            finalStatus = .interrupted
          }
        }
      } catch {
        finalStatus = .failed
        session.errorMessage = error.localizedDescription
        // 실패한 스레드는 버리고 다음 전송은 새 스레드에서 시작한다.
        session.threadID = nil
      }
      buffer.finish()
      let text = buffer.snapshot
      if let index = session.messages.firstIndex(where: { $0.id == assistant.id }) {
        session.messages[index].text = text
        session.messages[index].status = finalStatus
        session.messages[index].inputTokens = usage?.input
        session.messages[index].outputTokens = usage?.output
      }
      if let usage {
        session.lastInputTokens = usage.input
        if let window = usage.window { session.contextWindow = window }
      }
      session.streaming = nil
      session.streamingMessageId = nil
      if generatingSession === session { generatingSession = nil }
      if !session.isEphemeral {
        try? db.update(messageId: assistant.id, text: text, status: finalStatus, inputTokens: usage?.input, outputTokens: usage?.output)
        if let usage { try? db.updateContext(conversationId: session.id, lastInputTokens: usage.input, contextWindow: usage.window) }
        reloadList()
      } else if let threadID = session.threadID {
        codex.purgeLogs(threadID: threadID)
      }
      // 완료·중단 후 큐에 쌓인 다음 질문을 즉시 이어 보낸다. 실패는 사용자가 확인하도록 멈춘다.
      if finalStatus != .failed, !session.queuedPrompts.isEmpty {
        let next = session.queuedPrompts.removeFirst()
        dispatch(prompt: next, session: session, model: model, effort: effort)
      }
    }
  }
}
