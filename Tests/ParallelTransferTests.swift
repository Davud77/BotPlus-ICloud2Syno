import XCTest

@testable import SynologyPhotoSync

private actor PipelineProbe {
  var active = 0
  var peak = 0
  var completed: [Int] = []
  func process(_ index: Int, fail: Bool = false, delay: Duration = .milliseconds(10)) async throws {
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    try await Task.sleep(for: .milliseconds(10))  // iCloud extraction.
    if fail { throw URLError(.badServerResponse) }
    try await Task.sleep(for: .milliseconds(10))  // NAS upload.
    completed.append(index)
  }
  func snapshot() -> (Int, Int, [Int]) { (active, peak, completed) }
}

@MainActor
final class ParallelTransferTests: XCTestCase {
  func testPipelinesOverlapAndNeverExceedSelectedLimit() async throws {
    for limit in [1, 3, 8] {
      let probe = PipelineProbe()
      try await BoundedTransferQueue.run(count: 20, limit: limit) { try await probe.process($0) }
      let (active, peak, completed) = await probe.snapshot()
      XCTAssertEqual(active, 0)
      XCTAssertEqual(peak, limit)
      XCTAssertEqual(completed.sorted(), Array(0..<20))
    }
  }

  func testFatalFailureCancelsSiblingsAndDrainsCleanup() async {
    let probe = PipelineProbe()
    do {
      try await BoundedTransferQueue.run(count: 500, limit: 3) {
        try await probe.process($0, fail: true)
      }
      XCTFail("Fatal failure must stop the queue")
    } catch {}
    let (active, peak, completed) = await probe.snapshot()
    XCTAssertEqual(active, 0)
    XCTAssertLessThanOrEqual(peak, 3)
    XCTAssertTrue(completed.isEmpty)
  }

  func testCancelledQueueNeverStartsWaitingFiles() async {
    let probe = PipelineProbe()
    let task = Task {
      try await BoundedTransferQueue.run(count: 500, limit: 3) { try await probe.process($0) }
    }
    task.cancel()
    do {
      try await task.value
      XCTFail()
    } catch {}
    let (active, _, completed) = await probe.snapshot()
    XCTAssertEqual(active, 0)
    XCTAssertTrue(completed.isEmpty)
  }

  func testCancellationDrainsAlreadyRunningWorkers() async {
    let probe = PipelineProbe()
    let started = expectation(description: "bounded workers started")
    started.expectedFulfillmentCount = 3
    let task = Task {
      try await BoundedTransferQueue.run(count: 500, limit: 3) { index in
        started.fulfill()
        try await probe.process(index, delay: .seconds(30))
      }
    }
    await fulfillment(of: [started], timeout: 2)
    task.cancel()
    do {
      try await task.value
      XCTFail()
    } catch {}
    let (active, _, completed) = await probe.snapshot()
    XCTAssertEqual(active, 0)
    XCTAssertTrue(completed.isEmpty)
  }

  func testPauseGateBlocksAllWorkersUntilManualResume() async throws {
    let engine = SyncEngineActor()
    await engine.setPaused(true)
    let probe = PipelineProbe()
    let task = Task {
      try await BoundedTransferQueue.run(count: 6, limit: 3) { index in
        try await engine.waitUntilReady()
        try await probe.process(index)
      }
    }
    try await Task.sleep(for: .milliseconds(30))
    let before = await probe.snapshot()
    XCTAssertEqual(before.1, 0)
    await engine.setPaused(false)
    try await task.value
    let after = await probe.snapshot()
    XCTAssertEqual(after.2.count, 6)
  }

  func testParallelSettingPersistsAndClampsCorruptValues() throws {
    let name = "ParallelTransferTests-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let config = SyncConfig(defaults: defaults)
    XCTAssertEqual(config.parallelTransfers, 3)
    config.parallelTransfers = 5
    XCTAssertEqual(SyncConfig(defaults: defaults).parallelTransfers, 5)
    config.parallelTransfers = -50
    XCTAssertEqual(config.parallelTransfers, 1)
    defaults.set(500, forKey: "sync_parallel_transfers")
    XCTAssertEqual(config.parallelTransfers, 8)
  }

  private func state() -> SyncState {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let state = SyncState(database: SyncDatabase(fileURL: dir.appendingPathComponent("state.json")))
    state.startNewSession(totalFiles: 2, totalAlbums: 0)
    return state
  }

  func testProgressIsIsolatedAndLateCallbacksAreIgnored() {
    let state = state()
    let a = UUID()
    let b = UUID()
    let revisionA = UUID()
    let revisionB = UUID()
    state.beginTransfer(id: a, filename: "a.jpg")
    state.beginTransfer(id: b, filename: "b.jpg")
    state.setTransferFile(id: a, revision: revisionA, name: "a.jpg", stage: .downloadingFromICloud)
    state.setTransferFile(id: b, revision: revisionB, name: "b.jpg", stage: .downloadingFromICloud)
    state.updateTransfer(id: a, revision: revisionA, download: 0.25)
    state.updateTransfer(id: b, revision: revisionB, download: 0.75)
    XCTAssertEqual(state.activeTransfers.map(\.downloadProgress), [0.25, 0.75])
    state.setTransferFile(id: a, revision: UUID(), name: "a.mov", stage: .uploadingToSynology)
    state.updateTransfer(id: a, revision: revisionA, download: 0.9)
    XCTAssertEqual(state.activeTransfers[0].downloadProgress, 1)
    state.markFileSuccess(
      historyItem: SyncHistoryItem(
        assetIdentifier: "a", filename: "a.jpg", type: .photo, synologyId: 1))
    XCTAssertEqual(state.syncedCount, 1)
    state.endTransfer(id: a)
    state.updateTransfer(id: a, revision: revisionA, download: 0.9)
    XCTAssertEqual(state.activeTransfers.count, 1)
    XCTAssertEqual(state.currentFileName, "b.jpg")
    XCTAssertEqual(state.iCloudDownloadProgress, 0.75)
    state.requestCancellation()
    state.updateTransfer(id: b, revision: revisionB, download: 1)
    XCTAssertEqual(state.activeTransfers[0].downloadProgress, 0.75)
    state.endTransfer(id: b)
    state.finishSession(cancelled: true)
    XCTAssertEqual(state.currentStage, .cancelled)
    XCTAssertTrue(state.activeTransfers.isEmpty)
  }

  func testOneWorkerCannotClearAnotherWorkersNetworkWait() {
    let state = state()
    let a = UUID()
    let b = UUID()
    let operationA = UUID()
    let operationB = UUID()
    state.beginTransfer(id: a, filename: "a.jpg")
    state.beginTransfer(id: b, filename: "b.jpg")
    state.beginNetworkWait(operationID: operationA, transferID: a)
    state.beginNetworkWait(operationID: operationB, transferID: b)
    state.endNetworkWait(operationID: UUID())  // Another successful operation never waited.
    state.endNetworkWait(operationID: operationA)
    XCTAssertEqual(state.currentStage, .waitingForNetwork)
    XCTAssertFalse(state.activeTransfers[0].waitingForNetwork)
    XCTAssertTrue(state.activeTransfers[1].waitingForNetwork)
    state.togglePause()
    state.endNetworkWait(operationID: operationB)
    XCTAssertEqual(state.currentStage, .paused)
    state.togglePause()
    XCTAssertEqual(state.currentStage, .downloadingFromICloud)
  }
}
