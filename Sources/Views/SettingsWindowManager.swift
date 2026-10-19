import Cocoa
import SwiftUI

/// Менеджер отдельного окна Настроек для Menu Bar приложения
@MainActor
public final class SettingsWindowManager: NSObject, NSWindowDelegate {
  public static let shared = SettingsWindowManager()

  private var window: NSWindow?

  private override init() {
    super.init()
  }

  public func showSettings() {
    // Показываем иконку приложения в Dock при открытии Настроек
    NSApp.setActivationPolicy(.regular)

    if let existing = window {
      existing.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }

    let settingsView = SettingsView()
    let hostingController = NSHostingController(rootView: settingsView)

    let newWindow = NSWindow(contentViewController: hostingController)
    newWindow.title = "Настройки SynologyPhotoSync"
    newWindow.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    newWindow.titlebarAppearsTransparent = true
    newWindow.isOpaque = false
    newWindow.backgroundColor = .clear
    newWindow.hasShadow = true
    newWindow.setContentSize(NSSize(width: 590, height: 570))
    newWindow.center()
    newWindow.isReleasedWhenClosed = false
    newWindow.delegate = self

    self.window = newWindow
    newWindow.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  public func windowWillClose(_ notification: Notification) {
    // Скрываем иконку из Dock при закрытии окна настроек (возврат в режим строки меню)
    NSApp.setActivationPolicy(.accessory)
  }
}
