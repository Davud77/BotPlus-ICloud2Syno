import Combine
import Foundation
import Photos

/// Монитор системной медиатеки Apple Photos с поддержкой отслеживания изменений в реальном времени
@MainActor
public final class PhotoLibraryMonitor: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
  public static let shared = PhotoLibraryMonitor()

  @Published public var authorizationStatus: PHAuthorizationStatus = .notDetermined
  @Published public var availableAlbums: [AlbumInfo] = []
  @Published public var isScanning: Bool = false

  private let engineActor = SyncEngineActor()
  private var albumLoadTask: Task<Void, Never>?
  private var automaticSyncSuspended = false
  private var pendingChanges = false
  private var observerRegistered = false
  private var changeTask: Task<Void, Never>?
  private var syncTask: Task<Void, Never>?

  private override init() {
    super.init()
    checkAuthorization()
  }

  // MARK: - Авторизация PhotoKit

  public func checkAuthorization() {
    self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if self.authorizationStatus == .authorized || self.authorizationStatus == .limited {
      registerObserver()
      loadAvailableAlbums()
    }
  }

  public func requestAuthorization() async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    self.authorizationStatus = status
    if status == .authorized || status == .limited {
      registerObserver()
      loadAvailableAlbums()
      return true
    }
    return false
  }

  private func registerObserver() {
    guard !observerRegistered else { return }
    observerRegistered = true
    PHPhotoLibrary.shared().register(self)
  }

  deinit {
    PHPhotoLibrary.shared().unregisterChangeObserver(self)
  }

  // MARK: - PHPhotoLibraryChangeObserver

  nonisolated public func photoLibraryDidChange(_ changeInstance: PHChange) {
    Task { @MainActor in
      self.changeTask?.cancel()
      self.changeTask = Task { @MainActor in
        do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
        self.loadAvailableAlbums()

        // Если не на паузе и есть подключение к Synology, запускаем фоновую докачку новых снимков
        let state = SyncState.shared
        if state.isSyncing {
          self.pendingChanges = true
        } else if !self.automaticSyncSuspended && !state.isPaused
          && !SyncConfig.shared.username.isEmpty
        {
          self.startSync()
        }
      }
    }
  }

  // MARK: - Загрузка списка альбомов из Apple Photos

  public func loadAvailableAlbums() {
    albumLoadTask?.cancel()
    albumLoadTask = Task {
      let albums = await Task.detached(priority: .utility) { Self.fetchAvailableAlbums() }.value
      guard !Task.isCancelled else { return }
      self.availableAlbums = albums
    }
  }

  nonisolated private static func fetchAvailableAlbums() -> [AlbumInfo] {
    var albums: [AlbumInfo] = []

    // 1. Личные пользовательские альбомы
    let userAlbums = PHAssetCollection.fetchAssetCollections(
      with: .album,
      subtype: .albumRegular,
      options: nil
    )
    userAlbums.enumerateObjects { collection, _, _ in
      let fetchOptions = PHFetchOptions()
      let count = PHAsset.fetchAssets(in: collection, options: fetchOptions).count
      let info = AlbumInfo(
        id: collection.localIdentifier,
        title: collection.localizedTitle ?? "Альбом",
        assetCount: count,
        isCloudShared: false
      )
      albums.append(info)
    }

    // 2. Общие альбомы iCloud (Shared Albums)
    let sharedAlbums = PHAssetCollection.fetchAssetCollections(
      with: .album,
      subtype: .albumCloudShared,
      options: nil
    )
    sharedAlbums.enumerateObjects { collection, _, _ in
      let fetchOptions = PHFetchOptions()
      let count = PHAsset.fetchAssets(in: collection, options: fetchOptions).count
      let info = AlbumInfo(
        id: collection.localIdentifier,
        title: collection.localizedTitle ?? "Общий альбом",
        assetCount: count,
        isCloudShared: true
      )
      albums.append(info)
    }

    return albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  // MARK: - Сканирование и подготовка очереди

  nonisolated public func scanAssetsToSync() -> (
    assets: [PHAsset], collections: [PHAssetCollection]
  ) {
    let config = SyncConfig.shared
    // Настройка опций выборки ассетов
    let fetchOptions = PHFetchOptions()
    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

    fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared]
    if !config.syncAllHistory {
      fetchOptions.predicate = NSPredicate(
        format: "creationDate >= %@", config.syncStartDate as NSDate)
    }
    let scope = config.libraryScope
    let allAssets = PHAsset.fetchAssets(with: fetchOptions)
    var unsyncedAssets: [PHAsset] = []

    allAssets.enumerateObjects { asset, _, _ in
      // Фильтрация по дате съемки
      if !config.syncAllHistory, let creationDate = asset.creationDate,
        creationDate < config.syncStartDate
      {
        return
      }

      // Фильтрация по LibraryScope (Личная / Общая / Обе)
      let isCloudShared = asset.sourceType.contains(.typeCloudShared)
      switch scope {
      case .personalOnly:
        if isCloudShared { return }
      case .sharedOnly:
        if !isCloudShared { return }
      case .both:
        break
      }

      // Проверяем, загружен ли уже в Synology
      unsyncedAssets.append(asset)
    }

    // Выборка коллекций для синхронизации альбомов
    var targetCollections: [PHAssetCollection] = []
    let selectedIds = config.selectedAlbumIdentifiers

    func checkAndAddCollection(_ collection: PHAssetCollection, isShared: Bool) {
      if scope == .personalOnly && isShared { return }
      if scope == .sharedOnly && !isShared { return }
      if isShared && !config.syncSharedAlbums { return }
      if !isShared && !config.syncPersonalAlbums { return }

      if selectedIds.isEmpty || selectedIds.contains(collection.localIdentifier) {
        targetCollections.append(collection)
      }
    }

    let userAlbums = PHAssetCollection.fetchAssetCollections(
      with: .album, subtype: .albumRegular, options: nil)
    userAlbums.enumerateObjects { collection, _, _ in
      checkAndAddCollection(collection, isShared: false)
    }

    let sharedAlbums = PHAssetCollection.fetchAssetCollections(
      with: .album, subtype: .albumCloudShared, options: nil)
    sharedAlbums.enumerateObjects { collection, _, _ in
      checkAndAddCollection(collection, isShared: true)
    }

    return (assets: unsyncedAssets, collections: targetCollections)
  }

  // MARK: - Управление процессом синхронизации

  public func startSync() {
    guard authorizationStatus == .authorized || authorizationStatus == .limited else {
      Task {
        let granted = await requestAuthorization()
        if granted { self.startSync() }
      }
      return
    }

    let config = SyncConfig.shared
    guard !config.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let password = KeychainHelper.shared.getPassword(), !password.isEmpty
    else {
      // Сервер или учетные данные еще не настроены
      return
    }

    let state = SyncState.shared
    guard !state.isSyncing else {
      if state.isPaused {
        resumeSync()
      }
      return
    }

    let database = SyncDatabase.shared
    let apiClient = SynologyAPIClient.shared

    guard syncTask == nil else { return }
    do {
      guard let url = apiClient.buildURL(baseURL: config.serverURL, endpoint: "") else {
        throw SynologyError.invalidURL
      }
      try database.selectDestination(
        server: url.absoluteString, username: config.username, target: config.targetSpace,
        livePhotos: config.saveLivePhotos, editedCopies: config.saveEditedCopies)
    } catch {
      state.currentStage = .error
      state.connectionStatus = .failed(message: error.localizedDescription)
      AppLogger.error("Невозможно начать синхронизацию", details: error.localizedDescription)
      return
    }
    self.automaticSyncSuspended = false
    self.pendingChanges = false
    state.startNewSession(totalFiles: 0, totalAlbums: 0)
    self.isScanning = true
    syncTask = Task {
      defer {
        self.isScanning = false
        self.syncTask = nil
        let cancelled = Task.isCancelled
        state.finishSession(cancelled: cancelled)
        if state.currentStage == .error || state.currentStage == .attention {
          self.automaticSyncSuspended = true
        }
        if self.pendingChanges && !cancelled && !self.automaticSyncSuspended {
          self.pendingChanges = false
          Task { @MainActor in self.startSync() }
        }
      }
      do {
        await engineActor.reset()
        state.connectionStatus = .connecting
        if config.targetSpace == .personal
          || (config.targetSpace == .separate && config.libraryScope != .sharedOnly)
        {
          try await engineActor.validateAccess(target: .personal, config: config, client: apiClient)
        }
        if config.targetSpace == .shared
          || (config.targetSpace == .separate && config.libraryScope != .personalOnly)
        {
          try await engineActor.validateAccess(target: .shared, config: config, client: apiClient)
        }
        state.connectionStatus = .connected(
          serverName: URL(string: config.serverURL)?.host ?? "Synology",
          dsmVersion: "Synology Photos")
        try await engineActor.waitUntilReady()
        let scan = Task.detached(priority: .utility) { self.scanAssetsToSync() }
        let (selectedAssets, collectionsToSync) = await scan.value
        guard !Task.isCancelled else { return }
        self.isScanning = false
        state.totalToSyncCount = selectedAssets.count
        state.totalSelectedCount = selectedAssets.count
        state.totalAlbumsCount = collectionsToSync.count
        let assetsToSync = try await engineActor.prepareAssets(
          selectedAssets, config: config, database: database, apiClient: apiClient)
        AppLogger.info(
          "К выгрузке \(assetsToSync.count) файлов, \(collectionsToSync.count) альбомов")
        try await engineActor.waitUntilReady()
        try await engineActor.syncAssets(
          assetsToSync, config: config, database: database, apiClient: apiClient)
        try await engineActor.waitUntilReady()
        if !collectionsToSync.isEmpty {
          try await engineActor.syncAlbums(
            collections: collectionsToSync, config: config, database: database, apiClient: apiClient
          )
        }
        try await engineActor.waitUntilReady()
      } catch {
        if !Task.isCancelled {
          self.pendingChanges = false
          self.automaticSyncSuspended = true
          state.noteError()
          state.connectionStatus = .failed(message: error.localizedDescription)
          AppLogger.shared.error("Синхронизация остановлена", details: error.localizedDescription)
        }
      }
    }
  }

  public func pauseSync() {
    guard SyncState.shared.isSyncing, !SyncState.shared.isPaused else { return }
    SyncState.shared.togglePause()
  }

  public func resumeSync() {
    guard SyncState.shared.isSyncing, SyncState.shared.isPaused else { return }
    SyncState.shared.togglePause()
  }

  public func cancelSync() {
    automaticSyncSuspended = true
    pendingChanges = false
    SyncState.shared.requestCancellation()
    syncTask?.cancel()
    // Retain the task until PhotoKit releases the current extraction and cleanup finishes.
    // This prevents two sync loops from writing to the same destination concurrently.

  }

  public func retryFailedItems() {
    guard syncTask == nil else { return }
    startSync()
  }
}
