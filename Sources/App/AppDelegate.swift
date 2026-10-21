import Cocoa

/// Делегат приложения для настройки жизненного цикла Menu Bar утилиты
public final class AppDelegate: NSObject, NSApplicationDelegate {
  public func applicationDidFinishLaunching(_ notification: Notification) {
    // Dock and menu bar remain available throughout synchronization.
    NSApp.setActivationPolicy(.regular)

    UpdateManager.shared.start()

    #if SCREENSHOT_PREVIEW
      ScreenshotPreview.prepare()
      SettingsWindowManager.shared.showSettings()
    #else
      // Инициализируем проверку прав доступа к медиатеке в фоне
      Task { @MainActor in
        PhotoLibraryMonitor.shared.checkAuthorization()
      }
    #endif
  }

  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    SettingsWindowManager.shared.showSettings()
    return true
  }

  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Приложение продолжает работать в строке меню даже при закрытии окна настроек
    return false
  }
}
