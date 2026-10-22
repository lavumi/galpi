import SwiftUI

struct MainView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow
  let startupError: String?
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    @Bindable var model = model
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
    } content: {
      ConversationListView()
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
    } detail: {
      ChatView()
    }
    .alert("오류", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
      Button("확인") { model.lastError = nil }
    } message: {
      Text(model.lastError ?? "")
    }
    .onAppear {
      if let startupError { model.lastError = startupError }
      // 퀵챗이 닫힌 메인 창을 다시 열 수 있도록 openWindow 액션을 넘겨 둔다.
      QuickAskController.shared.openMainWindow = { openWindow(id: "main") }
    }
  }
}
