import CryptoKit
import Foundation

/// Персистентная база данных синхронизации (хранение маппинга идентификаторов, истории и лога ошибок)
public final class SyncDatabase: @unchecked Sendable {
  public static let shared = SyncDatabase(
    fileURL: BuildEnvironment.isScreenshotPreview
      ? FileManager.default.temporaryDirectory.appendingPathComponent(
        "SynologyPhotoSync-Preview-\(UUID().uuidString)/state.json") : nil)

  private struct DatabaseState: Codable {
    var resourceMappings: [String: [String: Int]] = [:]
    var syncedAssets: [String: Int] = [:]  // appleLocalIdentifier -> synologyItemId
    var syncedAlbums: [String: Int] = [:]  // appleAlbumLocalIdentifier -> synologyAlbumId
    var history: [SyncHistoryItem] = []  // Последние загруженные элементы
    var failedItems: [SyncErrorItem] = []  // Ошибки загрузки
    init() {}
    private enum CodingKeys: String, CodingKey {
      case syncedAssets, syncedAlbums, history, failedItems, resourceMappings
    }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      syncedAssets = try values.decode([String: Int].self, forKey: .syncedAssets)
      syncedAlbums = try values.decode([String: Int].self, forKey: .syncedAlbums)
      history = try values.decode([SyncHistoryItem].self, forKey: .history)
      failedItems = try values.decode([SyncErrorItem].self, forKey: .failedItems)
      resourceMappings =
        try values.decodeIfPresent([String: [String: Int]].self, forKey: .resourceMappings) ?? [:]
    }

  }

  private var fileURL: URL
  private var loadError: Error?
  private let queue = DispatchQueue(label: "com.synologyphotosync.database.queue", qos: .utility)
  private var state: DatabaseState

  init(fileURL: URL? = nil) {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.fileURL = fileURL ?? appSupport.appendingPathComponent("SynologyPhotoSync/state.json")
    self.state = DatabaseState()
    loadFromDisk()
  }

  private func loadFromDisk() {
    state = DatabaseState()
    loadError = nil
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      state = try JSONDecoder().decode(DatabaseState.self, from: Data(contentsOf: fileURL))
    } catch { loadError = error }
  }

  /// Legacy unscoped state is kept intact; it cannot safely identify the destination.
  public func selectDestination(
    server: String, username: String, target: TargetSpace,
    livePhotos: Bool, editedCopies: Bool
  ) throws {
    try queue.sync {
      let identity = [server, username, target.rawValue, String(livePhotos), String(editedCopies)]
        .joined(separator: "\n")
      let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
      fileURL = fileURL.deletingLastPathComponent().appendingPathComponent("state-\(hash).json")
      loadFromDisk()
      if let error = loadError { throw error }
    }
  }

  private func saveToDisk() throws {
    if let error = loadError { throw error }
    let directory = fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(state)
    try data.write(to: fileURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  public func syncedAssetIdentifiers() -> Set<String> {
    queue.sync { Set(state.syncedAssets.keys) }
  }

  /// One atomic write for the full preflight, including invalidation of stale mappings.
  public func reconcileAssets(
    selectedIDs: Set<String>, confirmed: [String: Int], resources: [String: [String: Int]] = [:]
  ) throws {
    guard confirmed.values.allSatisfy({ $0 > 0 }), Set(confirmed.keys).isSubset(of: selectedIDs),
      Set(resources.keys).isSubset(of: selectedIDs),
      resources.values.allSatisfy({ $0.values.allSatisfy { $0 > 0 } })
    else {
      throw SynologyError.unexpectedResponse("Некорректный результат сверки NAS")
    }
    try queue.sync {
      let previous = state
      do {
        for id in selectedIDs {
          state.syncedAssets[id] = confirmed[id]
          state.resourceMappings[id] = resources[id]
        }
        state.failedItems.removeAll { confirmed[$0.assetIdentifier] != nil }
        try saveToDisk()
      } catch {
        state = previous
        throw error
      }
    }
  }

  // MARK: - Работа с медиафайлами

  public func isAssetSynced(appleId: String) -> Bool {
    queue.sync {
      state.syncedAssets[appleId] != nil
    }
  }

  public func synologyItemId(for appleId: String) -> Int? {
    queue.sync {
      state.syncedAssets[appleId]
    }
  }

  public func resourceItemIDs(for appleId: String) -> [String: Int] {
    queue.sync { state.resourceMappings[appleId] ?? [:] }
  }

  public func recordAssetSynced(
    appleId: String,
    synologyId: Int,
    filename: String,
    type: SyncAssetType,
    sizeBytes: Int64,
    resourceIDs: [String: Int]? = nil
  ) throws {
    guard synologyId > 0 else { throw SynologyError.unexpectedResponse("Недопустимый ID файла") }
    try queue.sync {
      let previous = state
      do {
        state.syncedAssets[appleId] = synologyId
        if let resourceIDs { state.resourceMappings[appleId] = resourceIDs }

        // Удаляем из списка ошибок, если ранее была ошибка
        state.failedItems.removeAll { $0.assetIdentifier == appleId }

        // Добавляем в историю
        let historyItem = SyncHistoryItem(
          assetIdentifier: appleId,
          filename: filename,
          type: type,
          timestamp: Date(),
          synologyId: synologyId,
          sizeBytes: sizeBytes
        )
        state.history.insert(historyItem, at: 0)
        if state.history.count > 50 {
          state.history = Array(state.history.prefix(50))
        }

        try saveToDisk()
      } catch {
        state = previous
        throw error
      }
    }
  }

  // MARK: - Работа с Альбомами

  public func synologyAlbumId(for appleAlbumId: String) -> Int? {
    queue.sync {
      state.syncedAlbums[appleAlbumId]
    }
  }

  public func recordAlbumSynced(appleAlbumId: String, synologyAlbumId: Int, title: String) throws {
    try queue.sync {
      let previous = state
      do {
        state.syncedAlbums[appleAlbumId] = synologyAlbumId
        state.failedItems.removeAll { $0.assetIdentifier == appleAlbumId }

        let historyItem = SyncHistoryItem(
          assetIdentifier: appleAlbumId,
          filename: title,
          type: .album,
          timestamp: Date(),
          synologyId: synologyAlbumId,
          sizeBytes: 0
        )
        state.history.insert(historyItem, at: 0)
        if state.history.count > 50 {
          state.history = Array(state.history.prefix(50))
        }

        try saveToDisk()
      } catch {
        state = previous
        throw error
      }
    }
  }

  // MARK: - Ошибки и повторные попытки

  public func recordFailure(appleId: String, filename: String, errorMessage: String) {
    queue.sync {
      if let index = state.failedItems.firstIndex(where: { $0.assetIdentifier == appleId }) {
        let old = state.failedItems[index]
        state.failedItems[index] = SyncErrorItem(
          assetIdentifier: appleId, filename: filename,
          errorMessage: errorMessage, timestamp: Date(), retryCount: old.retryCount + 1)
      } else {
        let errorItem = SyncErrorItem(
          assetIdentifier: appleId,
          filename: filename,
          errorMessage: errorMessage,
          timestamp: Date(),
          retryCount: 1
        )
        state.failedItems.append(errorItem)
      }
      do { try saveToDisk() } catch {
        AppLogger.error(
          "Не удалось сохранить базу синхронизации", details: error.localizedDescription)
      }
    }
  }

  public func clearFailures() {
    queue.sync {
      state.failedItems.removeAll()
      do { try saveToDisk() } catch {
        AppLogger.error(
          "Не удалось сохранить базу синхронизации", details: error.localizedDescription)
      }
    }
  }

  public func removeFailure(appleId: String) {
    queue.sync {
      state.failedItems.removeAll { $0.assetIdentifier == appleId }
      do { try saveToDisk() } catch {
        AppLogger.error(
          "Не удалось сохранить базу синхронизации", details: error.localizedDescription)
      }
    }
  }

  // MARK: - Получение данных

  public var syncedCount: Int {
    queue.sync {
      state.syncedAssets.count
    }
  }

  public func getRecentHistory(limit: Int = 20) -> [SyncHistoryItem] {
    queue.sync {
      Array(state.history.prefix(max(0, limit)))
    }
  }

  public func getFailedItems() -> [SyncErrorItem] {
    queue.sync {
      state.failedItems
    }
  }

  // MARK: - Сброс кэша

  public func clearAllCache() {
    queue.sync {
      state.syncedAssets.removeAll()
      state.resourceMappings.removeAll()
      state.syncedAlbums.removeAll()
      state.history.removeAll()
      state.failedItems.removeAll()
      do { try saveToDisk() } catch {
        AppLogger.error(
          "Не удалось сохранить базу синхронизации", details: error.localizedDescription)
      }
    }
  }
}
