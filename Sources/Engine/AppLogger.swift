import AppKit
import Foundation
import OSLog

/// Структура отдельной записи в логе
public struct LogEntry: Identifiable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let level: LogLevel
  public let message: String
  public let details: String?

  public enum LogLevel: String, Sendable, CaseIterable {
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERR"

    public var emoji: String {
      switch self {
      case .info: return "ℹ️"
      case .success: return "✅"
      case .warning: return "⚠️"
      case .error: return "❌"
      }
    }
  }

  public init(
    id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String,
    details: String? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.level = level
    self.message = message
    self.details = details
  }

  public var timestampString: String {
    timestamp.formatted(.dateTime.hour().minute().second())
  }

  public var formattedText: String {
    var result = "[\(timestampString)] [\(level.rawValue)] \(message)"
    if let details = details, !details.isEmpty {
      result += "\n    └─ Детали: \(details)"
    }
    return result
  }
}

/// Централизованный менеджер подробных логов приложения с поддержкой копирования и фильтрации
@MainActor
public final class AppLogger: ObservableObject {
  public static let shared = AppLogger()

  @Published public private(set) var entries: [LogEntry] = []
  private let maxEntries = 1000

  private init() {
    log(level: .info, message: "Приложение запущено. Инициализация подсистем...")
  }

  public func log(level: LogEntry.LogLevel, message: String, details: String? = nil) {
    let entry = LogEntry(level: level, message: message, details: details)
    if level == .warning { SyncState.shared.noteWarning() }
    if level == .error { SyncState.shared.noteError() }
    entries.append(entry)
    if entries.count > maxEntries {
      entries.removeFirst(entries.count - maxEntries)
    }

    Logger(subsystem: "com.synologyphotosync.app", category: "sync")
      .log(
        "[\(level.rawValue, privacy: .public)] \(message, privacy: .private) \(details ?? "", privacy: .private)"
      )
  }

  public func info(_ message: String, details: String? = nil) {
    log(level: .info, message: message, details: details)
  }

  public func success(_ message: String, details: String? = nil) {
    log(level: .success, message: message, details: details)
  }

  public func warning(_ message: String, details: String? = nil) {
    log(level: .warning, message: message, details: details)
  }

  public func error(_ message: String, details: String? = nil) {
    log(level: .error, message: message, details: details)
  }

  public func clear() {
    entries.removeAll()
    log(level: .info, message: "Журнал логов очищен пользователем.")
  }

  public func exportAllText() -> String {
    return entries.map { $0.formattedText }.joined(separator: "\n")
  }

  public func copyAllToClipboard() {
    let text = exportAllText()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  public func copyEntryToClipboard(_ entry: LogEntry) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(entry.formattedText, forType: .string)
  }

  // MARK: - Неизолированные статические методы для вызова из фоновых потоков и акторов

  nonisolated public static func logAsync(
    level: LogEntry.LogLevel, message: String, details: String? = nil
  ) {
    Task { @MainActor in
      AppLogger.shared.log(level: level, message: message, details: details)
    }
  }

  nonisolated public static func info(_ message: String, details: String? = nil) {
    logAsync(level: .info, message: message, details: details)
  }

  nonisolated public static func success(_ message: String, details: String? = nil) {
    logAsync(level: .success, message: message, details: details)
  }

  nonisolated public static func warning(_ message: String, details: String? = nil) {
    logAsync(level: .warning, message: message, details: details)
  }

  nonisolated public static func error(_ message: String, details: String? = nil) {
    logAsync(level: .error, message: message, details: details)
  }
}
