import Combine
import Foundation

/// Состояние синхронизации и телеметрии в реальном времени (@MainActor)
@MainActor
public final class SyncState: ObservableObject {
  public static let shared = SyncState()

  // MARK: - Глобальные счетчики очереди

  @Published public private(set) var isReconciling = false
  @Published public var totalSelectedCount = 0
  @Published public private(set) var alreadyPresentCount = 0
  @Published public private(set) var nasScannedFileCount = 0
  @Published public private(set) var nasScannedFolderCount = 0
  @Published public private(set) var comparedAssetCount = 0
  @Published public var totalToSyncCount: Int = 0
  @Published public var syncedCount: Int = 0
  @Published public private(set) var warningCount: Int = 0
  @Published public private(set) var processedAlbumsCount: Int = 0
  @Published public var failedCount: Int = 0
  @Published public var totalAlbumsCount: Int = 0
  @Published public var syncedAlbumsCount: Int = 0

  /// Вычисляемое количество оставшихся файлов
  public var remainingCount: Int {
    let remaining = totalToSyncCount - syncedCount - fileFailureCount
    return max(0, remaining)
  }

  /// Общий процент выполнения текущей очереди (0.0 ... 1.0)
  public var overallProgressFraction: Double {
    guard totalToSyncCount > 0 else { return 0.0 }
    let progress = Double(syncedCount + fileFailureCount) / Double(totalToSyncCount)
    return min(1.0, max(0.0, progress))
  }

  // MARK: - Прогресс текущего файла (Двухэтапный)

  @Published public var currentFileName: String = ""
  @Published public var currentStage: SyncStage = .idle
  @Published public var iCloudDownloadProgress: Double = 0.0
  @Published public var synologyUploadProgress: Double = 0.0
  @Published public var uploadProgressBytesText: String = ""
  @Published public var uploadSpeedText: String = ""

  // MARK: - Статус подключения и управление процессом

  @Published public var connectionStatus: ConnectionStatus = .disconnected
  @Published public var isSyncing: Bool = false
  @Published public var isPaused: Bool = false

  // MARK: - История и ошибки

  @Published public var recentHistory: [SyncHistoryItem] = []
  @Published public var failedItems: [SyncErrorItem] = []

  private var stageBeforePause: SyncStage = .scanning
  private var sessionErrorCount = 0
  private var fileFailureCount = 0

  private let database: SyncDatabase

  init(database: SyncDatabase = .shared) {
    self.database = database
    reloadFromDatabase()
  }

  // MARK: - Обновление состояния

  public func reloadFromDatabase() {
    self.recentHistory = database.getRecentHistory(limit: 20)
    self.failedItems = database.getFailedItems()
  }

  public func startNewSession(totalFiles: Int, totalAlbums: Int) {
    self.isReconciling = true
    self.totalSelectedCount = totalFiles
    self.alreadyPresentCount = 0
    self.nasScannedFileCount = 0
    self.nasScannedFolderCount = 0
    self.comparedAssetCount = 0
    self.warningCount = 0
    self.processedAlbumsCount = 0
    self.sessionErrorCount = 0
    self.fileFailureCount = 0
    self.totalToSyncCount = totalFiles
    self.syncedCount = 0
    self.failedCount = 0
    self.totalAlbumsCount = totalAlbums
    self.syncedAlbumsCount = 0
    self.isSyncing = true
    self.isPaused = false
    self.currentStage = .scanning
    self.currentFileName = ""
    self.iCloudDownloadProgress = 0.0
    self.synologyUploadProgress = 0.0
    self.uploadProgressBytesText = ""
    self.uploadSpeedText = ""
    reloadFromDatabase()
  }

  public func updateNASScan(files: Int, folders: Int) {
    nasScannedFileCount = files
    nasScannedFolderCount = folders
  }

  public func updateComparison(checked: Int, present: Int) {
    comparedAssetCount = checked
    alreadyPresentCount = present
  }

  public func setReconciliationSummary(total: Int, alreadyPresent: Int, toUpload: Int) {
    isReconciling = false
    totalSelectedCount = total
    alreadyPresentCount = alreadyPresent
    totalToSyncCount = toUpload
    comparedAssetCount = total
    currentFileName = ""
    iCloudDownloadProgress = 0
    reloadFromDatabase()
  }

  public func setCurrentFile(name: String, stage: SyncStage) {
    self.currentFileName = name
    setStage(stage)
    self.iCloudDownloadProgress = 0.0
    self.synologyUploadProgress = 0.0
    self.uploadProgressBytesText = ""
    self.uploadSpeedText = ""
  }

  public func updateICloudProgress(_ progress: Double) {
    self.iCloudDownloadProgress = min(1.0, max(0.0, progress))
  }

  public func updateSynologyProgress(_ info: UploadProgressInfo) {
    self.synologyUploadProgress = info.fractionCompleted
    self.uploadProgressBytesText = info.formattedText
    self.uploadSpeedText = info.speedText
  }

  public func markFileSuccess(historyItem: SyncHistoryItem) {
    self.syncedCount += 1
    self.recentHistory.insert(historyItem, at: 0)
    if self.recentHistory.count > 20 {
      self.recentHistory = Array(self.recentHistory.prefix(20))
    }
    AppLogger.shared.success(
      "Выгружен: '\(historyItem.filename)' (\(ByteCountFormatter.string(fromByteCount: historyItem.sizeBytes, countStyle: .file)))"
    )
    self.currentFileName = ""
    self.iCloudDownloadProgress = 0.0
    self.synologyUploadProgress = 0.0
    self.uploadProgressBytesText = ""
    self.uploadSpeedText = ""
  }

  public func markFileFailed(errorItem: SyncErrorItem, isAlbum: Bool = false) {
    sessionErrorCount += 1
    if !isAlbum { fileFailureCount += 1 }
    self.failedCount += 1
    if let idx = self.failedItems.firstIndex(where: {
      $0.assetIdentifier == errorItem.assetIdentifier
    }) {
      self.failedItems[idx] = errorItem
    } else {
      self.failedItems.append(errorItem)
    }
  }

  public func markAlbumSuccess(historyItem: SyncHistoryItem) {
    self.syncedAlbumsCount += 1
    self.processedAlbumsCount += 1
    self.recentHistory.insert(historyItem, at: 0)
    if self.recentHistory.count > 20 {
      self.recentHistory = Array(self.recentHistory.prefix(20))
    }
    AppLogger.shared.success("Синхронизирован альбом: '\(historyItem.filename)'")
  }

  public func setStage(_ stage: SyncStage) {
    guard currentStage != .cancelling && currentStage != .cancelled else { return }
    stageBeforePause = stage
    currentStage = isPaused ? .paused : stage
  }

  public func noteWarning() {
    guard isSyncing else { return }
    warningCount += 1
  }

  public func noteError() {
    guard isSyncing else { return }
    sessionErrorCount += 1
  }

  public func markAlbumSkipped() {
    processedAlbumsCount += 1
  }

  public func requestCancellation() {
    guard isSyncing else { return }
    isPaused = false
    currentStage = .cancelling
  }

  public func finishSession(cancelled: Bool = false) {
    guard isSyncing else { return }
    // A late callback must never turn a paused/stopping run into a successful run.
    if isPaused && !cancelled && currentStage != .cancelling { return }
    reloadFromDatabase()
    let wasCancelled = cancelled || currentStage == .cancelling
    let hasErrors = sessionErrorCount > 0 || !failedItems.isEmpty || currentStage == .error
    let incomplete = remainingCount > 0 || processedAlbumsCount < totalAlbumsCount
    isSyncing = false
    isReconciling = false
    isPaused = false
    currentStage =
      wasCancelled
      ? .cancelled
      : (hasErrors ? .error : (warningCount > 0 || incomplete ? .attention : .completed))
    currentFileName = ""
    uploadSpeedText = ""
    uploadProgressBytesText = ""
    iCloudDownloadProgress = 0
    synologyUploadProgress = 0
  }

  public func togglePause() {
    guard isSyncing, currentStage != .cancelling else { return }
    if !isPaused { stageBeforePause = currentStage }
    isPaused.toggle()
    currentStage = isPaused ? .paused : stageBeforePause
  }
}
