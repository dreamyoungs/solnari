import Foundation
import Testing

@testable import Solnari

struct SchemaWorkspaceTabTests {
  private func object(_ name: String) -> SchemaObject {
    SchemaObject(schema: "main", name: name, kind: .table, columnCount: 2)
  }

  @Test("미리보기는 같은 탭을 재사용하고 쿼리를 보존한다")
  func previewReplacement() {
    var workspace = ConnectionWorkspace()
    let original = workspace.editorTabs[0]
    workspace.openSchema(object("first"), pinned: false)
    let previewID = workspace.selectedTabID
    workspace.openSchema(object("second"), pinned: false)
    #expect(workspace.editorTabs.count == 2)
    #expect(workspace.selectedTabID == previewID)
    #expect(workspace.editorTabs[1].schemaObject == object("second"))
    #expect(workspace.editorTabs[0] == original)
  }

  @Test("더블 클릭과 명시적 고정은 중복 없이 승격하고 여러 고정 탭을 보존한다")
  func pinAndClose() {
    var workspace = ConnectionWorkspace()
    workspace.openSchema(object("first"), pinned: false)
    let firstID = workspace.selectedTabID!
    workspace.openSchema(object("first"), pinned: true)
    #expect(workspace.editorTabs.count == 2)
    #expect(!workspace.editorTabs[1].isPreview)
    workspace.openSchema(object("second"), pinned: true)
    workspace.openSchema(object("third"), pinned: false)
    workspace.pinTab(workspace.selectedTabID!)
    workspace.openSchema(object("fourth"), pinned: false)
    #expect(workspace.editorTabs.filter(\.isPreview).count == 1)
    #expect(workspace.editorTabs.count == 5)
    workspace.openSchema(object("first"), pinned: false)
    #expect(workspace.selectedTabID == firstID)
    #expect(workspace.editorTabs.count == 5)
    workspace.closeTab(firstID)
    #expect(!workspace.editorTabs.contains { $0.id == firstID })
    #expect(workspace.editorTabs.contains { $0.id == workspace.selectedTabID })
  }

  @Test("마지막 탭을 닫으면 빈 쿼리를 만들고 재시작 시 상세 탭을 복원하지 않는다")
  func lastTabAndRestoration() {
    var workspace = ConnectionWorkspace()
    let initialID = workspace.selectedTabID!
    workspace.openSchema(object("first"), pinned: true)
    workspace.closeTab(initialID)
    workspace.closeTab(workspace.selectedTabID!)
    #expect(workspace.editorTabs.count == 1)
    #expect(workspace.editorTabs[0].kind == .query)
    #expect(ConnectionWorkspace().editorTabs.allSatisfy { $0.kind == .query })
  }
}
