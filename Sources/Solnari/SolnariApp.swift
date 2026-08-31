import AppKit
import SwiftUI

@MainActor
private final class SolnariAppDelegate: NSObject, NSApplicationDelegate {
  private let environment = AppEnvironment.shared
  private let singleInstance = SingleInstanceCoordinator()
  private var isPrimaryInstance = false
  private var isTerminating = false

  func applicationWillFinishLaunching(_ notification: Notification) {
    do {
      isPrimaryInstance = try singleInstance.acquire()
    } catch {
      NSAlert(error: error).runModal()
      NSApp.terminate(nil)
      return
    }

    guard isPrimaryInstance else {
      singleInstance.requestPrimaryActivation()
      activateExistingApplication()
      NSApp.terminate(nil)
      return
    }

    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(activateFromSecondaryInstance),
      name: SingleInstanceCoordinator.activationNotification,
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(suspendConnections),
      name: Notification.Name("com.apple.screenIsLocked"),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(resumeConnectionOperations),
      name: Notification.Name("com.apple.screenIsUnlocked"),
      object: nil,
      suspensionBehavior: .deliverImmediately
    )
    let workspaceNotifications = NSWorkspace.shared.notificationCenter
    workspaceNotifications.addObserver(
      self,
      selector: #selector(suspendConnections),
      name: NSWorkspace.willSleepNotification,
      object: nil
    )
    workspaceNotifications.addObserver(
      self,
      selector: #selector(suspendConnections),
      name: NSWorkspace.screensDidSleepNotification,
      object: nil
    )
    workspaceNotifications.addObserver(
      self,
      selector: #selector(suspendConnections),
      name: NSWorkspace.sessionDidResignActiveNotification,
      object: nil
    )
    workspaceNotifications.addObserver(
      self,
      selector: #selector(resumeConnectionOperations),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    workspaceNotifications.addObserver(
      self,
      selector: #selector(resumeConnectionOperations),
      name: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil
    )
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard isPrimaryInstance else { return }
    NSApp.setActivationPolicy(.regular)
    DispatchQueue.main.async { self.showMainWindow() }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    showMainWindow()
    return false
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard isPrimaryInstance else { return .terminateNow }
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    Task {
      await environment.workspace.suspendConnections()
      singleInstance.release()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  @objc private func activateFromSecondaryInstance(_ notification: Notification) {
    showMainWindow()
  }

  @objc private func suspendConnections(_ notification: Notification) {
    Task { await environment.workspace.suspendConnections() }
  }

  @objc private func resumeConnectionOperations(_ notification: Notification) {
    environment.workspace.resumeConnectionOperations()
  }

  private func showMainWindow() {
    NSApp.activate(ignoringOtherApps: true)
    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func activateExistingApplication() {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
    let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
      .first(where: { $0.processIdentifier != currentProcessIdentifier })?
      .activate(options: [.activateAllWindows])
  }
}

@main
struct SolnariApp: App {
  @NSApplicationDelegateAdaptor(SolnariAppDelegate.self) private var appDelegate
  @StateObject private var workspace = AppEnvironment.shared.workspace
  @StateObject private var settings = AppEnvironment.shared.settings

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(workspace)
        .environmentObject(settings)
        .environment(\.locale, settings.locale)
        .frame(minWidth: 1_180, minHeight: 720)
    }
    .defaultSize(width: 1_520, height: 940)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button(settings.text("New Connection")) {
          workspace.showNewConnection = true
        }
        .keyboardShortcut("n", modifiers: .command)
      }

      CommandMenu(settings.text("Query")) {
        Button(settings.text("Run Query")) {
          Task { await workspace.runCurrentQuery() }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(workspace.isRunning || workspace.selectedConnectionID == nil)

        Button(settings.text("Format SQL")) {
          workspace.formatCurrentSQL()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
      }
    }

    Settings {
      SettingsView()
        .environmentObject(settings)
        .environment(\.locale, settings.locale)
    }
  }
}
