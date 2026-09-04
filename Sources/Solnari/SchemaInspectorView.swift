import AppKit
import SwiftUI

struct SchemaInspectorView: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.dismiss) private var dismiss

  let object: SchemaObject
  @State private var details: SchemaObjectDetails?
  @State private var selectedTab: DetailTab = .columns
  @State private var isLoading = true
  @State private var errorMessage: String?
  @State private var errorDiagnostic: String?

  private enum DetailTab: String, CaseIterable, Identifiable {
    case columns = "Columns"
    case indexes = "Indexes"
    case constraints = "Constraints"
    case definition = "Definition"

    var id: String { rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      summary
      tabPicker
      content
      footer
    }
    .frame(width: 840, height: 600)
    .background(SolnariTheme.panel)
    .task(id: object.id) { await loadDetails() }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: object.kind.symbol)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(SolnariTheme.indigo)
        .frame(width: 36, height: 36)
        .background(
          SolnariTheme.indigo.opacity(0.10),
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
      VStack(alignment: .leading, spacing: 2) {
        Text(object.name)
          .font(.title3.weight(.semibold))
        Text(object.qualifiedName)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      Button {
        copyQualifiedName()
      } label: {
        Label(settings.text("Copy name"), systemImage: "doc.on.doc")
      }
      Button {
        model.generateSelect(for: object)
        dismiss()
      } label: {
        Label(settings.text("Generate SELECT"), systemImage: "terminal")
      }
      Button {
        dismiss()
        Task { await model.openData(for: object) }
      } label: {
        Label(settings.text("Open data"), systemImage: "tablecells")
      }
      .buttonStyle(.borderedProminent)
      .tint(SolnariTheme.indigo)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .frame(height: 72)
    .background(SolnariTheme.elevated)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var summary: some View {
    HStack(spacing: 18) {
      summaryItem("Schema", value: object.schema, symbol: "square.3.layers.3d")
      summaryItem("Object type", value: settings.text(objectTypeTitle), symbol: object.kind.symbol)
      summaryItem(
        "Columns", value: "\(details?.columns.count ?? object.columnCount)", symbol: "list.number")
      if let connection = model.selectedConnection {
        engineSummaryItem(connection.engine)
      }
      Spacer()
    }
    .padding(.horizontal, 20)
    .frame(height: 58)
    .background(SolnariTheme.subtleFill)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var objectTypeTitle: String {
    switch object.kind {
    case .table: "Table"
    case .view: "View"
    case .materializedView: "Materialized view"
    case .function: "Function"
    }
  }

  private func summaryItem(_ title: String, value: String, symbol: String) -> some View {
    HStack(spacing: 7) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(settings.text(title))
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.caption.weight(.medium))
          .lineLimit(1)
      }
    }
  }

  private func engineSummaryItem(_ engine: DatabaseEngine) -> some View {
    HStack(spacing: 7) {
      DatabaseEngineBadge(engine: engine, size: .inline)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text(settings.text("Engine"))
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(settings.text(engine.rawValue))
          .font(.caption.weight(.medium))
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(settings.text("Engine")): \(settings.text(engine.rawValue))")
  }

  private var tabPicker: some View {
    Picker("", selection: $selectedTab) {
      ForEach(availableTabs) { tab in
        Text(tabTitle(tab)).tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
  }

  private var availableTabs: [DetailTab] {
    var tabs: [DetailTab] = [.columns, .indexes, .constraints]
    if details?.definition != nil { tabs.append(.definition) }
    return tabs
  }

  private func tabTitle(_ tab: DetailTab) -> String {
    let count: Int?
    switch tab {
    case .columns: count = details?.columns.count
    case .indexes: count = details?.indexes.count
    case .constraints: count = details?.constraints.count
    case .definition: count = nil
    }
    if let count {
      return "\(settings.text(tab.rawValue)) \(count)"
    }
    return settings.text(tab.rawValue)
  }

  @ViewBuilder
  private var content: some View {
    if isLoading {
      VStack(spacing: 10) {
        ProgressView()
        Text(settings.text("Loading table structure…"))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let errorMessage {
      ContentUnavailableView {
        Label(settings.text("Could not load structure"), systemImage: "exclamationmark.triangle")
      } description: {
        VStack(spacing: 4) {
          Text(settings.text(errorMessage))
          if let errorDiagnostic {
            Text(errorDiagnostic)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
      } actions: {
        Button(settings.text("Try again")) { Task { await loadDetails() } }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let details {
      switch selectedTab {
      case .columns: columnsTable(details.columns)
      case .indexes: indexesTable(details.indexes)
      case .constraints: constraintsTable(details.constraints)
      case .definition: definitionView(details.definition)
      }
    }
  }

  private func columnsTable(_ columns: [SchemaColumn]) -> some View {
    Table(columns) {
      TableColumn(settings.text("#")) { column in
        Text("\(column.ordinalPosition)")
          .foregroundStyle(.secondary)
      }
      .width(min: 30, ideal: 36, max: 44)
      TableColumn(settings.text("Column")) { column in
        HStack(spacing: 6) {
          if column.isPrimaryKey {
            Image(systemName: "key.fill")
              .font(.caption2)
              .foregroundStyle(SolnariTheme.orange)
          }
          Text(column.name)
            .fontWeight(column.isPrimaryKey ? .medium : .regular)
        }
      }
      .width(min: 110, ideal: 150)
      TableColumn(settings.text("Type"), value: \.dataTypeDisplay)
        .width(min: 100, ideal: 145)
      TableColumn(settings.text("Nullable")) { column in
        Text(settings.text(column.isNullable ? "Yes" : "No"))
          .foregroundStyle(column.isNullable ? .secondary : .primary)
      }
      .width(min: 62, ideal: 72, max: 86)
      TableColumn(settings.text("Default"), value: \.defaultDisplay)
        .width(min: 90, ideal: 130)
      TableColumn(settings.text("Character set · Collation"), value: \.textRulesDisplay)
        .width(min: 120, ideal: 170)
      TableColumn(settings.text("Comment")) { column in
        Text(column.comment?.isEmpty == false ? column.comment ?? "" : "—")
          .foregroundStyle(column.comment?.isEmpty == false ? .primary : .tertiary)
      }
      .width(min: 100, ideal: 180)
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
  }

  @ViewBuilder
  private func indexesTable(_ indexes: [SchemaIndex]) -> some View {
    if indexes.isEmpty {
      emptyState("No indexes", symbol: "list.bullet.rectangle")
    } else {
      Table(indexes) {
        TableColumn(settings.text("Index"), value: \.name)
          .width(min: 150, ideal: 220)
        TableColumn(settings.text("Columns")) { index in
          Text(index.columns.joined(separator: ", "))
        }
        TableColumn(settings.text("Type")) { index in
          Text(index.isPrimary ? settings.text("Primary") : index.method ?? "—")
        }
        .width(min: 80, ideal: 110)
        TableColumn(settings.text("Unique")) { index in
          Text(settings.text(index.isUnique ? "Yes" : "No"))
        }
        .width(min: 60, ideal: 70, max: 84)
      }
      .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
  }

  @ViewBuilder
  private func constraintsTable(_ constraints: [SchemaConstraint]) -> some View {
    if constraints.isEmpty {
      emptyState("No constraints", symbol: "link.badge.plus")
    } else {
      Table(constraints) {
        TableColumn(settings.text("Constraint"), value: \.name)
          .width(min: 150, ideal: 210)
        TableColumn(settings.text("Type")) { constraint in
          Text(settings.text(constraint.kind.rawValue))
        }
        .width(min: 90, ideal: 110)
        TableColumn(settings.text("Columns")) { constraint in
          Text(constraint.columns.joined(separator: ", "))
        }
        TableColumn(settings.text("References"), value: \.referenceDisplay)
          .width(min: 130, ideal: 190)
        TableColumn(settings.text("Definition")) { constraint in
          Text(constraint.definition ?? "—")
            .lineLimit(2)
        }
        .width(min: 120, ideal: 220)
      }
      .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
  }

  @ViewBuilder
  private func definitionView(_ definition: String?) -> some View {
    if let definition, !definition.isEmpty {
      ScrollView {
        Text(definition)
          .font(.system(size: 12, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(18)
      }
      .background(Color(nsColor: .textBackgroundColor))
    } else {
      emptyState("No definition available", symbol: "doc.text.magnifyingglass")
    }
  }

  private func emptyState(_ title: String, symbol: String) -> some View {
    ContentUnavailableView {
      Label(settings.text(title), systemImage: symbol)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var footer: some View {
    HStack {
      Text(settings.text("Structure metadata is read directly from the connected database."))
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button(settings.text("Close")) { dismiss() }
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 20)
    .frame(height: 52)
    .background(SolnariTheme.elevated)
    .overlay(alignment: .top) { Divider() }
  }

  private func loadDetails() async {
    isLoading = true
    errorMessage = nil
    errorDiagnostic = nil
    do {
      details = try await model.loadSchemaObjectDetails(object)
    } catch {
      details = nil
      if let metadataError = error as? SchemaMetadataError {
        errorMessage = metadataError.messageKey
        errorDiagnostic =
          "\(settings.text(metadataError.stage.rawValue)) · \(metadataError.diagnosticCode)"
      } else {
        errorMessage = error.localizedDescription
      }
    }
    isLoading = false
  }

  private func copyQualifiedName() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(object.qualifiedName, forType: .string)
  }
}
