import AppKit
import SwiftUI

struct AIAssistantView: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  @State private var selectedContext = "Current schema"

  var body: some View {
    VStack(spacing: 0) {
      header
      contextBar
      messages
      composer
    }
    .background(SolnariTheme.panel)
    .overlay(alignment: .leading) { Divider() }
  }

  private var header: some View {
    HStack(spacing: 9) {
      ZStack {
        Circle()
          .fill(SolnariTheme.indigo.opacity(0.12))
          .frame(width: 28, height: 28)
        Image(systemName: "sparkles")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(SolnariTheme.indigo)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(settings.text("Ask Codex"))
          .font(.system(size: 13, weight: .semibold))
        HStack(spacing: 5) {
          StatusDot(color: SolnariTheme.orange, size: 5)
          Text(settings.text("Preview · ephemeral sessions planned"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help(settings.text("Conversation is kept in memory only"))
        }
      }
      Spacer()
      Button {
      } label: {
        Image(systemName: "plus.bubble")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(settings.text("New conversation"))
      Button {
        withAnimation(.snappy) { model.isAssistantVisible = false }
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 13)
    .frame(height: 48)
    .background(SolnariTheme.elevated)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var contextBar: some View {
    HStack(spacing: 6) {
      Image(systemName: "paperclip")
        .foregroundStyle(.secondary)
      Menu(settings.text(selectedContext)) {
        Button(settings.text("Current schema")) { selectedContext = "Current schema" }
        Button(settings.text("Selected tables")) { selectedContext = "Selected tables" }
        Button(settings.text("No database context")) { selectedContext = "No database context" }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Spacer()
      PillLabel("Read only", symbol: "shield.lefthalf.filled", tint: SolnariTheme.mint)
    }
    .padding(.horizontal, 12)
    .frame(height: 37)
    .background(SolnariTheme.subtleFill)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 14) {
          ForEach(model.assistantMessages) { message in
            AssistantMessageView(message: message) { sql in
              model.useSQL(sql)
            }
            .id(message.id)
          }

          suggestions
        }
        .padding(13)
      }
      .onChange(of: model.assistantMessages.count) {
        if let last = model.assistantMessages.last {
          withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
        }
      }
    }
  }

  private var suggestions: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(settings.text("Try asking"))
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .textCase(.uppercase)

      suggestionButton("Explain this query", symbol: "text.magnifyingglass")
      suggestionButton("Find performance risks", symbol: "gauge.with.dots.needle.50percent")
      suggestionButton("Add a date filter", symbol: "calendar.badge.plus")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func suggestionButton(_ title: String, symbol: String) -> some View {
    Button {
      model.assistantDraft = title
      model.sendAssistantMessage()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(SolnariTheme.indigo)
          .frame(width: 16)
        Text(settings.text(title))
        Spacer()
        Image(systemName: "arrow.up.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(SolnariTheme.elevated, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SolnariTheme.border))
    }
    .buttonStyle(.plain)
  }

  private var composer: some View {
    VStack(spacing: 8) {
      ZStack(alignment: .topLeading) {
        if model.assistantDraft.isEmpty {
          Text(settings.text("Ask about your data or SQL…"))
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
        }
        TextEditor(text: $model.assistantDraft)
          .font(.system(size: 12))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 46, maxHeight: 92)
          .padding(.horizontal, 3)
          .background(.clear)
      }

      HStack {
        Button {
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        Text(settings.text("Schema attached"))
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
        Button {
          model.sendAssistantMessage()
        } label: {
          Image(systemName: "arrow.up")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 25, height: 25)
            .background(
              model.assistantDraft.isEmpty ? Color.secondary.opacity(0.35) : SolnariTheme.indigo,
              in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(9)
    .background(SolnariTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SolnariTheme.border))
    .padding(10)
    .background(SolnariTheme.panel)
    .overlay(alignment: .top) { Divider() }
  }
}

private struct AssistantMessageView: View {
  @EnvironmentObject private var settings: AppSettings
  let message: AssistantMessage
  let onUseSQL: (String) -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if message.role == .user { Spacer(minLength: 32) }

      if message.role == .assistant {
        Image(systemName: "sparkles")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(SolnariTheme.indigo)
          .frame(width: 23, height: 23)
          .background(SolnariTheme.indigo.opacity(0.10), in: Circle())
      }

      VStack(alignment: .leading, spacing: 9) {
        Text(settings.text(message.text))
          .font(.system(size: 12))
          .lineSpacing(3)
          .textSelection(.enabled)

        if let sql = message.sql {
          VStack(spacing: 0) {
            HStack {
              Text("SQL")
                .font(.caption2.weight(.bold))
                .foregroundStyle(SolnariTheme.indigo)
              Spacer()
              Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sql, forType: .string)
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)

            Divider()

            Text(sql)
              .font(.system(size: 10.5, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(9)

            Divider()

            Button {
              onUseSQL(sql)
            } label: {
              Label(settings.text("Use in editor"), systemImage: "arrow.turn.down.left")
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SolnariTheme.indigo)
          }
          .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SolnariTheme.border))
        }
      }
      .padding(message.role == .user ? 10 : 0)
      .background(
        message.role == .user ? SolnariTheme.indigo.opacity(0.10) : .clear,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      if message.role == .assistant { Spacer(minLength: 4) }
    }
  }
}
