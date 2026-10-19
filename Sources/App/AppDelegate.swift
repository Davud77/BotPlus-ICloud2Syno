import Cocoa

/// Делегат приложения для настройки жизненного цикла Menu Bar утилиты
public final class AppDelegate: NSObject, NSApplicationDelegate {
  public func applicationDidFinishLaunching(_ notification: Notification) {
    // Убеждаемся, что приложение работает как Menu Bar агент без иконки в Dock
    NSApp.setActivationPolicy(.accessory)

    // Инициализируем проверку прав доступа к медиатеке в фоне
    Task { @MainActor in
      PhotoLibraryMonitor.shared.checkAuthorization()
    }
  }

  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Приложение продолжает работать в строке меню даже при закрытии окна настроек
    return false
  }
}
