import Foundation
import Testing

@testable import Solnari

struct AppLifecycleTests {
  @Test("한 프로세스만 Solnari 실행 잠금을 소유한다")
  func aSingleProcessOwnsTheApplicationLock() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SolnariLifecycleTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockURL = directory.appendingPathComponent("Solnari.lock")
    let primary = SingleInstanceCoordinator(lockURL: lockURL)
    let secondary = SingleInstanceCoordinator(lockURL: lockURL)

    #expect(try primary.acquire())
    #expect(try !secondary.acquire())

    primary.release()
    #expect(try secondary.acquire())
  }

  @Test("기존 실행 파일의 비밀이 아닌 설정을 앱 번들 환경으로 한 번만 이관한다")
  func legacyPreferencesMigrateOnceWithoutOverwritingCurrentValues() throws {
    let identifier = UUID().uuidString
    let currentSuite = "SolnariTests.current.\(identifier)"
    let legacySuite = "SolnariTests.legacy.\(identifier)"
    let current = try #require(UserDefaults(suiteName: currentSuite))
    let legacy = try #require(UserDefaults(suiteName: legacySuite))
    defer {
      current.removePersistentDomain(forName: currentSuite)
      legacy.removePersistentDomain(forName: legacySuite)
    }
    legacy.set(Data("profiles".utf8), forKey: "solnari.connectionProfiles.v1")
    legacy.set("ko", forKey: "solnari.language")
    current.set("en", forKey: "solnari.language")

    LegacyPreferencesMigrator.migrateIfNeeded(current: current, legacy: legacy)

    #expect(current.data(forKey: "solnari.connectionProfiles.v1") == Data("profiles".utf8))
    #expect(current.string(forKey: "solnari.language") == "en")

    legacy.set("Asia/Seoul", forKey: "solnari.displayTimeZone")
    LegacyPreferencesMigrator.migrateIfNeeded(current: current, legacy: legacy)
    #expect(current.string(forKey: "solnari.displayTimeZone") == nil)
  }
}
