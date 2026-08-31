import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.openSettings) private var openSettings
  @State private var searchText = ""
  @State private var schemasExpanded = true
  @State private var tablesExpanded = true
  @State private var viewsExpanded = true

  private var filteredConnections: [ConnectionProfile] {
    guard !searchText.isEmpty else { return model.connections }
    return model.connections.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
        || $0.database.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      brandHeader

      List(selection: $model.selectedConnectionID) {
        Section {
          ForEach(filteredConnections) { connection in
            ConnectionRow(connection: connection)
              .tag(connection.id)
              .contextMenu {
                Button(settings.text("Connect")) {
                  Task { await model.connect(profileID: connection.id) }
                }
                Button(settings.text("Edit…")) {}
                  .disabled(true)
                Divider()
                Button(settings.text("Remove"), role: .destructive) {
                  Task { await model.removeConnection(connection.id) }
                }
              }
          }
        } header: {
          sectionHeader("Connections", count: filteredConnections.count) {
            model.showNewConnection = true
          }
        }

        if let connection = model.selectedConnection {
          Section {
            databaseTree(connection)
          } header: {
            sectionHeader("Explorer", count: nil) {}
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .searchable(
        text: $searchText, placement: .sidebar, prompt: Text(settings.text("Connections")))

      sidebarFooter
    }
    .background(SolnariTheme.sidebar)
  }

  private var brandHeader: some View {
    HStack(spacing: 11) {
      SolnariMark(size: 32)
      VStack(alignment: .leading, spacing: 1) {
        Text("Solnari")
          .font(.system(size: 16, weight: .bold, design: .rounded))
        Text(settings.text("Database workspace"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 13)
    .padding(.bottom, 10)
  }

  private func sectionHeader(_ title: String, count: Int?, action: @escaping () -> Void)
    -> some View
  {
    HStack {
      Text(settings.text(title))
      if let count {
        Text("\(count)")
          .foregroundStyle(.tertiary)
      }
      Spacer()
      if title == "Connections" {
        Button(action: action) {
          Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        .help(settings.text("New connection"))
      }
    }
  }

  @ViewBuilder
  private func databaseTree(_ connection: ConnectionProfile) -> some View {
    DisclosureGroup(isExpanded: $schemasExpanded) {
      DisclosureGroup(isExpanded: $tablesExpanded) {
        ForEach(model.schemaObjects.filter { $0.kind == .table }) { object in
          SchemaObjectRow(object: object)
        }
      } label: {
        treeLabel(
          "Tables", symbol: "tablecells",
          count: model.schemaObjects.filter { $0.kind == .table }.count)
      }

      DisclosureGroup(isExpanded: $viewsExpanded) {
        ForEach(
          model.schemaObjects.filter { $0.kind == .view || $0.kind == .materializedView }
        ) { object in
          SchemaObjectRow(object: object)
        }
      } label: {
        treeLabel(
          "Views", symbol: "eye",
          count: model.schemaObjects.filter { $0.kind == .view || $0.kind == .materializedView }
            .count)
      }
    } label: {
      HStack(spacing: 7) {
        Image(systemName: "cylinder")
          .foregroundStyle(connection.engine.tint)
        Text(connection.database)
          .fontWeight(.medium)
        Spacer()
        Button {
          Task { await model.refreshSchema() }
        } label: {
          Image(systemName: "arrow.clockwise")
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func treeLabel(_ title: String, symbol: String, count: Int) -> some View {
    HStack(spacing: 7) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 15)
      Text(settings.text(title))
      Spacer()
      Text("\(count)")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private var sidebarFooter: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.seal.fill")
        .foregroundStyle(SolnariTheme.orange)
      VStack(alignment: .leading, spacing: 1) {
        Text(settings.text("Codex preview"))
          .font(.caption.weight(.medium))
        Text(settings.text("Integration planned"))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .padding(12)
    .background(SolnariTheme.sidebarElevated)
    .overlay(alignment: .top) { Divider() }
  }
}

private struct ConnectionRow: View {
  @EnvironmentObject private var settings: AppSettings
  let connection: ConnectionProfile

  var body: some View {
    HStack(spacing: 10) {
      ZStack(alignment: .bottomTrailing) {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(connection.engine.tint.opacity(0.12))
          .frame(width: 31, height: 31)
          .overlay {
            Image(systemName: connection.engine.symbol)
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(connection.engine.tint)
          }
        StatusDot(color: connection.status.color, size: 6)
          .background(SolnariTheme.sidebar, in: Circle())
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(connection.name)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Text(connection.subtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Image(systemName: connection.transport.symbol)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 3)
  }
}

private struct SchemaObjectRow: View {
  @EnvironmentObject private var settings: AppSettings
  let object: SchemaObject

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: object.kind.symbol)
        .font(.caption)
        .foregroundStyle(object.kind == .view ? SolnariTheme.orange : .secondary)
        .frame(width: 15)
      Text(object.schema == "public" ? object.name : object.qualifiedName)
        .font(.system(size: 12))
      Spacer()
      Text(localizedMetadata)
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }
    .contextMenu {
      Button(settings.text("Open data")) {}
      Button(settings.text("Copy qualified name")) {}
      Button(settings.text("Generate SELECT")) {}
    }
  }

  private var localizedMetadata: String {
    if object.metadata.hasSuffix(" columns"),
      let count = object.metadata.split(separator: " ").first
    {
      return settings.effectiveLanguage == .korean ? "\(count)개 컬럼" : object.metadata
    }
    return settings.text(object.metadata)
  }
}
