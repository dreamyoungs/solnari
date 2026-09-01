import AppKit
import SwiftUI

struct MCPSettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var mcpAccess: MCPAccessController

  var body: some View {
    Form {
      Section {
        Toggle(
          settings.text("Allow local MCP access"),
          isOn: Binding(
            get: { mcpAccess.isEnabled },
            set: { mcpAccess.setEnabled($0) }
          )
        )

        HStack(spacing: 8) {
          Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
          Text(settings.text(statusText))
            .foregroundStyle(.secondary)
        }
      } header: {
        Text(settings.text("External agent access"))
      } footer: {
        Text(
          settings.text(
            "MCP is off by default and available only while Solnari is running and unlocked."
          )
        )
        .foregroundStyle(.secondary)
      }

      Section {
        VStack(alignment: .leading, spacing: 10) {
          scopeRow(
            symbol: "sidebar.left",
            text: settings.text("Only the currently selected connection is exposed.")
          )
          scopeRow(
            symbol: "key.slash",
            text: settings.text(
              "Credentials, hosts, and cloud project identifiers are never exposed.")
          )
          scopeRow(
            symbol: "eye.fill",
            text: settings.text("Query tools require an already connected read-only profile.")
          )
        }
        .padding(.vertical, 4)
      } header: {
        Text(settings.text("Access boundary"))
      }

      Section {
        if let command = mcpAccess.registrationCommand {
          Text(command)
            .font(.system(size: 10.5, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(4)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 7))

          HStack {
            Button(settings.text("Copy Codex registration command")) {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(command, forType: .string)
            }
            Spacer()
            Text(settings.text("Run once, then restart Codex."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else {
          Text(
            settings.text("Build the Solnari app bundle to generate its MCP registration command.")
          )
          .foregroundStyle(.secondary)
        }
      } header: {
        Text(settings.text("Connect Codex"))
      }
    }
    .formStyle(.grouped)
  }

  private func scopeRow(symbol: String, text: String) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: symbol)
        .foregroundStyle(SolnariTheme.indigo)
        .frame(width: 18)
      Text(text)
        .font(.callout)
    }
  }

  private var statusText: String {
    switch mcpAccess.state {
    case .disabled: "MCP access is disabled"
    case .starting: "Starting local MCP bridge…"
    case .ready: "Local MCP bridge is ready"
    case .suspended: "MCP access is suspended while this Mac is locked or sleeping"
    case .failed: "Local MCP bridge could not start"
    }
  }

  private var statusColor: Color {
    switch mcpAccess.state {
    case .ready: SolnariTheme.mint
    case .starting: SolnariTheme.orange
    case .failed: .red
    case .disabled, .suspended: .secondary
    }
  }
}
