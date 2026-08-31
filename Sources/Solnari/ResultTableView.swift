import AppKit
import SwiftUI

@MainActor
struct ResultTableView: NSViewRepresentable {
  let rows: [QueryRow]
  @Binding var columnWidths: [String: CGFloat]

  private let columnDefinitions:
    [(id: String, title: String, width: CGFloat, minimumWidth: CGFloat)] = [
      ("id", "id", 72, 58),
      ("name", "name", 142, 90),
      ("email", "email", 205, 120),
      ("plan", "plan", 105, 72),
      ("orders", "orders", 82, 68),
      ("revenue", "revenue", 104, 80),
      ("created_at", "created_at", 170, 126),
    ]

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let tableView = NSTableView()
    tableView.delegate = context.coordinator
    tableView.dataSource = context.coordinator
    tableView.rowHeight = 29
    let headerView = WideResizeTableHeaderView()
    headerView.additionalHitWidth = 3
    tableView.headerView = headerView
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.allowsMultipleSelection = true
    tableView.allowsColumnResizing = true
    tableView.columnAutoresizingStyle = .noColumnAutoresizing
    tableView.gridStyleMask = [.solidVerticalGridLineMask]
    tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.18)
    tableView.style = .plain

    for definition in columnDefinitions {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.id))
      column.title = definition.title
      column.width = columnWidths[definition.id] ?? definition.width
      column.minWidth = definition.minimumWidth
      column.resizingMask = .userResizingMask
      tableView.addTableColumn(column)
    }

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor

    context.coordinator.tableView = tableView
    headerView.onColumnResize = { [weak coordinator = context.coordinator] in
      coordinator?.captureColumnWidths()
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let tableView = context.coordinator.tableView else { return }

    for column in tableView.tableColumns {
      if let desiredWidth = columnWidths[column.identifier.rawValue],
        abs(column.width - desiredWidth) > 0.5
      {
        column.width = desiredWidth
      }
    }
    tableView.reloadData()
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var parent: ResultTableView
    weak var tableView: NSTableView?

    init(parent: ResultTableView) {
      self.parent = parent
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
      parent.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard let tableColumn, parent.rows.indices.contains(row) else { return nil }
      let reuseIdentifier = NSUserInterfaceItemIdentifier(
        "result-cell-\(tableColumn.identifier.rawValue)")
      let cell =
        tableView.makeView(withIdentifier: reuseIdentifier, owner: nil) as? NSTableCellView
        ?? makeCell(identifier: reuseIdentifier)
      let textField = cell.textField
      textField?.stringValue = value(for: tableColumn.identifier.rawValue, row: parent.rows[row])
      textField?.textColor =
        tableColumn.identifier.rawValue == "id" ? .secondaryLabelColor : .labelColor
      textField?.font =
        tableColumn.identifier.rawValue == "id"
        ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        : NSFont.systemFont(ofSize: 11)
      return cell
    }

    func tableViewColumnDidResize(_ notification: Notification) {
      captureColumnWidths()
    }

    func captureColumnWidths() {
      guard let tableView else { return }
      var widths = parent.columnWidths
      for column in tableView.tableColumns {
        widths[column.identifier.rawValue] = column.width
      }
      parent.columnWidths = widths
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
      let cell = NSTableCellView()
      cell.identifier = identifier

      let textField = NSTextField(labelWithString: "")
      textField.lineBreakMode = .byTruncatingTail
      textField.maximumNumberOfLines = 1
      textField.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(textField)
      cell.textField = textField

      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    }

    private func value(for column: String, row: QueryRow) -> String {
      switch column {
      case "id": String(row.id)
      case "name": row.name
      case "email": row.email
      case "plan": row.plan
      case "orders": String(row.orders)
      case "revenue": row.revenue
      case "created_at": row.createdAt
      default: ""
      }
    }
  }
}

@MainActor
private final class WideResizeTableHeaderView: NSTableHeaderView {
  var additionalHitWidth: CGFloat = 3
  var onColumnResize: (() -> Void)?

  private weak var resizingColumn: NSTableColumn?
  private var dragStartX: CGFloat = 0
  private var dragStartWidth: CGFloat = 0
  private var hoveredDividerX: CGFloat?
  private var hoverTrackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let hoveredDividerX else { return }
    NSColor.controlAccentColor.setFill()
    NSRect(x: hoveredDividerX - 1.5, y: bounds.minY, width: 3, height: bounds.height).fill()
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard let tableView,
      bounds.minX.isFinite,
      bounds.minY.isFinite,
      bounds.width.isFinite,
      bounds.height.isFinite,
      bounds.width > 0,
      bounds.height > 0
    else { return }

    for index in tableView.tableColumns.indices {
      let dividerX = tableView.rect(ofColumn: index).maxX
      guard dividerX.isFinite else { continue }
      let cursorRect = NSRect(
        x: dividerX - additionalHitWidth,
        y: bounds.minY,
        width: additionalHitWidth * 2 + 1,
        height: bounds.height
      )
      let clippedRect = cursorRect.intersection(bounds)
      guard clippedRect.minX.isFinite,
        clippedRect.minY.isFinite,
        clippedRect.width.isFinite,
        clippedRect.height.isFinite,
        !clippedRect.isEmpty
      else { continue }
      addCursorRect(clippedRect, cursor: .resizeLeftRight)
    }
  }

  override func mouseDown(with event: NSEvent) {
    let location = convert(event.locationInWindow, from: nil)
    guard let divider = dividerNear(x: location.x) else {
      super.mouseDown(with: event)
      return
    }

    resizingColumn = divider.column
    hoveredDividerX = divider.x
    dragStartX = event.locationInWindow.x
    dragStartWidth = divider.column.width
    NSCursor.resizeLeftRight.set()
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let resizingColumn else {
      super.mouseDragged(with: event)
      return
    }

    let delta = event.locationInWindow.x - dragStartX
    resizingColumn.width = min(
      resizingColumn.maxWidth,
      max(resizingColumn.minWidth, dragStartWidth + delta)
    )
    tableView?.tile()
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard resizingColumn != nil else {
      super.mouseUp(with: event)
      return
    }

    resizingColumn = nil
    onColumnResize?()
    window?.invalidateCursorRects(for: self)
    updateHoveredDivider(for: event)
  }

  override func mouseMoved(with event: NSEvent) {
    updateHoveredDivider(for: event)
    super.mouseMoved(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    guard resizingColumn == nil else { return }
    hoveredDividerX = nil
    needsDisplay = true
    super.mouseExited(with: event)
  }

  private func updateHoveredDivider(for event: NSEvent) {
    guard resizingColumn == nil else { return }
    let location = convert(event.locationInWindow, from: nil)
    let newDividerX = dividerNear(x: location.x)?.x
    guard newDividerX != hoveredDividerX else { return }
    hoveredDividerX = newDividerX
    needsDisplay = true
  }

  private func dividerNear(x: CGFloat) -> (column: NSTableColumn, x: CGFloat)? {
    guard let tableView else { return nil }
    for index in tableView.tableColumns.indices {
      let dividerX = tableView.rect(ofColumn: index).maxX
      if abs(x - dividerX) <= additionalHitWidth {
        return (tableView.tableColumns[index], dividerX)
      }
    }
    return nil
  }
}
