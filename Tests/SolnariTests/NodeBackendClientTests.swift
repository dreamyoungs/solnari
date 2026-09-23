import Foundation
import Testing

@testable import Solnari

struct NodeBackendClientTests {
  private struct Empty: Encodable, Sendable {}
  private struct Ping: Decodable, Sendable { let protocolVersion: Int }

  @Test("유휴 Node 클라이언트와 두 번째 클라이언트 및 재시작이 서로 막지 않는다")
  func independentReadersAndRestart() async throws {
    let first = NodeBackendClient()
    let second = NodeBackendClient()
    do {
      let _: Ping = try await first.call(method: "system.ping", params: Empty())
      try await Task.sleep(for: .milliseconds(50))
      let response: Ping = try await ConnectionTestDeadline.run(
        timeout: .seconds(5),
        operation: { try await second.call(method: "system.ping", params: Empty()) },
        cleanup: { await second.stop() })
      #expect(response.protocolVersion == 1)
      for _ in 0..<3 {
        await first.stop()
        let restarted: Ping = try await ConnectionTestDeadline.run(
          timeout: .seconds(5),
          operation: { try await first.call(method: "system.ping", params: Empty()) },
          cleanup: { await first.stop() })
        #expect(restarted.protocolVersion == 1)
      }
    } catch {
      await first.stop()
      await second.stop()
      throw error
    }
    await first.stop()
    await second.stop()
  }
}
