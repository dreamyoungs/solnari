import Foundation
import Testing

@testable import Solnari

private actor CleanupProbe {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

struct ConnectionTestDeadlineTests {
  @Test("연결 테스트 제한 시간은 호출자에게 즉시 반환하고 정리를 시작한다")
  func timeoutReturnsAndCleansUp() async throws {
    let probe = CleanupProbe()
    let startedAt = ContinuousClock.now

    do {
      let _: String = try await ConnectionTestDeadline.run(
        timeout: .milliseconds(30),
        operation: {
          try await Task.sleep(for: .seconds(5))
          return "late"
        },
        cleanup: { await probe.record() }
      )
      Issue.record("제한 시간 초과 오류가 필요합니다.")
    } catch SolnariDatabaseError.connectionTestTimedOut {
      // Expected.
    } catch {
      Issue.record("예상하지 못한 오류: \(error)")
    }

    #expect(ContinuousClock.now - startedAt < .seconds(1))
    try await waitForCleanup(probe)
    #expect(await probe.count == 1)
  }

  @Test("호출자 취소는 대기 중인 연결 테스트와 정리 루틴에 전달된다")
  func cancellationReturnsAndCleansUp() async throws {
    let probe = CleanupProbe()
    let task = Task {
      try await ConnectionTestDeadline.run(
        timeout: .seconds(5),
        operation: {
          try await Task.sleep(for: .seconds(5))
          return true
        },
        cleanup: { await probe.record() }
      )
    }

    try await Task.sleep(for: .milliseconds(30))
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("취소 오류가 필요합니다.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("예상하지 못한 오류: \(error)")
    }

    try await waitForCleanup(probe)
    #expect(await probe.count == 1)
  }

  private func waitForCleanup(_ probe: CleanupProbe) async throws {
    for _ in 0..<20 {
      if await probe.count > 0 { return }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
