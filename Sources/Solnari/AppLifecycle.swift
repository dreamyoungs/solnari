import AppKit
import Darwin
import Foundation

@MainActor
final class AppEnvironment {
  static let shared = AppEnvironment()

  let workspace: WorkspaceModel
  let settings: AppSettings

  private init() {
    LegacyPreferencesMigrator.migrateIfNeeded()
    workspace = WorkspaceModel()
    settings = AppSettings()
  }
}

enum LegacyPreferencesMigrator {
  private static let migratedKey = "solnari.preferencesMigratedFromExecutable.v1"
  private static let preferenceKeys = [
    "solnari.connectionProfiles.v1",
    "solnari.language",
    "solnari.displayTimeZone",
  ]

  static func migrateIfNeeded(
    current: UserDefaults = .standard,
    legacy: UserDefaults? = UserDefaults(suiteName: "Solnari")
  ) {
    guard !current.bool(forKey: migratedKey) else { return }
    if let legacy {
      for key in preferenceKeys where current.object(forKey: key) == nil {
        if let value = legacy.object(forKey: key) {
          current.set(value, forKey: key)
        }
      }
    }
    current.set(true, forKey: migratedKey)
  }
}

final class SingleInstanceCoordinator {
  static let activationNotification = Notification.Name("com.dreamyoungs.solnari.activate-existing")

  private let lockURL: URL
  private var descriptor: Int32 = -1

  init(lockURL: URL = SingleInstanceCoordinator.defaultLockURL) {
    self.lockURL = lockURL
  }

  deinit {
    release()
  }

  func acquire() throws -> Bool {
    if descriptor >= 0 { return true }

    try FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let openedDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    guard openedDescriptor >= 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockURL.path])
    }
    guard flock(openedDescriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(openedDescriptor)
      return false
    }

    descriptor = openedDescriptor
    _ = ftruncate(descriptor, 0)
    let processIdentifier = "\(getpid())\n"
    processIdentifier.withCString { pointer in
      _ = Darwin.write(descriptor, pointer, strlen(pointer))
    }
    return true
  }

  func release() {
    guard descriptor >= 0 else { return }
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
    descriptor = -1
  }

  func requestPrimaryActivation() {
    DistributedNotificationCenter.default().post(
      name: Self.activationNotification,
      object: nil
    )
  }

  private static var defaultLockURL: URL {
    let applicationSupport =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      applicationSupport
      .appendingPathComponent("Solnari", isDirectory: true)
      .appendingPathComponent("Solnari.lock", isDirectory: false)
  }
}
