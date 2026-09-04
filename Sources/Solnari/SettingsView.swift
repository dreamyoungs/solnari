import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var workspace: WorkspaceModel
  @State private var showExportConfirmation = false
  @State private var transferNotice: ConnectionTransferNotice?

  var body: some View {
    TabView(selection: $settings.selectedSettingsTab) {
      generalSettings
        .tabItem {
          Label(settings.text("General"), systemImage: "gearshape")
        }
        .tag(SettingsTab.general)

      MCPSettingsView()
        .tabItem {
          Label(settings.text("MCP access"), systemImage: "point.3.connected.trianglepath.dotted")
        }
        .tag(SettingsTab.mcp)

      AboutSettingsView()
        .tabItem {
          Label(settings.text("About Solnari"), systemImage: "info.circle")
        }
        .tag(SettingsTab.about)
    }
    .frame(width: 580, height: 500)
    .confirmationDialog(
      settings.text("Export connection profiles?"),
      isPresented: $showExportConfirmation,
      titleVisibility: .visible
    ) {
      Button(settings.text("Export…")) {
        exportConnectionProfiles()
      }
      Button(settings.text("Cancel"), role: .cancel) {}
    } message: {
      Text(
        settings.text(
          "Passwords, encryption keys, credential references, and tokens are never exported. The file still contains sensitive hosts, usernames, database names, and cloud, SSH, or Kubernetes settings. Store and share it carefully. Imported credential-based connections require password entry or IAM reauthentication."
        )
      )
    }
    .alert(item: $transferNotice) { notice in
      Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .default(Text(settings.text("OK")))
      )
    }
  }

  private var generalSettings: some View {
    Form {
      Section {
        Picker(settings.text("Language"), selection: $settings.language) {
          Text(settings.text("Follow System")).tag(AppLanguage.system)
          Text("English").tag(AppLanguage.english)
          Text("한국어").tag(AppLanguage.korean)
        }
        .pickerStyle(.radioGroup)
      } header: {
        Text(settings.text("Appearance"))
      } footer: {
        Text(settings.text("The interface updates immediately when you change the language."))
          .foregroundStyle(.secondary)
      }

      Section {
        Picker(settings.text("Display time zone"), selection: $settings.displayTimeZoneOption) {
          ForEach(DisplayTimeZoneOption.allCases) { option in
            Text(settings.text(option.label)).tag(option)
          }
        }
      } header: {
        Text(settings.text("Query results"))
      } footer: {
        Text(
          settings.text(
            "Zoned timestamps are displayed in this time zone without changing their stored value.")
        )
        .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Text(
            String(
              format: settings.text("%d saved connection profiles"),
              workspace.connections.count
            )
          )
          .foregroundStyle(.secondary)

          Spacer()

          Button(settings.text("Import…")) {
            importConnectionProfiles()
          }

          Button(settings.text("Export…")) {
            showExportConfirmation = true
          }
          .disabled(workspace.connections.isEmpty)
        }
      } header: {
        Text(settings.text("Connection profiles"))
      } footer: {
        Text(
          settings.text(
            "Transfer non-secret connection settings. Passwords and authentication credentials are never included."
          )
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func exportConnectionProfiles() {
    do {
      let data = try workspace.exportConnectionProfiles()
      let panel = NSSavePanel()
      panel.title = settings.text("Save connection profiles")
      panel.nameFieldStringValue = "Solnari Connections.json"
      panel.allowedContentTypes = [.json]
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK, let url = panel.url else { return }

      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      transferNotice = ConnectionTransferNotice(
        title: settings.text("Export complete"),
        message: String(
          format: settings.text("Exported %d connection profiles without credentials."),
          workspace.connections.count
        )
      )
    } catch {
      transferNotice = ConnectionTransferNotice(
        title: settings.text("Export failed"),
        message: localizedTransferError(error)
      )
    }
  }

  private func importConnectionProfiles() {
    let panel = NSOpenPanel()
    panel.title = settings.text("Choose connection profile file")
    panel.allowedContentTypes = [.json]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      let summary = try workspace.importConnectionProfiles(data)
      transferNotice = ConnectionTransferNotice(
        title: settings.text("Import complete"),
        message: String(
          format: settings.text(
            "Imported %d connection profiles. %d names were adjusted to avoid conflicts. Credential-based connections require password entry or IAM reauthentication."
          ),
          summary.importedCount,
          summary.renamedCount
        )
      )
    } catch {
      transferNotice = ConnectionTransferNotice(
        title: settings.text("Import failed"),
        message: localizedTransferError(error)
      )
    }
  }

  private func localizedTransferError(_ error: Error) -> String {
    guard let transferError = error as? ConnectionProfileTransferError else {
      return error.localizedDescription
    }
    switch transferError {
    case .documentTooLarge:
      return settings.text("The connection profile file is larger than the 5 MB limit.")
    case .invalidDocument:
      return settings.text(
        "The selected file is not a valid Solnari connection profile document.")
    case .invalidFormat:
      return settings.text(
        "The selected JSON file is not a Solnari connection profile document.")
    case .unsupportedVersion(let version):
      return String(
        format: settings.text("Connection profile format version %d is not supported."),
        version
      )
    case .tooManyConnections:
      return settings.text("A connection profile file can contain at most 1,000 connections.")
    case .unknownFields(let context, let fields):
      return String(
        format: settings.text("Unsupported fields in %@: %@."),
        context,
        fields.joined(separator: ", ")
      )
    case .invalidConnection(let index, let reason):
      return String(
        format: settings.text("Connection %d is invalid: %@"),
        index + 1,
        settings.text(reason)
      )
    }
  }
}

private struct ConnectionTransferNotice: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

private struct AboutSettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @State private var presentedLicense: LicenseDocument?

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
  }

  private var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
  }

  var body: some View {
    VStack(spacing: 20) {
      VStack(spacing: 10) {
        Image("SolnariIcon", bundle: SolnariResources.bundle)
          .resizable()
          .scaledToFit()
          .frame(width: 88, height: 88)
          .accessibilityHidden(true)

        Text("Solnari")
          .font(.title2.weight(.semibold))

        Text(String(format: settings.text("Version %@ (%@)"), version, build))
          .font(.callout)
          .foregroundStyle(.secondary)

        Text(settings.text("A native open-source database tool for macOS."))
          .foregroundStyle(.secondary)
      }

      GroupBox {
        VStack(spacing: 0) {
          aboutRow(
            title: settings.text("Solnari license"),
            detail: "Apache License 2.0"
          ) {
            presentedLicense = .solnari
          }

          Divider()

          aboutRow(
            title: settings.text("Open-source licenses"),
            detail: settings.text("Node.js, Swift and npm dependencies")
          ) {
            presentedLicense = .thirdParty
          }
        }
      }
      .frame(maxWidth: 430)

      Link(
        settings.text("View source on GitHub"),
        destination: URL(string: "https://github.com/dreamyoungs/solnari")!
      )

      Text(settings.text("Copyright © 2026 Solnari contributors."))
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(28)
    .sheet(item: $presentedLicense) { document in
      LicenseDocumentView(document: document)
        .environmentObject(settings)
    }
  }

  private func aboutRow(
    title: String,
    detail: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .foregroundStyle(.primary)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .contentShape(Rectangle())
      .padding(.vertical, 10)
      .padding(.horizontal, 12)
    }
    .buttonStyle(.plain)
  }
}
