import Foundation

/// Текущая стадия процесса синхронизации
public enum SyncStage: String, Codable, CaseIterable, Sendable {
  case idle
  case scanning
  case checkingSynology
  case downloadingFromICloud
  case uploadingToSynology
  case syncingAlbums
  case paused
  case waitingForNetwork
  case cancelling
  case cancelled
  case attention
  case completed
  case error

  public var localizedDescription: String {
    switch self {
    case .idle:
      return "Ожидание"
    case .scanning:
      return "Сканирование медиатеки..."
    case .checkingSynology:
      return "Сверка с Synology…"
    case .downloadingFromICloud:
      return "Скачивание из iCloud..."
    case .uploadingToSynology:
      return "Выгрузка на Synology..."
    case .syncingAlbums:
      return "Синхронизация альбомов..."
    case .waitingForNetwork:
      return "Ожидание сети…"
    case .paused:
      return "Приостановлено"
    case .cancelling:
      return "Остановка синхронизации…"
    case .cancelled:
      return "Синхронизация отменена"
    case .attention:
      return "Требуется внимание"
    case .completed:
      return "Синхронизация завершена"
    case .error:
      return "Ошибка синхронизации"
    }
  }
}

/// Фильтрация источника в Apple Photos
public enum LibraryScope: String, Codable, CaseIterable, Identifiable, Sendable {
  case personalOnly
  case sharedOnly
  case both

  public var id: String { rawValue }

  public var localizedTitle: String {
    switch self {
    case .personalOnly:
      return "Только Личная медиатека"
    case .sharedOnly:
      return "Только общие альбомы iCloud"
    case .both:
      return "Личная и общие альбомы"
    }
  }

  public var localizedSubtitle: String {
    switch self {
    case .personalOnly:
      return "Синхронизировать только ваши персональные снимки"
    case .sharedOnly:
      return "Синхронизировать снимки из общих альбомов iCloud"
    case .both:
      return "Синхронизировать персональные и общие снимки"
    }
  }
}

/// Пространство назначения в Synology Photos
public enum TargetSpace: String, Codable, CaseIterable, Identifiable, Sendable {
  case personal
  case shared
  case separate

  public var id: String { rawValue }

  public var localizedTitle: String {
    switch self {
    case .personal:
      return "Личное пространство (Personal Space — /home/Photos)"
    case .shared:
      return "Общее пространство (Shared Space — /photo)"
    case .separate:
      return "Раздельно (личные → Personal, общие альбомы → Shared)"
    }
  }

  public var uploadApiPath: String {
    switch self {
    case .personal:
      return "SYNO.Foto.Upload.Item"
    case .shared:
      return "SYNO.FotoTeam.Upload.Item"
    case .separate:
      return "SYNO.Foto.Upload.Item"
    }
  }
}

/// Тип синхронизируемого объекта для аналитики и UI
public enum SyncAssetType: String, Codable, Sendable {
  case photo
  case video
  case livePhoto
  case album

  public var localizedTitle: String {
    switch self {
    case .photo:
      return "Фото"
    case .video:
      return "Видео"
    case .livePhoto:
      return "Live Photo"
    case .album:
      return "Альбом"
    }
  }

  public var sfSymbol: String {
    switch self {
    case .photo:
      return "photo"
    case .video:
      return "video.fill"
    case .livePhoto:
      return "livephoto"
    case .album:
      return "rectangle.stack.fill"
    }
  }
}

/// Запись в истории успешных загрузок
public struct SyncHistoryItem: Identifiable, Codable, Sendable {
  public let id: UUID
  public let assetIdentifier: String
  public let filename: String
  public let type: SyncAssetType
  public let timestamp: Date
  public let synologyId: Int
  public let sizeBytes: Int64

  public init(
    id: UUID = UUID(),
    assetIdentifier: String,
    filename: String,
    type: SyncAssetType,
    timestamp: Date = Date(),
    synologyId: Int,
    sizeBytes: Int64 = 0
  ) {
    self.id = id
    self.assetIdentifier = assetIdentifier
    self.filename = filename
    self.type = type
    self.timestamp = timestamp
    self.synologyId = synologyId
    self.sizeBytes = sizeBytes
  }
}

/// Запись об ошибке синхронизации
public struct SyncErrorItem: Identifiable, Codable, Sendable {
  public let id: UUID
  public let assetIdentifier: String
  public let filename: String
  public let errorMessage: String
  public let timestamp: Date
  public var retryCount: Int

  public init(
    id: UUID = UUID(),
    assetIdentifier: String,
    filename: String,
    errorMessage: String,
    timestamp: Date = Date(),
    retryCount: Int = 0
  ) {
    self.id = id
    self.assetIdentifier = assetIdentifier
    self.filename = filename
    self.errorMessage = errorMessage
    self.timestamp = timestamp
    self.retryCount = retryCount
  }
}

/// Информация об альбоме из Apple Photos для настроек
public struct AlbumInfo: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let assetCount: Int
  public let isCloudShared: Bool

  public init(id: String, title: String, assetCount: Int, isCloudShared: Bool) {
    self.id = id
    self.title = title
    self.assetCount = assetCount
    self.isCloudShared = isCloudShared
  }
}

/// Статус подключения к серверу
public enum ConnectionStatus: Equatable, Sendable {
  case disconnected
  case connecting
  case connected(serverName: String, dsmVersion: String)
  case failed(message: String)

  public var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }

  public var statusText: String {
    switch self {
    case .disconnected:
      return "Не подключено"
    case .connecting:
      return "Подключение..."
    case .connected(let server, _):
      return "Подключено: \(server)"
    case .failed(let message):
      return "Ошибка: \(message)"
    }
  }
}
