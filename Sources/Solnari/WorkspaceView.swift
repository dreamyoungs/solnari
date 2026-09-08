import AppKit
import SwiftUI

struct WorkspaceView: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings
  @State private var editorHeight: CGFloat?

  var body: some View {
    VStack(spacing: 0) {
      connectionBar
      EditorTabBar()

      if let tab = model.selectedTab, let object = tab.schemaObject,
        let profileID = model.selectedConnectionID
      {
        SchemaInspectorView(object: object, profileID: profileID, tabID: tab.id)
          .id(tab.id)
      } else {
        workspaceSplit
      }

      statusBar
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var workspaceSplit: some View {
    GeometryReader { proxy in
      let dividerHeight: CGFloat = 15
      let defaultHeight = max(230, proxy.size.height * 0.49)
      let maximumHeight = max(230, proxy.size.height - 250 - dividerHeight)
      let resolvedHeight = min(max(editorHeight ?? defaultHeight, 230), maximumHeight)

      VStack(spacing: 0) {
        SQLEditorPane()
          .frame(height: resolvedHeight)

        HorizontalResizeHandle(
          height: Binding(
            get: { resolvedHeight },
            set: { editorHeight = $0 }
          ),
          minimumHeight: 230,
          maximumHeight: maximumHeight,
          resetHeight: defaultHeight
        )
        .frame(height: dividerHeight)

        ResultsPane()
          .frame(maxHeight: .infinity)
      }
    }
  }

  private var connectionBar: some View {
    HStack(spacing: 10) {
      if let connection = model.selectedConnection {
        HStack(spacing: 7) {
          StatusDot(color: connection.status.color)
          Text(connection.name)
            .font(.system(size: 13, weight: .semibold))
          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
          Text(connection.database)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }

        DatabaseEnginePill(engine: connection.engine)
        PillLabel(connection.transport.rawValue, symbol: connection.transport.symbol)
        PillLabel(
          connection.effectiveSecurityPolicy.rawValue,
          symbol: connection.effectiveSecurityPolicy.symbol,
          tint: connection.effectiveSecurityPolicy.tint
        )
        PillLabel(
          connection.effectiveAccessLevel.rawValue,
          symbol: connection.effectiveAccessLevel.symbol,
          tint: connection.effectiveAccessLevel.tint
        )
      }

      Spacer()

      Button {
        if let profileID = model.selectedConnectionID {
          Task { await model.connect(profileID: profileID) }
        }
      } label: {
        Image(systemName: "arrow.triangle.2.circlepath")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(settings.text("Reconnect"))
      .disabled(model.isConnecting || model.isRunning || model.selectedConnectionID == nil)

      Button {
      } label: {
        Label(settings.text("Share"), systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 14)
    .frame(height: 43)
    .background(SolnariTheme.elevated)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var statusBar: some View {
    HStack(spacing: 13) {
      if let connection = model.selectedConnection {
        Label(
          connection.serverVersion.map { "\(connection.engine.rawValue) \($0)" }
            ?? connection.engine.rawValue,
          systemImage: "cylinder")
        Divider().frame(height: 12)
        Label(settings.text(connection.status.rawValue), systemImage: "network")
      } else {
        Label(settings.text("No connection"), systemImage: "cylinder")
      }
      Spacer()
      Text(settings.text("Ln 12, Col 10"))
      if let connection = model.selectedConnection {
        Divider().frame(height: 12)
        Text(connection.serverEncoding ?? connection.clientEncoding)
        Divider().frame(height: 12)
        Text(connection.serverTimeZone ?? TimeZone.current.identifier)
      }
    }
    .font(.system(size: 10))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .frame(height: 27)
    .background(SolnariTheme.elevated)
    .overlay(alignment: .top) { Divider() }
  }
}

private struct HorizontalResizeHandle: View {
  @Binding var height: CGFloat
  let minimumHeight: CGFloat
  let maximumHeight: CGFloat
  let resetHeight: CGFloat
  @State private var dragStartHeight: CGFloat?
  @State private var isHovering = false

  var body: some View {
    Rectangle()
      .fill(isHovering ? SolnariTheme.indigo.opacity(0.09) : SolnariTheme.panel)
      .contentShape(Rectangle())
      .overlay {
        ZStack {
          Rectangle()
            .fill(SolnariTheme.border)
            .frame(height: 1)
          Capsule()
            .fill(isHovering ? SolnariTheme.indigo : Color.secondary.opacity(0.35))
            .frame(width: isHovering ? 52 : 42, height: isHovering ? 4 : 3)
        }
      }
      .highPriorityGesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            if dragStartHeight == nil {
              dragStartHeight = height
            }
            height = min(
              maximumHeight,
              max(minimumHeight, (dragStartHeight ?? height) + value.translation.height)
            )
          }
          .onEnded { _ in
            dragStartHeight = nil
          }
      )
      .onTapGesture(count: 2) {
        height = resetHeight
      }
      .onHover { hovering in
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
          NSCursor.resizeUpDown.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        if isHovering { NSCursor.pop() }
      }
  }
}

private struct EditorTabBar: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          ForEach(model.editorTabs) { tab in
            editorTab(tab)
          }
        }
      }

      Divider().frame(height: 20)

      Button {
        model.newQueryTab()
      } label: {
        Image(systemName: "plus")
          .frame(width: 32, height: 32)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)

      Spacer(minLength: 0)
    }
    .frame(height: 36)
    .background(SolnariTheme.panel)
    .overlay(alignment: .bottom) { Divider() }
  }

  private func editorTab(_ tab: EditorTab) -> some View {
    let isSelected = model.selectedTabID == tab.id
    return HStack(spacing: 7) {
      Image(systemName: tab.schemaObject?.kind.symbol ?? "terminal")
        .font(.caption)
        .foregroundStyle(isSelected ? SolnariTheme.indigo : .secondary)
      Text(settings.text(tab.title))
        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
        .italic(tab.isPreview)
      if tab.isPreview {
        Button {
          model.pinTab(tab.id)
        } label: {
          Image(systemName: "pin")
        }
        .buttonStyle(.plain)
        .help(settings.text("Pin tab"))
        .accessibilityLabel(settings.text("Pin tab"))
      }
      if tab.isModified {
        Circle()
          .fill(.secondary)
          .frame(width: 5, height: 5)
      }
      Button {
        model.closeTab(tab.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tertiary)
    }
    .padding(.horizontal, 11)
    .frame(height: 35)
    .background(isSelected ? Color(nsColor: .textBackgroundColor) : .clear)
    .overlay(alignment: .bottom) {
      if isSelected {
        Rectangle().fill(SolnariTheme.indigo).frame(height: 2)
      }
    }
    .overlay(alignment: .trailing) { Divider() }
    .contentShape(Rectangle())
    .focusable()
    .onKeyPress(.return) {
      model.selectedTabID = tab.id
      return .handled
    }
    .onTapGesture { model.selectedTabID = tab.id }
    .simultaneousGesture(TapGesture(count: 2).onEnded { model.pinTab(tab.id) })
    .contextMenu {
      Button(settings.text("Pin tab")) { model.pinTab(tab.id) }
        .disabled(!tab.isPreview)
      Button(settings.text("Close")) { model.closeTab(tab.id) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(tab.title + (tab.isPreview ? " · " + settings.text("Preview") : ""))
    .accessibilityAction(named: Text(settings.text("Open"))) { model.selectedTabID = tab.id }
    .accessibilityAction(named: Text(settings.text("Pin tab"))) { model.pinTab(tab.id) }
  }
}

private struct SQLEditorPane: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    VStack(spacing: 0) {
      queryToolbar
      editor
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var queryToolbar: some View {
    HStack(spacing: 8) {
      Button {
        Task { await model.runCurrentQuery() }
      } label: {
        HStack(spacing: 6) {
          if model.isRunning {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "play.fill")
          }
          Text(settings.text(model.isRunning ? "Running" : "Run"))
        }
      }
      .buttonStyle(.borderedProminent)
      .tint(SolnariTheme.mint)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(model.isRunning || model.selectedConnectionID == nil)

      Menu {
        Button(settings.text("Run current statement")) {}
        Button(settings.text("Run selected text")) {}
        Button(settings.text("Run all statements")) {}
      } label: {
        Image(systemName: "chevron.down")
      }
      .menuStyle(.borderlessButton)
      .frame(width: 20)

      Divider().frame(height: 18)

      Button {
        model.formatCurrentSQL()
      } label: {
        Label(settings.text("Format"), systemImage: "wand.and.stars")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)

      Button {
        model.explainCurrentQuery()
      } label: {
        Label(settings.text("Explain"), systemImage: "chart.bar.doc.horizontal")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .disabled(!model.canExplain)

      Spacer()

      Menu {
        Button(settings.text("Read/write session")) {}
        Button(settings.text("Read-only session")) {}
        Divider()
        Button(settings.text("Auto commit")) {}
      } label: {
        HStack(spacing: 5) {
          StatusDot(color: SolnariTheme.mint, size: 5)
          Text(settings.text("Auto commit"))
          Image(systemName: "chevron.down")
            .font(.system(size: 8))
        }
        .font(.caption)
      }
      .menuStyle(.borderlessButton)
      .frame(width: 104)
    }
    .padding(.horizontal, 12)
    .frame(height: 40)
    .background(SolnariTheme.elevated)
    .overlay(alignment: .bottom) { Divider() }
  }

  @ViewBuilder
  private var editor: some View {
    if let selectedTabID = model.selectedTabID,
      let tab = model.editorTabs.first(where: { $0.id == selectedTabID })
    {
      HStack(spacing: 0) {
        lineNumbers(for: tab.sql)
        SQLTextEditor(
          text: model.sqlBinding(for: selectedTabID),
          engine: model.selectedConnection?.engine ?? .postgresql,
          formatRequestID: model.formatRequestID,
          onError: { model.presentedError = $0 }
        )
        .id(selectedTabID)
      }
    } else {
      ContentUnavailableView {
        Label(settings.text("No query"), systemImage: "terminal")
      } description: {
        Text(settings.text("Create a query tab to begin."))
      }
    }
  }

  private func lineNumbers(for sql: String) -> some View {
    let count = max(1, sql.components(separatedBy: .newlines).count)
    return VStack(alignment: .trailing, spacing: 0) {
      ForEach(1...count, id: \.self) { line in
        Text("\(line)")
          .frame(height: 22, alignment: .trailing)
      }
      Spacer(minLength: 0)
    }
    .font(.system(size: 11, design: .monospaced))
    .foregroundStyle(.tertiary)
    .padding(.top, 12)
    .padding(.horizontal, 9)
    .frame(width: 43)
    .background(SolnariTheme.subtleFill)
    .overlay(alignment: .trailing) { Divider() }
  }
}

private struct ResultsPane: View {
  @EnvironmentObject private var model: WorkspaceModel
  @EnvironmentObject private var settings: AppSettings

  @State private var columnWidths: [String: CGFloat] = [:]
  @State private var exportNotice: String?
  @State private var planColumnWidths: [String: CGFloat] = [:]

  private var columns: [ResultColumn] {
    model.queryTable.columns.enumerated().map { index, title in
      ResultColumn(
        id: "column-\(index)",
        initialWidth: min(280, max(100, CGFloat(title.count * 8 + 36)))
      )
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      resultToolbar
      if model.selectedResultTab == "Results" {
        resultGrid
      } else if model.selectedResultTab == "Explain" {
        planResults
      } else {
        explainPlaceholder
      }
    }
    .background(SolnariTheme.elevated)
    .onChange(of: model.queryTable.columns) {
      resetColumnWidths()
    }
  }

  private var resultToolbar: some View {
    HStack(spacing: 18) {
      resultTab("Results", symbol: "tablecells")
      resultTab("Explain", symbol: "chart.bar.xaxis")
      resultTab("Messages", symbol: "text.bubble")
      Spacer()
      if let exportNotice {
        Label(exportNotice, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(SolnariTheme.mint)
          .transition(.opacity)
      } else if model.selectedResultTab != "Explain" {
        Text(settings.text(model.executionMessage))
          .font(.caption)
          .foregroundStyle(model.isRunning ? SolnariTheme.orange : .secondary)
      }
      if model.selectedResultTab == "Results" {
        exportMenu
        resultOptionsMenu
      }
    }
    .padding(.horizontal, 13)
    .frame(height: 39)
    .background(SolnariTheme.panel)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var exportMenu: some View {
    Menu {
      Menu(settings.text("Copy as")) {
        ForEach(ExportFormat.allCases) { format in
          Button {
            ResultExporter.copy(model.queryTable, format: format)
            showExportNotice("\(format.rawValue) \(settings.text("Copied"))")
          } label: {
            Label(format.rawValue, systemImage: format.symbol)
          }
        }
      }

      Menu(settings.text("Save as file")) {
        ForEach(ExportFormat.allCases) { format in
          Button {
            do {
              if try ResultExporter.save(
                model.queryTable,
                format: format,
                panelTitle: settings.text("Export Query Result")
              ) != nil {
                showExportNotice("\(format.rawValue) \(settings.text("Saved"))")
              }
            } catch {
              showExportNotice(settings.text("Export failed"))
            }
          } label: {
            Label(format.rawValue, systemImage: format.symbol)
          }
        }
      }

      Divider()

      Button {
        ResultExporter.copy(model.queryTable, format: .tsv)
        showExportNotice(settings.text("Copied for spreadsheet paste"))
      } label: {
        Label(settings.text("Copy for spreadsheet"), systemImage: "clipboard")
      }
    } label: {
      Image(systemName: "square.and.arrow.up")
        .symbolRenderingMode(.monochrome)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .foregroundStyle(.secondary)
    .help(settings.text("Export result"))
  }

  private var resultOptionsMenu: some View {
    Menu {
      Button {
        Task { await model.runCurrentQuery() }
      } label: {
        Label(settings.text("Run query again"), systemImage: "arrow.clockwise")
      }

      Menu(settings.text("Column widths")) {
        Button {
          fitColumnsToContent()
        } label: {
          Label(settings.text("Fit to content"), systemImage: "arrow.left.and.right.text.vertical")
        }

        Button {
          resetColumnWidths()
        } label: {
          Label(settings.text("Reset widths"), systemImage: "arrow.counterclockwise")
        }
      }

      Divider()

      Button {
        ResultExporter.copy(model.queryTable, format: .csv)
        showExportNotice("CSV \(settings.text("Copied"))")
      } label: {
        Label(settings.text("Copy all as CSV"), systemImage: "doc.on.doc")
      }

      Button {
        ResultExporter.copy(model.queryTable, format: .json)
        showExportNotice("JSON \(settings.text("Copied"))")
      } label: {
        Label(settings.text("Copy all as JSON"), systemImage: "curlybraces")
      }

      Divider()

      Button(role: .destructive) {
        model.clearResults()
      } label: {
        Label(settings.text("Clear results"), systemImage: "trash")
      }
      .disabled(model.queryTable.rows.isEmpty && model.queryTable.columns.isEmpty)
    } label: {
      Image(systemName: "ellipsis.circle")
        .symbolRenderingMode(.monochrome)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .foregroundStyle(.secondary)
    .help(settings.text("Result options"))
  }

  private func resultTab(_ title: String, symbol: String) -> some View {
    Button {
      model.selectedResultTab = title
    } label: {
      HStack(spacing: 6) {
        Image(systemName: symbol)
        Text(settings.text(title))
      }
      .font(.system(size: 12, weight: model.selectedResultTab == title ? .semibold : .regular))
      .foregroundStyle(model.selectedResultTab == title ? .primary : .secondary)
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottom) {
      if model.selectedResultTab == title {
        Rectangle()
          .fill(SolnariTheme.indigo)
          .frame(height: 2)
          .offset(y: 11)
      }
    }
  }

  private var resultGrid: some View {
    ResultTableView(
      table: model.queryTable,
      displayTimeZone: settings.displayTimeZone,
      sourceObject: model.querySourceObject,
      canGenerateDeleteQuery: model.canGenerateDeleteQueryFromResult,
      localizedText: settings.text,
      onGenerateQuery: { row, column, action in
        model.generateQueryFromResultCell(
          rowIndex: row,
          columnIndex: column,
          action: action
        )
      },
      columnWidths: $columnWidths
    )
    .overlay {
      if model.isRunning {
        ZStack {
          Color(nsColor: .textBackgroundColor).opacity(0.75)
          ProgressView("Running query…")
            .controlSize(.small)
        }
      }
    }
  }

  private var explainPlaceholder: some View {
    ContentUnavailableView {
      Label(
        settings.text(model.selectedResultTab),
        systemImage: model.selectedResultTab == "Explain" ? "chart.bar.xaxis" : "text.bubble")
    } description: {
      Text(
        settings.text(
          model.selectedResultTab == "Explain"
            ? "Run EXPLAIN to inspect the query plan." : "Server messages will appear here."))
    }
  }

  private var planResults: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(settings.text(model.planMessage))
          .font(.caption)
          .textSelection(.enabled)
        Spacer()
        if model.isPlanning {
          ProgressView().controlSize(.small)
          Button(settings.text("Cancel")) { model.cancelQueryPlan() }
            .help(settings.text("Cancel closes this connection."))
        }
        Button(settings.text("Copy plan SQL")) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(model.planSQL, forType: .string)
        }
        .disabled(model.planSQL.isEmpty)
      }
      .padding(.horizontal, 13)
      .padding(.top, 8)
      ResultTableView(
        table: model.planTable,
        displayTimeZone: settings.displayTimeZone,
        sourceObject: nil,
        canGenerateDeleteQuery: false,
        localizedText: settings.text,
        onGenerateQuery: { _, _, _ in },
        columnWidths: $planColumnWidths
      )
    }
    .onAppear { fitPlanColumns() }
    .onChange(of: model.planTable) { fitPlanColumns() }
  }

  private func fitPlanColumns() {
    let table = model.planTable
    planColumnWidths = Dictionary(
      uniqueKeysWithValues: table.columns.enumerated().map { index, title in
        let values = table.rows.prefix(100).compactMap {
          $0.indices.contains(index) ? $0[index] : nil
        }
        return (
          "column-\(index)",
          ResultColumnWidthCalculator.fittedWidth(
            title: title, values: values, displayTimeZone: settings.displayTimeZone)
        )
      })
  }

  private func resetColumnWidths() {
    withAnimation(.easeOut(duration: 0.16)) {
      columnWidths = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0.initialWidth) })
    }
  }

  private func fitColumnsToContent() {
    let table = model.queryTable
    var fitted: [String: CGFloat] = [:]

    for (index, column) in columns.enumerated() {
      let values: [QueryCellValue] = table.rows.compactMap { row in
        row.indices.contains(index) ? row[index] : nil
      }
      fitted[column.id] = ResultColumnWidthCalculator.fittedWidth(
        title: table.columns[index],
        values: values,
        displayTimeZone: settings.displayTimeZone
      )
    }

    withAnimation(.easeOut(duration: 0.16)) {
      columnWidths = fitted
    }
  }

  private func showExportNotice(_ message: String) {
    withAnimation { exportNotice = message }
    Task {
      try? await Task.sleep(for: .seconds(1.6))
      guard exportNotice == message else { return }
      withAnimation { exportNotice = nil }
    }
  }
}

private struct ResultColumn: Identifiable {
  let id: String
  let initialWidth: CGFloat
}
