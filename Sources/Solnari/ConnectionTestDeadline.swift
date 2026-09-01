import Foundation

private actor ConnectionTestRace<Value: Sendable> {
  typealias Outcome = Result<Value, any Error>

  private var outcome: Outcome?
  private var continuation: CheckedContinuation<Outcome, Never>?

  func wait() async -> Outcome {
    if let outcome { return outcome }
    return await withCheckedContinuation { continuation = $0 }
  }

  @discardableResult
  func resolve(_ outcome: Outcome) -> Bool {
    guard self.outcome == nil else { return false }
    self.outcome = outcome
    continuation?.resume(returning: outcome)
    continuation = nil
    return true
  }
}

private actor ConnectionTestCleanup {
  private let action: @Sendable () async -> Void
  private var hasRun = false

  init(action: @escaping @Sendable () async -> Void) {
    self.action = action
  }

  func run() async {
    guard !hasRun else { return }
    hasRun = true
    await action()
  }
}

enum ConnectionTestDeadline {
  static func run<Value: Sendable>(
    timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value,
    cleanup: @escaping @Sendable () async -> Void = {}
  ) async throws -> Value {
    let race = ConnectionTestRace<Value>()
    let cleanupOnce = ConnectionTestCleanup(action: cleanup)
    let operationTask = Task {
      do {
        await race.resolve(.success(try await operation()))
      } catch {
        await race.resolve(.failure(error))
      }
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard await race.resolve(.failure(SolnariDatabaseError.connectionTestTimedOut)) else {
        return
      }
      operationTask.cancel()
      await cleanupOnce.run()
    }

    return try await withTaskCancellationHandler {
      let outcome = await race.wait()
      timeoutTask.cancel()
      return try outcome.get()
    } onCancel: {
      operationTask.cancel()
      timeoutTask.cancel()
      Task {
        await race.resolve(.failure(CancellationError()))
        await cleanupOnce.run()
      }
    }
  }
}
