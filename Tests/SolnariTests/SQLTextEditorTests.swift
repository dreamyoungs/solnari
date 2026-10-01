import AppKit
import SwiftUI
import Testing

@testable import Solnari

@MainActor
struct SQLTextEditorTests {
  @Test("긴 SQL을 붙여넣어도 편집기 뷰포트가 툴바와 결과 영역을 침범하지 않는다", arguments: ["\n", "\r\n"])
  func pastingLongSQLKeepsWorkspaceLayout(lineEnding: String) async throws {
    let suiteName = "SQLPasteLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let profile = ConnectionProfile(
      name: "Paste fixture", database: ":memory:", engine: .sqlite, transport: .direct,
      host: "", port: 0, username: "", requiresTLS: false, clientEncoding: "Automatic")
    let store = ConnectionProfileStore(defaults: defaults)
    try store.save([profile])
    let model = WorkspaceModel(profileStore: store)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    let host = NSHostingView(
      rootView: HStack(spacing: 0) {
        WorkspaceView().frame(minWidth: 660)
        AIAssistantView().frame(width: 340)
      }
      .environmentObject(model).environmentObject(AppSettings()))
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let editor = try #require(sqlEditor(in: host))
    let scroll = try #require(editor.enclosingScrollView)
    host.displayIfNeeded()
    let originalFrame = scroll.convert(scroll.bounds, to: host)
    let originalImage = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: originalImage)
    let headerInk = darkHeaderPixels(in: originalImage, viewSize: host.bounds.size)
    window.makeFirstResponder(editor)
    editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
    let sql =
      (1...180).map { "SELECT \($0) AS value; -- 붙여넣기 🍀" }.joined(separator: lineEnding)
      + lineEnding
    let pasteboard = NSPasteboard(name: .init("SolnariSQLPaste-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString(sql, forType: .string)
    #expect(editor.readSelection(from: pasteboard, type: .string))
    editor.didChangeText()
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    #expect(editor.string == sql)
    #expect(model.selectedTab?.sql == sql)
    host.displayIfNeeded()
    let pastedFrame = scroll.convert(scroll.bounds, to: host)
    let pastedImage = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: pastedImage)
    #expect(headerInk > 0)
    #expect(darkHeaderPixels(in: pastedImage, viewSize: host.bounds.size) >= headerInk * 9 / 10)
    #expect(abs(pastedFrame.height - originalFrame.height) < 1)
    #expect(abs(pastedFrame.minY - originalFrame.minY) < 1)
    #expect(abs(pastedFrame.maxY - originalFrame.maxY) < 1)
    #expect(editor.frame.height > scroll.contentView.bounds.height)
    let ruler = try #require(scroll.verticalRulerView as? SQLLineNumberRuler)
    #expect(ruler.visibleLineLabels.first?.number == 1)
    editor.scrollRangeToVisible(NSRange(location: (sql as NSString).length, length: 0))
    #expect((ruler.visibleLineLabels.first?.number ?? 0) > 1)
    #expect(ruler.visibleLineLabels.last?.number == 181)
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(ruler.visibleLineLabels.first?.number == 1)

    if ProcessInfo.processInfo.environment["SOLNARI_RENDER_UI"] != nil {
      let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/feature-previews")
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try #require(pastedImage.representation(using: .png, properties: [:]))
        .write(to: output.appendingPathComponent("editor-long-paste.png"))
    }
  }

  private func darkHeaderPixels(in image: NSBitmapImageRep, viewSize: NSSize) -> Int {
    let scaleX = CGFloat(image.pixelsWide) / viewSize.width
    let scaleY = CGFloat(image.pixelsHigh) / viewSize.height
    var count = 0
    // The connection bar is unchanged by editing. Its labels must remain visible after paste.
    for y in Int(5 * scaleY)..<Int(38 * scaleY) {
      for x in Int(60 * scaleX)..<Int(640 * scaleX) {
        if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          color.alphaComponent > 0.9,
          max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5
        {
          count += 1
        }
      }
    }
    return count
  }

  private func sqlEditor(in view: NSView) -> NSTextView? {
    if let editor = view as? NSTextView, editor.accessibilityLabel() == "SQL" { return editor }
    return view.subviews.lazy.compactMap { sqlEditor(in: $0) }.first
  }

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
