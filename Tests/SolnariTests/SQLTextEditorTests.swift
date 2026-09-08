import AppKit
import Testing

@testable import Solnari

@MainActor
struct SQLTextEditorTests {
  @Test("SQL 정렬은 선택을 복원하고 한 번의 실행 취소로 돌아간다")
  func formattingIsOneUndoOperation() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    let editor = NSTextView(frame: window.contentView!.bounds)
    editor.isRichText = false
    editor.allowsUndo = true
    window.contentView = editor
    window.makeFirstResponder(editor)
    let original = "SELECT '🍀' AS name FROM items"
    let formatted = "SELECT\n  '🍀' AS name\nFROM\n  items"
    editor.string = original
    let range = (formatted as NSString).range(of: "items")
    SQLTextEditor.Coordinator.apply(formatted, to: editor, selections: [range])
    #expect(editor.string == formatted)
    #expect(editor.selectedRange() == range)
    let undo = try #require(editor.undoManager)
    #expect(undo.canUndo)
    undo.undo()
    #expect(editor.string == original)
    undo.redo()
    #expect(editor.string == formatted)
  }
}
