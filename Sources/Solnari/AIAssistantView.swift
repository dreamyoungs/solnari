import AppKit
import SwiftUI

struct AIAssistantView: View {
  @EnvironmentObject private var model: WorkspaceModel
  var body: some View {
    SQLAssistantPanel(assistant: model.assistant)
  }
}

private struct SQLAssistantPanel: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject var assistant: SQLAssistantModel
  @State private var review: AssistantSuggestion?
  @State private var showContext = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(settings.text("Ask Codex"), systemImage: "sparkles")
          .font(.headline)
        Spacer()
        Button {
          assistant.close()
        } label: {
          Image(systemName: "plus.bubble")
        }
        .help(settings.text("New conversation"))
        Button {
          assistant.close()
          model.isAssistantVisible = false
        } label: {
          Image(systemName: "xmark")
        }
      }
      .buttonStyle(.plain)
      .padding(13)
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Text(settings.text(assistant.status)).font(.caption).textSelection(.enabled)
        if !assistant.signedIn {
          HStack {
            Button(settings.text("Check connection")) { assistant.connect() }
            Menu(settings.text("Sign in")) {
              Button(settings.text("Browser sign-in")) { assistant.login(device: false) }
              Button(settings.text("Device code sign-in")) { assistant.login(device: true) }
            }
          }
          .disabled(assistant.isBusy)
        }
        if let url = assistant.loginURL {
          Link(settings.text("Open sign-in page"), destination: url)
          if let code = assistant.deviceCode {
            Text(code).font(.body.monospaced()).textSelection(.enabled)
          }
        }
        DisclosureGroup(settings.text("Context to send"), isExpanded: $showContext) {
          VStack(alignment: .leading, spacing: 7) {
            Toggle(settings.text("Include current SQL"), isOn: $assistant.includeSQL)
            Text(settings.text("Select up to 8 schema objects")).font(.caption)
            ScrollView {
              VStack(alignment: .leading) {
                ForEach(model.schemaObjects) { object in
                  Toggle(
                    object.qualifiedName,
                    isOn: Binding(
                      get: { assistant.selectedObjects.contains(object.id) },
                      set: {
                        if $0 {
                          assistant.selectedObjects.insert(object.id)
                        } else {
                          assistant.selectedObjects.remove(object.id)
                        }
                      }
                    ))
                }
              }
            }
            .frame(maxHeight: 100)
            Toggle(settings.text("Send first 10 result rows once"), isOn: $assistant.includeRows)
            Text(
              settings.text(
                "Selected SQL, schema and opted-in rows are sent to OpenAI through your ChatGPT account. Result sharing resets after each request."
              )
            )
            .font(.caption2).foregroundStyle(.secondary)
          }
          .padding(.top, 6)
        }
        .disabled(assistant.isBusy)
        Text(settings.text("Drafts only · review SQL before running"))
          .font(.caption2).foregroundStyle(.secondary)
      }
      .padding(12)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 14) {
            if assistant.messages.isEmpty {
              Text(
                settings.text(
                  "Ask a question. Database context is excluded until you select it. Conversations are kept in memory only."
                )
              )
              .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(assistant.messages) { message in
              AssistantMessageView(message: message) { sql in
                review = AssistantSuggestion(explanation: message.text, sql: sql)
              }
            }
            if assistant.isBusy {
              Text(
                assistant.streamedText.isEmpty
                  ? settings.text("Waiting for Codex…") : assistant.streamedText
              )
              .font(.callout).textSelection(.enabled)
            }
            Color.clear.frame(height: 1).id("end")
          }
          .padding(13)
        }
        .onChange(of: assistant.streamedText) { proxy.scrollTo("end", anchor: .bottom) }
        .onChange(of: assistant.messages.count) { proxy.scrollTo("end", anchor: .bottom) }
      }
      Divider()
      VStack(spacing: 8) {
        TextEditor(text: $assistant.draft)
          .font(.system(size: 12))
          .frame(minHeight: 50, maxHeight: 90)
          .accessibilityLabel(settings.text("Ask about your data or SQL…"))
        HStack {
          Text(contextSummary).font(.caption2).foregroundStyle(.secondary)
          Spacer()
          if assistant.isBusy {
            Button(settings.text("Cancel")) { assistant.cancel() }
          } else {
            Button(settings.text("Send")) { assistant.send(workspace: model) }
              .disabled(
                !assistant.signedIn
                  || assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
      .padding(12)
    }
    .background(SolnariTheme.panel)
    .onChange(of: model.selectedConnectionID) { assistant.close() }
    .onDisappear { assistant.close() }
    .sheet(item: $review) { suggestion in
      VStack(alignment: .leading, spacing: 14) {
        Text(settings.text("Review SQL suggestion")).font(.headline)
        HStack(alignment: .top, spacing: 16) {
          reviewColumn("Current SQL", sql: model.selectedTab?.sql ?? "")
          reviewColumn("Suggested SQL", sql: suggestion.sql ?? "")
        }
        Text(settings.text("This creates a new query tab. SQL is not executed automatically."))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button(settings.text("Cancel")) { review = nil }
          Button(settings.text("Use in editor")) {
            if let sql = suggestion.sql {
              model.newQueryTab()
              model.useSQL(sql)
            }
            review = nil
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(20).frame(width: 760, height: 500)
    }
  }

  private var contextSummary: String {
    if assistant.includeRows { return settings.text("Includes up to 10 result rows") }
    if assistant.includeSQL || !assistant.selectedObjects.isEmpty {
      return settings.text("Selected context attached")
    }
    return settings.text("No database context")
  }
  private func reviewColumn(_ title: String, sql: String) -> some View {
    VStack(alignment: .leading) {
      Text(settings.text(title)).font(.subheadline)
      ScrollView {
        Text(sql).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Text(message.text)
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
