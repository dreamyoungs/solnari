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
    }
    .formStyle(.grouped)
    .navigationTitle(settings.text("Settings"))
    .frame(width: 470, height: 280)
  }
}
