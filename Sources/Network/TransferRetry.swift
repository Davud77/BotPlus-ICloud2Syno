import Foundation
import Network
import Photos

/// Only transport errors are retried indefinitely. Authentication, TLS and corrupt resources fail normally.
enum TransferRetry {
  static func isNetworkFailure(_ error: Error, depth: Int = 0) -> Bool {
    guard depth < 8, !(error is CancellationError) else { return false }
    if case SynologyError.networkError(let underlying) = error {
      return isNetworkFailure(underlying, depth: depth + 1)
    }
    let value = error as NSError
    if value.domain == NSURLErrorDomain {
      return [
        URLError.notConnectedToInternet, .networkConnectionLost, .timedOut,
        .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
        .dataNotAllowed,
      ].contains(URLError.Code(rawValue: value.code))
    }
    if value.domain == PHPhotosErrorDomain, value.code == PHPhotosError.networkError.rawValue {
      return true
    }
    if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
      return isNetworkFailure(underlying, depth: depth + 1)
    }
    return false
  }

  static func isTransientPhotoFailure(_ error: Error) -> Bool {
    let value = error as NSError
    return value.domain == PHPhotosErrorDomain
      && [PHPhotosError.internalError.rawValue, PHPhotosError.operationInterrupted.rawValue]
        .contains(value.code)
  }

  /// Injectable wait and checkpoints make pause, cancellation and retry limits testable without a live NAS.
  static func run<T>(
    isolation: isolated (any Actor)? = #isolation,
    checkpoint: () async throws -> Void,
    wait: (_ attempt: Int, _ network: Bool) async throws -> Void,
    onRetry: (_ error: Error, _ network: Bool) async -> Void,
    operation: () async throws -> T
  ) async throws -> T {
    var attempt = 0
    var photoRetries = 0
    while true {
      try Task.checkCancellation()
      try await checkpoint()
      do { return try await operation() } catch {
        try Task.checkCancellation()
        let network = isNetworkFailure(error)
        if !network {
          guard isTransientPhotoFailure(error), photoRetries < 2 else { throw error }
          photoRetries += 1
        }
        attempt += 1
        await onRetry(error, network)
        try await wait(attempt, network)
      }
    }
  }

  static func message(for error: Error) -> String {
    let value = error as NSError
    if value.domain == PHPhotosErrorDomain {
      switch value.code {
      case PHPhotosError.networkError.rawValue:
        return "Photos не смогла скачать оригинал из iCloud: ошибка сети (3169)."
      case PHPhotosError.internalError.rawValue:
        return
          "Внутренняя ошибка извлечения оригинала Photos (код −1). Проверьте, открывается ли оригинал в Фото."
      case PHPhotosError.missingResource.rawValue:
        return "Оригинал отсутствует в медиатеке Photos (3303)."
      case PHPhotosError.notEnoughSpace.rawValue:
        return "Недостаточно свободного места для извлечения оригинала Photos (3305)."
      default: break
      }
    }
    return error.localizedDescription
  }
}

@MainActor
final class NetworkAvailability {
  static let shared = NetworkAvailability()
  private let monitor = NWPathMonitor()
  private(set) var isOffline = false
  private init() {
    monitor.pathUpdateHandler = { path in
      let offline = path.status != .satisfied
      Task { @MainActor in self.isOffline = offline }
    }
    monitor.start(queue: DispatchQueue(label: "com.synologyphotosync.reachability"))
  }

  /// A satisfied route is only a hint; the next real request determines server availability.
  func waitBeforeRetry(attempt: Int, network: Bool, checkpoint: @Sendable () async throws -> Void)
    async throws
  {
    let seconds = min(60.0, pow(2, Double(min(attempt, 6))))
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(Int64(seconds * 1000)))
    var sawOffline = false
    while true {
      try Task.checkCancellation()
      try await checkpoint()
      if network && isOffline {
        sawOffline = true
      } else if sawOffline || clock.now >= deadline {
        return
      }
      try await Task.sleep(for: .milliseconds(250))
    }
  }
}
