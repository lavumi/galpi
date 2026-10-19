import SwiftUI

struct SidebarView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      Button {
        model.newChat()
      } label: {
        Label("새 대화", systemImage: "square.and.pencil")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      List(selection: Binding(get: { Optional(model.scope) }, set: { if let s = $0 { model.scope = s } })) {
        Section("대화") {
          row("전체 대화", icon: "bubble.left.and.bubble.right", count: model.counts.all, scope: .all)
          row("즐겨찾기", icon: "star", count: model.counts.favorites, scope: .favorites)
          row("보관함", icon: "archivebox", count: model.counts.archived, scope: .archived)
          row("휴지통", icon: "trash", count: model.counts.trash, scope: .trash)
        }
      }
      .listStyle(.sidebar)
      Divider()
      ConnectionStatusView()
        .padding(10)
    }
  }

  private func row(_ title: String, icon: String, count: Int, scope: Database.Scope) -> some View {
    HStack {
      Label(title, systemImage: icon)
      Spacer()
      Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
    }
    .tag(scope)
  }
}

struct ConnectionStatusView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    let codex = model.codex
    Button {
      openSettings()
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Circle().fill(color(for: codex.state)).frame(width: 8, height: 8)
          Text(codex.state.label).font(.callout.weight(.medium))
          Spacer()
          if codex.state == .starting { ProgressView().controlSize(.mini) }
        }
        if let account = codex.account, codex.state == .connected {
          Text([account.email, account.plan.map { "ChatGPT \($0)" }].compactMap { $0 }.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if let limits = codex.rateLimits, codex.state == .connected {
          limitRow("5시간", limits.primary)
          limitRow("주간", limits.secondary)
        }
        if case .failed(let reason) = codex.state {
          Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        if codex.state == .notInstalled {
          Text("npm i -g @openai/codex 로 설치한 뒤 다시 연결하세요.").font(.caption).foregroundStyle(.secondary)
        }
        if codex.state == .needsLogin {
          Text("터미널에서 codex login 을 실행한 뒤 다시 연결하세요.").font(.caption).foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("연결 설정 열기")
  }

  @ViewBuilder
  private func limitRow(_ name: String, _ window: RateLimitWindow?) -> some View {
    if let window {
      HStack(spacing: 6) {
        Text(name).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
        ProgressView(value: Double(window.usedPercent), total: 100).controlSize(.small)
        Text("\(window.usedPercent)%").font(.caption2).foregroundStyle(.secondary).monospacedDigit().frame(width: 34, alignment: .trailing)
      }
      .help(window.resetsAt.map { "초기화: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }
  }

  private func color(for state: ConnectionState) -> Color {
    switch state {
    case .connected: return .green
    case .starting: return .yellow
    case .idle: return .gray
    case .needsLogin, .notInstalled: return .orange
    case .failed: return .red
    }
  }
}
