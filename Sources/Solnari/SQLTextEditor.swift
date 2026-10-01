import AppKit
import SwiftUI

struct SQLFormatRequest: Encodable, Sendable {
  let sql: String
  let engine: String
  let offsets: [Int]
}

struct SQLFormatResponse: Decodable, Sendable {
  let sql: String
  let offsets: [Int]
}

struct SQLTextEditor: NSViewRepresentable {
  @Binding var text: String
  let engine: DatabaseEngine
  let formatRequestID: UUID
  let onError: (String) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    let editor = scroll.documentView as! NSTextView
    editor.isRichText = false
    editor.isAutomaticQuoteSubstitutionEnabled = false
    editor.isAutomaticDashSubstitutionEnabled = false
    editor.isAutomaticTextReplacementEnabled = false
    editor.isAutomaticSpellingCorrectionEnabled = false
    editor.isContinuousSpellCheckingEnabled = false
    editor.allowsUndo = true
    editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    editor.textContainerInset = NSSize(width: 9, height: 11)
    editor.string = text
    editor.delegate = context.coordinator
    editor.setAccessibilityLabel("SQL")
    editor.usesRuler = false
    scroll.hasHorizontalRuler = false
    scroll.hasVerticalRuler = true
    scroll.verticalRulerView = SQLLineNumberRuler(scrollView: scroll, editor: editor)
    scroll.rulersVisible = true
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let editor = scroll.documentView as? NSTextView else { return }
    let coordinator = context.coordinator
    coordinator.parent = self
    if editor.string != text {
      editor.string = text
      editor.undoManager?.removeAllActions()
      (scroll.verticalRulerView as? SQLLineNumberRuler)?.updateLineStarts()
    }
    if coordinator.lastRequest != formatRequestID {
      coordinator.lastRequest = formatRequestID
      coordinator.format(editor)
    }
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.task?.cancel()
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: SQLTextEditor
    var lastRequest: UUID
    var task: Task<Void, Never>?

    init(_ parent: SQLTextEditor) {
      self.parent = parent
      lastRequest = parent.formatRequestID
    }

    func textDidChange(_ notification: Notification) {
      guard let editor = notification.object as? NSTextView else { return }
      (editor.enclosingScrollView?.verticalRulerView as? SQLLineNumberRuler)?.updateLineStarts()
      parent.text = editor.string
    }

    func format(_ editor: NSTextView) {
      task?.cancel()
      let original = editor.string
      let selections = editor.selectedRanges.map(\.rangeValue)
      let dialect = parent.engine
      let requestID = lastRequest
      task = Task { [weak self, weak editor] in
        do {
          let response: SQLFormatResponse = try await NodeBackendClient.shared.call(
            method: "sql.format",
            params: SQLFormatRequest(
              sql: original, engine: dialect.rawValue,
              offsets: selections.flatMap { [$0.location, NSMaxRange($0)] })
          )
          try Task.checkCancellation()
          guard let self, let editor, self.lastRequest == requestID,
            self.parent.engine == dialect, editor.string == original,
            editor.selectedRanges.map(\.rangeValue) == selections
          else { return }
          guard response.offsets.count == selections.count * 2,
            response.offsets.allSatisfy({ $0 >= 0 && $0 <= (response.sql as NSString).length })
          else {
            throw NodeBackendError.invalidResponse
          }
          let ranges = selections.indices.map { index in
            NSRange(
              location: response.offsets[index * 2],
              length: max(0, response.offsets[index * 2 + 1] - response.offsets[index * 2]))
          }
          let origin = editor.enclosingScrollView?.contentView.bounds.origin ?? .zero
          Self.apply(response.sql, to: editor, selections: ranges)
          if let scroll = editor.enclosingScrollView {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
          }
        } catch {
          guard !Task.isCancelled else { return }
          self?.parent.onError(
            "SQL could not be formatted safely. Check incomplete or unsupported syntax; the original SQL was preserved."
          )
        }
      }
    }

    static func apply(_ sql: String, to editor: NSTextView, selections: [NSRange]) {
      guard editor.string != sql else { return }
      editor.breakUndoCoalescing()
      editor.undoManager?.beginUndoGrouping()
      editor.insertText(
        sql, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
      editor.undoManager?.endUndoGrouping()
      editor.breakUndoCoalescing()
      editor.selectedRanges = selections.map {
        let location = min($0.location, (sql as NSString).length)
        return NSValue(
          range: NSRange(
            location: location, length: min($0.length, (sql as NSString).length - location)))
      }
    }
  }
}

/// A scroll-view ruler keeps line numbers inside the editor viewport and follows text layout.
@MainActor
final class SQLLineNumberRuler: NSRulerView {
  struct LineLabel {
    let number: Int
    let rect: NSRect
  }

  private weak var textView: NSTextView?
  private var lineStarts = [0]
  private let numberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

  init(scrollView: NSScrollView, editor: NSTextView) {
    textView = editor
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    clientView = editor
    clipsToBounds = true
    reservedThicknessForMarkers = 0
    reservedThicknessForAccessoryView = 0
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(scrollBoundsChanged), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)
    updateLineStarts()
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit { NotificationCenter.default.removeObserver(self) }

  override var isFlipped: Bool { true }

  @objc private func scrollBoundsChanged(_ notification: Notification) {
    needsDisplay = true
  }

  func updateLineStarts() {
    guard let editor = textView else { return }
    let text = editor.string as NSString
    lineStarts = [0]
    var index = 0
    while index < text.length {
      index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
      if index < text.length { lineStarts.append(index) }
    }
    if text.length > 0,
      text.lineRange(for: NSRange(location: text.length, length: 0)).location == text.length
    {
      lineStarts.append(text.length)
    }
    let label = String(lineStarts.count) as NSString
    ruleThickness = max(43, label.size(withAttributes: [.font: numberFont]).width + 18)
    needsDisplay = true
  }

  var visibleLineLabels: [LineLabel] {
    guard let editor = textView,
      let layout = editor.layoutManager, let container = editor.textContainer
    else { return [] }
    let origin = editor.textContainerOrigin
    let visible = editor.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
    layout.ensureLayout(forBoundingRect: visible, in: container)
    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
    // Include the logical line containing the first visible glyph, then visit visible starts only.
    var lower = 0
    var upper = lineStarts.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if lineStarts[middle] <= characters.location {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    var labels: [LineLabel] = []
    for index in max(0, lower - 1)..<lineStarts.count {
      let start = lineStarts[index]
      if start > NSMaxRange(characters) { break }
      let fragment: NSRect
      if start == (editor.string as NSString).length {
        fragment = layout.extraLineFragmentRect
      } else {
        fragment = layout.lineFragmentRect(
          forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
      }
      var rect = convert(fragment.offsetBy(dx: origin.x, dy: origin.y), from: editor)
      rect.origin.x = bounds.minX
      rect.size.width = bounds.width
      if rect.intersects(bounds) { labels.append(LineLabel(number: index + 1, rect: rect)) }
    }
    return labels
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.textBackgroundColor.setFill()
    dirtyRect.intersection(bounds).fill()
    NSColor.labelColor.withAlphaComponent(0.045).setFill()
    dirtyRect.intersection(bounds).fill()
    NSColor.separatorColor.setFill()
    NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
    let attributes: [NSAttributedString.Key: Any] = [
      .font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    for label in visibleLineLabels {
      let text = String(label.number) as NSString
      let size = text.size(withAttributes: attributes)
      text.draw(
        at: NSPoint(x: bounds.maxX - size.width - 9, y: label.rect.midY - size.height / 2),
        withAttributes: attributes)
    }
  }
}
