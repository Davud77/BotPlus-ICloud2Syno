import Foundation

/// Compile-time isolation for publishing screenshots; unavailable as a runtime switch in releases.
enum BuildEnvironment {
  static var isScreenshotPreview: Bool {
    #if SCREENSHOT_PREVIEW
      return true
    #else
      return false
    #endif
  }
}

#if SCREENSHOT_PREVIEW
  @MainActor
  enum ScreenshotPreview {
    static func prepare() {
      let state = SyncState.shared
      state.connectionStatus = .connected(
        serverName: "Демонстрационный NAS", dsmVersion: "Synology Photos")
      state.totalSelectedCount = 1250
      state.updateNASScan(files: 1240, folders: 24)
      state.setReconciliationSummary(total: 1250, alreadyPresent: 1240, toUpload: 10)
      state.syncedCount = 10
      state.currentStage = .completed
      state.totalAlbumsCount = 12
      state.syncedAlbumsCount = 12
      AppLogger.shared.info("Демонстрационный интерфейс. Личные данные не используются.")
    }
  }
#endif
