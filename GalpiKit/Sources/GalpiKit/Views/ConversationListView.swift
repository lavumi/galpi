import SwiftUI

struct ConversationListView: View {
  @Environment(AppModel.self) private var model
  @State private var selection = Set<String>()
  @State private var renaming: Conversation?
  @State private var renameText = ""
  @State private var confirmDelete: Set<String>?
  @State private var confirmEmptyTrash = false

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("제목·본문 검색", text: $model.query)
          .textFieldStyle(.plain)
          .accessibilityLabel("대화 검색")
        if !model.query.isEmpty {
          Button {
            model.query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("검색어 지우기")
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      .padding(8)

      Divider()

      List(selection: $selection) {
        ForEach(model.hits) { hit in
          ConversationRow(hit: hit, isSearching: !model.query.isEmpty)
            .tag(hit.conversation.id)
            .contextMenu { contextMenu(for: hit.conversation) }
        }
      }
      .overlay {
        if model.hits.isEmpty {
          ContentUnavailableView(model.query.isEmpty ? "대화가 없습니다" : "검색 결과가 없습니다", systemImage: "bubble.left")
        }
      }
    }
    .onChange(of: selection) { _, new in
      // 단일 선택은 열고, 다중 선택은 관리 모드로 둔다.
      if new.count == 1, let id = new.first {
        model.selectedId = id
        if let hit = model.hits.first(where: { $0.conversation.id == id }) { model.pendingScrollMessageId = hit.messageId }
      }
    }
    .onChange(of: model.selectedId) { _, new in
      if let new, selection != [new] { selection = [new] }
      if new == nil { selection = [] }
    }
    .navigationTitle(scopeTitle)
    .toolbar {
      ToolbarItemGroup {
        if selection.count > 1 {
          Text("\(selection.count)개 선택").font(.callout).foregroundStyle(.secondary)
          bulkMenu
        }
        if model.scope == .trash, !model.hits.isEmpty {
          Button("휴지통 비우기", systemImage: "trash.slash") { confirmEmptyTrash = true }
        }
      }
    }
    .sheet(item: $renaming) { conversation in
      RenameSheet(title: conversation.title) { newTitle in
        model.rename(id: conversation.id, title: newTitle)
      }
    }
    .confirmationDialog("영구 삭제", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
      Button("\(confirmDelete?.count ?? 0)개 대화 영구 삭제", role: .destructive) {
        if let ids = confirmDelete { model.deletePermanently(ids: ids); selection = [] }
        confirmDelete = nil
      }
    } message: {
      Text("앱 기록과 검색에서 제거됩니다. 이미 내보낸 파일이나 외부 백업은 지워지지 않습니다.")
    }
    .confirmationDialog("휴지통 비우기", isPresented: $confirmEmptyTrash) {
      Button("\(model.counts.trash)개 대화 영구 삭제", role: .destructive) { model.emptyTrash(); selection = [] }
    }
  }

  private var scopeTitle: String {
    switch model.scope {
    case .all: return "전체 대화"
    case .favorites: return "즐겨찾기"
    case .archived: return "보관함"
    case .trash: return "휴지통"
    }
  }

  private var bulkMenu: some View {
    Menu("선택 항목", systemImage: "ellipsis.circle") {
      if model.scope == .trash {
        Button("복구") { model.restore(ids: selection); selection = [] }
        Button("영구 삭제", role: .destructive) { confirmDelete = selection }
      } else {
        Button("즐겨찾기") { model.setFavorite(true, ids: selection) }
        Button("즐겨찾기 해제") { model.setFavorite(false, ids: selection) }
        Divider()
        Button(model.scope == .archived ? "보관 해제" : "보관") { model.setArchived(model.scope != .archived, ids: selection); selection = [] }
        Button("휴지통으로 이동", role: .destructive) { model.moveToTrash(ids: selection); selection = [] }
      }
    }
  }

  @ViewBuilder
  private func contextMenu(for conversation: Conversation) -> some View {
    let ids: Set<String> = selection.contains(conversation.id) && selection.count > 1 ? selection : [conversation.id]
    if conversation.deletedAt != nil {
      Button("복구") { model.restore(ids: ids); selection = [] }
      Button("영구 삭제", role: .destructive) { confirmDelete = ids }
    } else {
      if ids.count == 1 {
        Button("이름 바꾸기") { renameText = conversation.title; renaming = conversation }
      }
      Button(conversation.isFavorite ? "즐겨찾기 해제" : "즐겨찾기") { model.setFavorite(!conversation.isFavorite, ids: ids) }
      Button(conversation.isArchived ? "보관 해제" : "보관") { model.setArchived(!conversation.isArchived, ids: ids); selection = [] }
      Divider()
      Button("휴지통으로 이동", role: .destructive) { model.moveToTrash(ids: ids); selection = [] }
    }
  }
}

struct ConversationRow: View {
  let hit: SearchHit
  let isSearching: Bool

  var body: some View {
    let c = hit.conversation
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        if c.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
        Text(c.title).font(.body.weight(.medium)).lineLimit(1)
        Spacer()
        Text(c.updatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
      }
      Text(hit.snippet ?? c.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }
    .padding(.vertical, 2)
  }
}

struct RenameSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State var title: String
  let onSave: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("대화 이름").font(.headline)
      TextField("제목", text: $title).textFieldStyle(.roundedBorder).onSubmit(save)
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("저장", action: save).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 380)
  }

  private func save() {
    onSave(title)
    dismiss()
  }
}
