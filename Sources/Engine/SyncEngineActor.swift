import Foundation
import Photos

/// Owns reconciliation and a bounded set of concurrent asset pipelines. Live Photo parts remain ordered.
public actor SyncEngineActor {
  private var isPaused = false
  private var confirmedResources: [String: [String: SynologyMediaItem]] = [:]

  public init() {}
  public func setPaused(_ paused: Bool) { isPaused = paused }
  public func reset() {
    isPaused = false
    confirmedResources.removeAll()
  }
  public func waitUntilReady() async throws {
    while true {
      try Task.checkCancellation()
      let manuallyPaused = await MainActor.run { SyncState.shared.isPaused }
      if !isPaused && !manuallyPaused { return }
      try await Task.sleep(for: .milliseconds(150))
    }
  }

  private func recovering<T>(transferID: UUID? = nil, _ operation: () async throws -> T)
    async throws -> T
  {
    let operationID = UUID()
    do {
      let result = try await TransferRetry.run(
        checkpoint: { try await self.waitUntilReady() },
        wait: { attempt, network in
          try await NetworkAvailability.shared.waitBeforeRetry(attempt: attempt, network: network) {
            try await self.waitUntilReady()
          }
        },
        onRetry: { error, network in
          await MainActor.run {
            if network {
              SyncState.shared.beginNetworkWait(operationID: operationID, transferID: transferID)
            }
            AppLogger.shared.warning(
              network
                ? "Связь прервана. Синхронизация продолжится автоматически; пауза и отмена сохраняют приоритет."
                : "Повторное извлечение оригинала Photos",
              details: TransferRetry.message(for: error))
          }
        }, operation: operation)
      await MainActor.run { SyncState.shared.endNetworkWait(operationID: operationID) }
      return result
    } catch {
      await MainActor.run { SyncState.shared.endNetworkWait(operationID: operationID) }
      throw error
    }
  }

  public func validateAccess(target: TargetSpace, config: SyncConfig, client: SynologyAPIClient)
    async throws
  {
    try await recovering {
      try await client.validateAccess(
        targetSpace: target, allowInsecureSSL: config.allowInsecureSSL)
    }
  }

  nonisolated static func mustStopQueue(after error: Error) -> Bool {
    if error is CancellationError { return true }
    if let error = error as? SynologyError {
      switch error {
      case .sessionExpired, .invalidCredentials, .twoFactorRequired, .twoFactorFailed,
        .permissionDenied, .invalidURL, .invalidParameters, .unexpectedResponse:
        return true
      case .networkError(let underlying): return mustStopQueue(after: underlying)
      case .uploadFailed(let code, _): return code == 429 || code >= 500
      default: return false
      }
    }
    return error is DecodingError || (error as NSError).domain == NSURLErrorDomain
  }

  /// Refreshes the complete remote inventory on every run, so stale local mappings cannot hide NAS deletions.
  public func prepareAssets(
    _ assets: [PHAsset], config: SyncConfig, database: SyncDatabase, apiClient: SynologyAPIClient
  ) async throws -> [PHAsset] {
    await MainActor.run { SyncState.shared.setStage(.checkingSynology) }
    var targets: [TargetSpace] =
      config.targetSpace == .separate ? [.personal, .shared] : [config.targetSpace]
    if config.targetSpace == .separate {
      if config.libraryScope == .personalOnly { targets = [.personal] }
      if config.libraryScope == .sharedOnly { targets = [.shared] }
    }
    var inventories: [String: RemoteMediaInventory] = [:]
    var scannedFiles = 0
    var scannedFolders = 0
    for target in targets {
      let previousFiles = scannedFiles
      let previousFolders = scannedFolders
      let items = try await recovering {
        try await apiClient.listMedia(
          targetSpace: target, allowInsecureSSL: config.allowInsecureSSL,
          progress: { files, folders in
            await MainActor.run {
              SyncState.shared.updateNASScan(
                files: previousFiles + files, folders: previousFolders + folders)
            }
          }, checkpoint: { try await self.waitUntilReady() })
      }
      inventories[target.rawValue] = RemoteMediaInventory(items: items)
      scannedFiles += items.count
      // Folder progress is already published by listMedia; preserve it between spaces.
      scannedFolders = await MainActor.run { SyncState.shared.nasScannedFolderCount }
    }
    var missing: [PHAsset] = []
    var confirmed: [String: Int] = [:]
    var fingerprints: [String: FileFingerprint] = [:]
    confirmedResources.removeAll()
    for (offset, asset) in assets.enumerated() {
      try await waitUntilReady()
      let presentBefore = confirmed.count
      guard let plan = try? PhotoTransferPlan(asset: asset, config: config),
        let inventory = inventories[plan.target.rawValue]
      else {
        missing.append(asset)
        await MainActor.run {
          SyncState.shared.updateComparison(checked: offset + 1, present: presentBefore)
        }
        continue
      }
      var parts: [String: SynologyMediaItem] = [:]
      let cachedResources = database.resourceItemIDs(for: asset.localIdentifier)
      for (index, source) in plan.resources.enumerated() {
        try await waitUntilReady()
        let cached =
          cachedResources[source.filename]
          ?? (index == 0 ? database.synologyItemId(for: asset.localIdentifier) : nil)
        let isPaired =
          source.resource.type == .pairedVideo || source.resource.type == .fullSizePairedVideo
        let primary = parts[plan.resources[0].filename]
        let safeCached = isPaired && cached == primary?.id && primary?.type != "live" ? nil : cached
        if let known = inventory.knownItem(
          filename: source.filename, cachedID: safeCached, originalFilename: source.legacyFilename)
        {
          parts[source.filename] = known
          continue
        }
        // A grouped Live Photo explicitly advertises its paired video as type "live".
        if source.resource.type == .pairedVideo || source.resource.type == .fullSizePairedVideo,
          let primary = parts[plan.resources[0].filename], primary.type == "live"
        {
          parts[source.filename] = primary
          continue
        }
        let candidates = inventory.legacyCandidates(originalFilename: source.legacyFilename)
        guard !candidates.isEmpty else { continue }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
          "syno_verify_\(UUID().uuidString)")
        let local = directory.appendingPathComponent(source.filename)
        defer { try? FileManager.default.removeItem(at: directory) }
        let verificationName = source.resource.originalFilename
        await MainActor.run { SyncState.shared.currentFileName = "Проверка: " + verificationName }
        do {
          try await extractResourceToFile(resource: source.resource, destinationURL: local)
        } catch {
          if Task.isCancelled || error is CancellationError { throw error }
          AppLogger.warning(
            "Не удалось извлечь оригинал для сверки; файл остаётся в очереди",
            details: TransferRetry.message(for: error))
          break
        }
        let localHash = try FileFingerprint.read(local)
        for candidate in candidates where candidate.filesize == localHash.size {
          try await waitUntilReady()
          let key = plan.target.rawValue + ":" + String(candidate.id)
          let remoteHash: FileFingerprint
          if let cachedHash = fingerprints[key] {
            remoteHash = cachedHash
          } else {
            remoteHash = try await recovering {
              try await apiClient.originalFingerprint(
                itemID: candidate.id, targetSpace: plan.target,
                allowInsecureSSL: config.allowInsecureSSL)
            }
            fingerprints[key] = remoteHash
          }
          if localHash == remoteHash {
            parts[source.filename] = candidate
            break
          }
        }
      }
      confirmedResources[asset.localIdentifier] = parts
      if parts.count == plan.resources.count, let primary = parts[plan.resources[0].filename] {
        confirmed[asset.localIdentifier] = primary.id
      } else {
        missing.append(asset)
      }
      let presentAfter = confirmed.count
      await MainActor.run {
        SyncState.shared.updateComparison(checked: offset + 1, present: presentAfter)
      }
    }
    try await waitUntilReady()
    try database.reconcileAssets(
      selectedIDs: Set(assets.map(\.localIdentifier)), confirmed: confirmed,
      resources: confirmedResources.mapValues { $0.mapValues(\.id) })
    let presentTotal = confirmed.count
    let uploadTotal = missing.count
    await MainActor.run {
      SyncState.shared.setReconciliationSummary(
        total: assets.count, alreadyPresent: presentTotal, toUpload: uploadTotal)
    }
    return missing
  }

  public func syncAssets(
    _ assets: [PHAsset], config: SyncConfig, database: SyncDatabase, apiClient: SynologyAPIClient
  ) async throws {
    let limit = config.parallelTransfers
    try await BoundedTransferQueue.run(count: assets.count, limit: limit) { index in
      try await self.syncSingleAsset(
        assets[index], config: config, database: database, apiClient: apiClient)
    }
  }

  public func syncSingleAsset(
    _ asset: PHAsset, config: SyncConfig, database: SyncDatabase, apiClient: SynologyAPIClient
  ) async throws {
    try await waitUntilReady()
    let transferID = UUID()
    await MainActor.run {
      SyncState.shared.beginTransfer(id: transferID, filename: asset.localIdentifier)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "syno_media_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var displayName = asset.localIdentifier
    do {
      let plan = try PhotoTransferPlan(asset: asset, config: config)
      displayName = plan.resources[0].resource.originalFilename
      var primaryID = 0
      var totalBytes: Int64 = 0
      var resourceIDs: [String: Int] = [:]
      for (index, source) in plan.resources.enumerated() {
        try await waitUntilReady()
        if let existing = confirmedResources[asset.localIdentifier]?[source.filename] {
          if index == 0 { primaryID = existing.id }
          resourceIDs[source.filename] = existing.id
          continue
        }
        let file = directory.appendingPathComponent(source.filename)
        let originalName = source.resource.originalFilename
        let revision = UUID()
        defer { try? FileManager.default.removeItem(at: file) }
        await MainActor.run {
          SyncState.shared.setTransferFile(
            id: transferID, revision: revision, name: originalName, stage: .downloadingFromICloud)
        }
        try await extractResourceToFile(
          resource: source.resource, destinationURL: file, transferID: transferID,
          revision: revision)
        totalBytes +=
          (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
          .int64Value ?? 0
        try await waitUntilReady()
        await MainActor.run {
          SyncState.shared.setTransferFile(
            id: transferID, revision: revision, name: originalName, stage: .uploadingToSynology)
        }
        let id = try await recovering(transferID: transferID) {
          try await apiClient.uploadItem(
            fileURL: file, filename: source.filename, creationDate: plan.creationDate,
            targetSpace: plan.target, allowInsecureSSL: config.allowInsecureSSL
          ) { progress in
            Task { @MainActor in
              SyncState.shared.updateTransfer(id: transferID, revision: revision, upload: progress)
            }
          }
        }
        if index == 0 { primaryID = id }
        resourceIDs[source.filename] = id
      }
      try Task.checkCancellation()
      try database.recordAssetSynced(
        appleId: asset.localIdentifier, synologyId: primaryID, filename: plan.resources[0].filename,
        type: plan.type, sizeBytes: totalBytes, resourceIDs: resourceIDs)
      let history = SyncHistoryItem(
        assetIdentifier: asset.localIdentifier, filename: displayName, type: plan.type,
        synologyId: primaryID, sizeBytes: totalBytes)
      await MainActor.run { SyncState.shared.markFileSuccess(historyItem: history) }
    } catch {
      await MainActor.run { SyncState.shared.endTransfer(id: transferID) }
      await recordError(
        appleId: asset.localIdentifier, filename: displayName,
        error: TransferRetry.message(for: error),
        database: database)
      if Self.mustStopQueue(after: error) { throw error }
      return
    }
    await MainActor.run { SyncState.shared.endTransfer(id: transferID) }
  }

  private func extractResourceToFile(
    resource: PHAssetResource, destinationURL: URL, transferID: UUID? = nil, revision: UUID? = nil
  ) async throws {
    try await waitUntilReady()
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try await recovering(transferID: transferID) {
      try? FileManager.default.removeItem(at: destinationURL)
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress in
          Task { @MainActor in
            if let transferID, let revision {
              SyncState.shared.updateTransfer(
                id: transferID, revision: revision, download: progress)
            } else {
              SyncState.shared.updateICloudProgress(progress)
            }
          }
        }
        PHAssetResourceManager.default().writeData(
          for: resource, toFile: destinationURL, options: options
        ) { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
    }
    try Task.checkCancellation()
  }

  // MARK: - Синхронизация Альбомов

  public func syncAlbums(
    collections: [PHAssetCollection],
    config: SyncConfig,
    database: SyncDatabase,
    apiClient: SynologyAPIClient
  ) async throws {
    await MainActor.run {
      SyncState.shared.setStage(.syncingAlbums)
    }

    var albumCache: [String: [SynologyAlbumItem]] = [:]
    // Fetch each destination independently; never create albums after a failed listing.
    for collection in collections {
      try await waitUntilReady()
      if Task.isCancelled { break }
      let shared = collection.assetCollectionSubtype == .albumCloudShared
      let target: TargetSpace =
        config.targetSpace == .separate ? (shared ? .shared : .personal) : config.targetSpace
      let albumTitle = collection.localizedTitle ?? "Без названия"

      // 1. Считываем все ассеты альбома
      let fetchOptions = PHFetchOptions()
      let assetsInAlbum = PHAsset.fetchAssets(in: collection, options: fetchOptions)

      var synologyItemIds: [Int] = []

      for i in 0..<assetsInAlbum.count {
        if Task.isCancelled { break }
        let asset = assetsInAlbum.object(at: i)
        let assetShared = asset.sourceType.contains(.typeCloudShared)
        if config.libraryScope == .personalOnly && assetShared { continue }
        if config.libraryScope == .sharedOnly && !assetShared { continue }
        if !config.syncAllHistory, let date = asset.creationDate, date < config.syncStartDate {
          continue
        }
        if config.targetSpace == .separate && (assetShared != (target == .shared)) { continue }

        // Если ассет уже загружен на Synology, берем его ID
        if let itemId = database.synologyItemId(for: asset.localIdentifier), itemId > 0 {
          synologyItemIds.append(itemId)
        }

      }

      guard !synologyItemIds.isEmpty else {
        await MainActor.run { SyncState.shared.markAlbumSkipped() }
        continue
      }

      do {
        if albumCache[target.rawValue] == nil {
          albumCache[target.rawValue] = try await recovering {
            try await apiClient.listAlbums(
              allowInsecureSSL: config.allowInsecureSSL, targetSpace: target)
          }
        }
        let existingSynologyAlbums = albumCache[target.rawValue] ?? []
        // 2. Ищем или создаем альбом на Synology с таким же именем
        let synologyAlbumId: Int
        if let storedID = database.synologyAlbumId(for: collection.localIdentifier),
          existingSynologyAlbums.contains(where: { $0.id == storedID })
        {
          synologyAlbumId = storedID
        } else if let match = existingSynologyAlbums.first(where: {
          $0.name.caseInsensitiveCompare(albumTitle) == .orderedSame
        }) {
          synologyAlbumId = match.id
        } else {
          synologyAlbumId = try await recovering {
            let albums = try await apiClient.listAlbums(
              allowInsecureSSL: config.allowInsecureSSL, targetSpace: target)
            if let existing = albums.first(where: {
              $0.name.caseInsensitiveCompare(albumTitle) == .orderedSame
            }) {
              return existing.id
            }
            return try await apiClient.createAlbum(
              name: albumTitle, allowInsecureSSL: config.allowInsecureSSL, targetSpace: target)
          }
          albumCache[target.rawValue, default: []].append(
            SynologyAlbumItem(id: synologyAlbumId, name: albumTitle, itemCount: 0))
        }

        // 3. Добавляем элементы в альбом без дублирования файлов
        try await recovering {
          try await apiClient.addItemsToAlbum(
            albumId: synologyAlbumId,
            itemIds: synologyItemIds,
            allowInsecureSSL: config.allowInsecureSSL, targetSpace: target
          )
        }

        // 4. Фиксируем успешную синхронизацию альбома
        try Task.checkCancellation()
        try database.recordAlbumSynced(
          appleAlbumId: collection.localIdentifier,
          synologyAlbumId: synologyAlbumId,
          title: albumTitle
        )

        let historyItem = SyncHistoryItem(
          assetIdentifier: collection.localIdentifier,
          filename: "Альбом: \(albumTitle) (\(synologyItemIds.count) элементов)",
          type: .album,
          timestamp: Date(),
          synologyId: synologyAlbumId,
          sizeBytes: 0
        )

        await MainActor.run {
          SyncState.shared.markAlbumSuccess(historyItem: historyItem)
        }
      } catch {
        await recordError(
          appleId: collection.localIdentifier,
          filename: "Альбом: \(albumTitle)",
          error: TransferRetry.message(for: error),
          database: database, isAlbum: true
        )
        if Self.mustStopQueue(after: error) { throw error }
      }
    }
  }

  // MARK: - Запись ошибки

  private func recordError(
    appleId: String, filename: String, error: String, database: SyncDatabase, isAlbum: Bool = false
  ) async {
    guard !Task.isCancelled else { return }
    database.recordFailure(appleId: appleId, filename: filename, errorMessage: error)
    let errorItem = SyncErrorItem(
      assetIdentifier: appleId,
      filename: filename,
      errorMessage: error,
      timestamp: Date()
    )
    AppLogger.error("Ошибка синхронизации: '\(filename)'", details: error)
    await MainActor.run {
      SyncState.shared.markFileFailed(errorItem: errorItem, isAlbum: isAlbum)
    }
  }
}
