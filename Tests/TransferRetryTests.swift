import Photos
import XCTest

@testable import SynologyPhotoSync

@MainActor
final class TransferRetryTests: XCTestCase {
  func testNetworkErrorsIncludePhotos3169AndNestedErrors() {
    XCTAssertTrue(TransferRetry.isNetworkFailure(NSError(domain: PHPhotosErrorDomain, code: 3169)))
    XCTAssertTrue(
      TransferRetry.isNetworkFailure(SynologyError.networkError(URLError(.networkConnectionLost))))
    XCTAssertTrue(
      TransferRetry.isNetworkFailure(
        NSError(
          domain: PHPhotosErrorDomain, code: -1,
          userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])))
    for error in [URLError(.cancelled), URLError(.serverCertificateUntrusted), URLError(.badURL)] {
      XCTAssertFalse(TransferRetry.isNetworkFailure(error))
    }
    XCTAssertFalse(TransferRetry.isNetworkFailure(SynologyError.invalidCredentials))
    XCTAssertFalse(TransferRetry.isNetworkFailure(NSError(domain: PHPhotosErrorDomain, code: 3303)))
  }

  func testNetworkRecoveryRetriesCurrentOperationWithoutSkippingIt() async throws {
    var attempts = 0
    var notifications = 0
    let value = try await TransferRetry.run(
      checkpoint: {},
      wait: { _, network in
        XCTAssertTrue(network)
      }, onRetry: { _, _ in notifications += 1 },
      operation: {
        attempts += 1
        if attempts < 4 { throw URLError(.networkConnectionLost) }
        return 42
      })
    XCTAssertEqual(value, 42)
    XCTAssertEqual(attempts, 4)
    XCTAssertEqual(notifications, 3)
  }

  func testInternalPhotoErrorHasOnlyTwoRetries() async {
    var attempts = 0
    do {
      let _: Int = try await TransferRetry.run(
        checkpoint: {}, wait: { _, _ in }, onRetry: { _, _ in },
        operation: {
          attempts += 1
          throw NSError(domain: PHPhotosErrorDomain, code: -1)
        })
      XCTFail("An unavailable resource must remain an error")
    } catch {
      XCTAssertEqual(attempts, 3)
      XCTAssertTrue(TransferRetry.message(for: error).contains("оригинал"))
    }
  }

  func testAuthenticationFailureIsNeverRetried() async {
    var attempts = 0
    do {
      let _: Int = try await TransferRetry.run(
        checkpoint: {}, wait: { _, _ in XCTFail() }, onRetry: { _, _ in XCTFail() },
        operation: {
          attempts += 1
          throw SynologyError.invalidCredentials
        })
      XCTFail()
    } catch { XCTAssertEqual(attempts, 1) }
  }

  func testCancellationDuringNetworkWaitPreventsAnyMoreRequests() async {
    let waiting = expectation(description: "waiting for connectivity")
    var attempts = 0
    let task = Task {
      try await TransferRetry.run(
        checkpoint: {},
        wait: { _, _ in
          waiting.fulfill()
          try await Task.sleep(for: .seconds(30))
        }, onRetry: { _, _ in },
        operation: {
          attempts += 1
          throw URLError(.notConnectedToInternet)
        })
    }
    await fulfillment(of: [waiting], timeout: 2)
    task.cancel()
    do {
      try await task.value
      XCTFail()
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(attempts, 1)
  }

  func testManualPauseBlocksRetryEvenWhenConnectivityReturns() async throws {
    let engine = SyncEngineActor()
    let waiting = expectation(description: "network recovered while paused")
    var attempts = 0
    let task = Task {
      try await TransferRetry.run(
        checkpoint: { try await engine.waitUntilReady() },
        wait: { _, _ in
          await engine.setPaused(true)
          waiting.fulfill()
        }, onRetry: { _, _ in },
        operation: {
          attempts += 1
          if attempts == 1 { throw URLError(.networkConnectionLost) }
          return 7
        })
    }
    await fulfillment(of: [waiting], timeout: 2)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(attempts, 1)
    await engine.setPaused(false)
    let result = try await task.value
    XCTAssertEqual(result, 7)
    XCTAssertEqual(attempts, 2)
  }

  func testCancellationWhileManuallyPausedDoesNotResumeOnNetworkRecovery() async {
    let engine = SyncEngineActor()
    await engine.setPaused(true)
    var attempts = 0
    let task = Task {
      try await TransferRetry.run(
        checkpoint: { try await engine.waitUntilReady() }, wait: { _, _ in }, onRetry: { _, _ in },
        operation: {
          attempts += 1
        })
    }
    task.cancel()
    await engine.setPaused(false)
    do {
      try await task.value
      XCTFail()
    } catch {}
    XCTAssertEqual(attempts, 0)
  }
}
