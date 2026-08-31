import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
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
    .navigationTitle(settings.text("Settings"))
    .frame(width: 500, height: 390)
  }
}
