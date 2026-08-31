import SwiftUI

@main
struct SolnariApp: App {
  @StateObject private var workspace = WorkspaceModel()
  @StateObject private var settings = AppSettings()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(workspace)
        .environmentObject(settings)
        .environment(\.locale, settings.locale)
        .frame(minWidth: 1_180, minHeight: 720)
    }
    .defaultSize(width: 1_520, height: 940)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button(settings.text("New Connection")) {
          workspace.showNewConnection = true
        }
        .keyboardShortcut("n", modifiers: .command)
      }

      CommandMenu(settings.text("Query")) {
        Button(settings.text("Run Query")) {
          Task { await workspace.runCurrentQuery() }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(workspace.isRunning || workspace.selectedConnectionID == nil)

        Button(settings.text("Format SQL")) {
          workspace.formatCurrentSQL()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
      }
    }

    Settings {
      SettingsView()
        .environmentObject(settings)
        .environment(\.locale, settings.locale)
    }
  }
}
