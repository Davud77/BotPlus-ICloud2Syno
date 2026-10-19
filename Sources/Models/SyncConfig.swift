import Foundation

/// Менеджер глобальной конфигурации и настроек приложения
public final class SyncConfig: ObservableObject, @unchecked Sendable {
  public static let shared = SyncConfig()

  private let defaults = UserDefaults.standard

  // Ключи UserDefaults
  private enum Keys {
    static let serverURL = "sync_server_url"
    static let username = "sync_username"
    static let libraryScope = "sync_library_scope"
    static let targetSpace = "sync_target_space"
    static let syncAllHistory = "sync_all_history"
    static let syncStartDate = "sync_start_date"
    static let saveLivePhotos = "sync_save_live_photos"
    static let saveEditedCopies = "sync_save_edited_copies"
    static let syncPersonalAlbums = "sync_personal_albums"
    static let syncSharedAlbums = "sync_shared_albums"
    static let selectedAlbumIdentifiers = "sync_selected_album_ids"
    static let launchAtLogin = "sync_launch_at_login"
    static let allowInsecureSSL = "sync_allow_insecure_ssl"
    static let lastKnownSessionId = "sync_last_session_id"
  }

  private init() {
    registerDefaults()
  }

  private func registerDefaults() {
    defaults.register(defaults: [
      Keys.serverURL: "https://",
      Keys.username: "",
      Keys.libraryScope: LibraryScope.both.rawValue,
      Keys.targetSpace: TargetSpace.personal.rawValue,
      Keys.syncAllHistory: true,
      // По умолчанию — последние 30 дней, если syncAllHistory выключен.
      Keys.syncStartDate: Date().timeIntervalSince1970 - (30 * 24 * 3600),
      Keys.saveLivePhotos: true,
      Keys.saveEditedCopies: false,
      Keys.syncPersonalAlbums: true,
      Keys.syncSharedAlbums: true,
      Keys.selectedAlbumIdentifiers: [String](),
      Keys.launchAtLogin: false,
      Keys.allowInsecureSSL: false,
    ])
  }

  // MARK: - Публичные свойства с уведомлением ObservableObject

  public var serverURL: String {
    get { defaults.string(forKey: Keys.serverURL) ?? "https://" }
    set {
      objectWillChange.send()
      var url = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if !url.isEmpty && !url.lowercased().hasPrefix("http://")
        && !url.lowercased().hasPrefix("https://")
      {
        url = "https://" + url
      }
      defaults.set(url, forKey: Keys.serverURL)
    }
  }

  public var username: String {
    get { defaults.string(forKey: Keys.username) ?? "" }
    set {
      objectWillChange.send()
      defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.username)
    }
  }

  public var libraryScope: LibraryScope {
    get {
      guard let raw = defaults.string(forKey: Keys.libraryScope),
        let scope = LibraryScope(rawValue: raw)
      else {
        return .both
      }
      return scope
    }
    set {
      objectWillChange.send()
      defaults.set(newValue.rawValue, forKey: Keys.libraryScope)
    }
  }

  public var targetSpace: TargetSpace {
    get {
      guard let raw = defaults.string(forKey: Keys.targetSpace),
        let space = TargetSpace(rawValue: raw)
      else {
        return .personal
      }
      return space
    }
    set {
      objectWillChange.send()
      defaults.set(newValue.rawValue, forKey: Keys.targetSpace)
    }
  }

  public var syncAllHistory: Bool {
    get { defaults.bool(forKey: Keys.syncAllHistory) }
    set {
      objectWillChange.send()
      defaults.set(newValue, forKey: Keys.syncAllHistory)
    }
  }

  public var syncStartDate: Date {
    get {
      let timestamp = defaults.double(forKey: Keys.syncStartDate)
      return timestamp > 0
        ? Date(timeIntervalSince1970: timestamp) : Date().addingTimeInterval(-30 * 86400)
    }
    set {
      objectWillChange.send()
      defaults.set(newValue.timeIntervalSince1970, forKey: Keys.syncStartDate)
    }
  }

  public var saveLivePhotos: Bool {
    get { defaults.bool(forKey: Keys.saveLivePhotos) }
    set {
      objectWillChange.send()
      defaults.set(newValue, forKey: Keys.saveLivePhotos)
    }
  }

  public var saveEditedCopies: Bool {
    get { defaults.bool(forKey: Keys.saveEditedCopies) }
    set {
      objectWillChange.send()
      defaults.set(newValue, forKey: Keys.saveEditedCopies)
    }
  }

  public var syncPersonalAlbums: Bool {
    get { defaults.bool(forKey: Keys.syncPersonalAlbums) }
    set {
      objectWillChange.send()
      defaults.set(newValue, forKey: Keys.syncPersonalAlbums)
    }
  }

  public var syncSharedAlbums: Bool {
    get { defaults.bool(forKey: Keys.syncSharedAlbums) }
    set {
      objectWillChange.send()
      defaults.set(newValue, forKey: Keys.syncSharedAlbums)
    }
  }

  public var selectedAlbumIdentifiers: Set<String> {
    get {
      let array = defaults.stringArray(forKey: Keys.selectedAlbumIdentifiers) ?? []
      return Set(array)
    }
    set {
      objectWillChange.send()
      defaults.set(Array(newValue), forKey: Keys.selectedAlbumIdentifiers)
    }
  }

  public var launchAtLogin: Bool {
    get { defaults.bool(forKey: Keys.launchAtLogin) }
    set {
      objectWillChange.send()
      defaults.set(newValue, forKey: Keys.launchAtLogin)
    }
  }

  public var allowInsecureSSL: Bool {
    get { defaults.bool(forKey: Keys.allowInsecureSSL) }
    set {
      objectWillChange.send()
      defaults.set(newValue, forKey: Keys.allowInsecureSSL)
    }
  }
}
