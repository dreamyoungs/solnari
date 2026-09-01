import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings

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
    }
    .formStyle(.grouped)
  }
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
