import AppKit
import Combine
import Foundation
import Sparkle

struct AppVersion: Equatable {
  let version: String
  let build: String
  init(info: [String: Any]) {
    version = info["CFBundleShortVersionString"] as? String ?? "—"
    build = info["CFBundleVersion"] as? String ?? "—"
  }
  static var current: AppVersion { AppVersion(info: Bundle.main.infoDictionary ?? [:]) }
  var display: String { "Версия \(version) (\(build))" }
}

/// Retains a one-shot install request until the sync owner has fully cleaned up its task.
@MainActor
final class UpdateInstallationGate {
  private var pending: (() -> Void)?
  func postpone(isSyncing: Bool, install: @escaping () -> Void) -> Bool {
    guard isSyncing else {
      pending = nil
      return false
    }
    pending = install
    return true
  }
  func syncStateChanged(isSyncing: Bool) {
    guard !isSyncing, let install = pending else { return }
    pending = nil
    install()
  }
  func cancel() { pending = nil }
}

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
  static let shared = UpdateManager()
  @Published private(set) var canCheck = false
  @Published private(set) var isInstallationPending = false
  @Published private(set) var status =
    "Обновления загружаются из GitHub Releases и проверяются по подписи."
  @Published private(set) var lastChecked: Date?
  private var controller: SPUStandardUpdaterController!
  private var started = false
  private let installationGate = UpdateInstallationGate()
  private var syncObservation: AnyCancellable?

  private override init() {
    super.init()
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    controller.updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
    syncObservation = SyncState.shared.$isSyncing.sink { [weak self] syncing in
      // Published fires before the value is committed. Defer until the state has settled.
      Task { @MainActor in
        self?.installationGate.syncStateChanged(isSyncing: syncing || SyncState.shared.isSyncing)
      }
    }
  }

  func start() {
    guard !started else { return }
    do {
      try controller.updater.start()
      started = true
    } catch { status = error.localizedDescription }
  }

  func checkForUpdates() {
    guard !SyncState.shared.isSyncing, !isInstallationPending else { return }
    start()
    guard canCheck else { return }
    status = "Проверка обновлений…"
    controller.checkForUpdates(nil)
  }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard !SyncState.shared.isSyncing else {
      throw NSError(
        domain: "SynologyPhotoSync.Update", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Проверка обновлений доступна после завершения или остановки синхронизации."
        ])
    }
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    status =
      "Доступна версия \(item.displayVersionString). Дальнейшие действия — в окне обновления."
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
    status = "Установлена последняя доступная версия."
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    isInstallationPending = true
    PhotoLibraryMonitor.shared.suspendAutomaticSyncForUpdate()
  }

  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    isInstallationPending = true
    PhotoLibraryMonitor.shared.suspendAutomaticSyncForUpdate()
    let postponed = installationGate.postpone(
      isSyncing: SyncState.shared.isSyncing, install: installHandler)
    if postponed {
      status = "Установка ожидает завершения синхронизации. На паузе ожидание сохраняется."
    }
    return postponed
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    installationGate.cancel()
    isInstallationPending = false
    status = error.localizedDescription
  }
}
