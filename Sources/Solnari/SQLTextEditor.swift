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
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let editor = scroll.documentView as? NSTextView else { return }
    let coordinator = context.coordinator
    coordinator.parent = self
    if editor.string != text {
      editor.string = text
      editor.undoManager?.removeAllActions()
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
