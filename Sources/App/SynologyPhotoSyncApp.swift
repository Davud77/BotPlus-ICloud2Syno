import SwiftUI

@main
struct SynologyPhotoSyncApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var syncState = SyncState.shared

  var body: some Scene {
    MenuBarExtra {
      MenuBarPopupView()
    } label: {
      HStack(spacing: 4) {
        Image(systemName: menuBarIcon)
        if syncState.isSyncing && syncState.totalToSyncCount > 0 {
          Text("\(syncState.syncedCount)/\(syncState.totalToSyncCount)")
            .font(.system(size: 10, weight: .bold))
        }
      }
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
    }
  }

  private var menuBarIcon: String {
    if syncState.isPaused {
      return "pause.circle.fill"
    } else if syncState.isSyncing {
      return "arrow.triangle.2.circlepath.circle.fill"
    } else if case .failed = syncState.connectionStatus {
      return "exclamationmark.circle.fill"
    } else {
      return "photo.stack.fill"
    }
  }
}
