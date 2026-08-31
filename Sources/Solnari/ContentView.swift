import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 236, ideal: 268, max: 320)
    } detail: {
      HStack(spacing: 0) {
        WorkspaceView()
          .frame(minWidth: 660)
          .frame(maxWidth: .infinity)
          .clipped()

        if model.isAssistantVisible {
          AIAssistantView()
            .frame(width: 340)
        }
      }
      .background(Color(nsColor: .textBackgroundColor))
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          withAnimation(.snappy) {
            model.isAssistantVisible.toggle()
          }
        } label: {
          Image(systemName: "sparkles")
            .foregroundStyle(model.isAssistantVisible ? SolnariTheme.indigo : .secondary)
        }
        .help(settings.text("Toggle Codex"))

        Button {
          model.beginNewConnection()
        } label: {
          Label(settings.text("New Connection"), systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .tint(SolnariTheme.indigo)
      }
    }
    .sheet(
      isPresented: $model.showNewConnection,
      onDismiss: { model.finishConnectionPresentation() }
    ) {
      NewConnectionView(profile: model.editingConnection)
        .environmentObject(model)
    }
    .task {
      await model.activateSelectedConnection()
    }
    .onChange(of: model.selectedConnectionID) {
      Task { await model.activateSelectedConnection() }
    }
    .alert(
      settings.text("Database error"),
      isPresented: Binding(
        get: { model.presentedError != nil },
        set: { if !$0 { model.presentedError = nil } }
      )
    ) {
      Button(settings.text("OK")) { model.presentedError = nil }
    } message: {
      Text(settings.text(model.presentedError ?? ""))
    }
    .tint(SolnariTheme.indigo)
  }
}
