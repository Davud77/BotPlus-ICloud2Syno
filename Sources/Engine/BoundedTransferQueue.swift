import Foundation

/// Keeps only `limit` jobs alive; errors cancel siblings and await their cleanup before returning.
enum BoundedTransferQueue {
  static let limits = 1...8
  static let defaultLimit = 3
  static func clamped(_ value: Int) -> Int { min(limits.upperBound, max(limits.lowerBound, value)) }

  static func run(count: Int, limit: Int, operation: @escaping @Sendable (Int) async throws -> Void)
    async throws
  {
    guard count > 0 else { return }
    try await withThrowingTaskGroup(of: Void.self) { group in
      var next = 0
      for _ in 0..<min(count, clamped(limit)) {
        let index = next
        next += 1
        group.addTask {
          try Task.checkCancellation()
          try await operation(index)
        }
      }
      do {
        while try await group.next() != nil {
          try Task.checkCancellation()
          if next < count {
            let index = next
            next += 1
            group.addTask {
              try Task.checkCancellation()
              try await operation(index)
            }
          }
        }
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }
}

struct ActiveTransfer: Identifiable, Sendable {
  let id: UUID
  var revision: UUID
  var filename: String
  var stage: SyncStage
  var downloadProgress = 0.0
  var uploadProgress = 0.0
  var bytesText = ""
  var speedText = ""
  var waitingForNetwork = false
}
