import XCTest

@testable import SynologyPhotoSync

@MainActor final class SessionLifecycleTests: XCTestCase {
  private func state(files: Int = 0, albums: Int = 0) -> SyncState {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let state = SyncState(
      database: SyncDatabase(fileURL: directory.appendingPathComponent("state.json")))
    state.startNewSession(totalFiles: files, totalAlbums: albums)
    return state
  }

  func testOnlyCleanFullyProcessedSessionCompletes() {
    let state = state(files: 1, albums: 1)
    state.markFileSuccess(
      historyItem: SyncHistoryItem(
        assetIdentifier: "a", filename: "a.jpg", type: .photo, synologyId: 1))
    state.markAlbumSkipped()
    state.finishSession()
    XCTAssertEqual(state.currentStage, .completed)
  }

  func testPausedFinalFileDoesNotCompleteUntilResume() {
    let state = state(files: 1)
    state.togglePause()
    state.markFileSuccess(
      historyItem: SyncHistoryItem(
        assetIdentifier: "a", filename: "a.jpg", type: .photo, synologyId: 1))
    state.finishSession()
    XCTAssertEqual(state.currentStage, .paused)
    XCTAssertTrue(state.isSyncing)
    state.togglePause()
    state.finishSession()
    XCTAssertEqual(state.currentStage, .completed)
  }

  func testCancellationIsImmediateAndSurvivesLateStageCallbacks() {
    let state = state(files: 1)
    state.requestCancellation()
    XCTAssertEqual(state.currentStage, .cancelling)
    state.setCurrentFile(name: "late", stage: .uploadingToSynology)
    XCTAssertEqual(state.currentStage, .cancelling)
    state.finishSession()
    XCTAssertEqual(state.currentStage, .cancelled)
    state.finishSession()
    XCTAssertEqual(state.currentStage, .cancelled)
    XCTAssertFalse(state.isSyncing)
  }

  func testCancellationWhilePausedIsNotSuccess() {
    let state = state()
    state.togglePause()
    state.finishSession(cancelled: true)
    XCTAssertEqual(state.currentStage, .cancelled)
    XCTAssertFalse(state.isPaused)
  }

  func testWarningPreventsCompletedEvenWhenAllFilesSucceeded() {
    let state = state()
    state.noteWarning()
    state.finishSession()
    XCTAssertEqual(state.currentStage, .attention)
    XCTAssertEqual(state.warningCount, 1)
  }

  func testUnprocessedFilesAndAlbumsPreventCompleted() {
    for state in [state(files: 1), state(albums: 1)] {
      state.finishSession()
      XCTAssertEqual(state.currentStage, .attention)
    }
  }

  func testFatalErrorPreventsCompleted() {
    let state = state()
    state.noteError()
    state.finishSession()
    XCTAssertEqual(state.currentStage, .error)
  }

  func testNewSessionClearsPreviousWarningAndCancellation() {
    let state = state()
    state.noteWarning()
    state.requestCancellation()
    state.finishSession()
    state.startNewSession(totalFiles: 0, totalAlbums: 0)
    state.finishSession()
    XCTAssertEqual(state.warningCount, 0)
    XCTAssertEqual(state.currentStage, .completed)
  }

  func testPersistentAuthAndParameterErrorsStopQueue() {
    XCTAssertTrue(SyncEngineActor.mustStopQueue(after: SynologyError.sessionExpired))
    XCTAssertTrue(
      SyncEngineActor.mustStopQueue(
        after: SynologyError.invalidParameters(field: "name", reason: "required")))
    XCTAssertTrue(SyncEngineActor.mustStopQueue(after: URLError(.notConnectedToInternet)))
    XCTAssertFalse(
      SyncEngineActor.mustStopQueue(
        after: SynologyError.uploadFailed(code: 422, message: "unsupported media")))
  }

  func testFatalFailureWhilePausedDoesNotLeaveAnEndedSessionStuck() {
    let state = state(files: 1)
    state.togglePause()
    state.noteError()
    state.finishSession()
    XCTAssertEqual(state.currentStage, .error)
    XCTAssertFalse(state.isSyncing)
    XCTAssertFalse(state.isPaused)
  }

  func testNetworkWaitCannotCompleteAndManualPauseRemainsInControl() {
    let state = state()
    state.setStage(.uploadingToSynology)
    state.beginNetworkWait()
    state.finishSession()
    XCTAssertTrue(state.isSyncing)
    XCTAssertEqual(state.currentStage, .waitingForNetwork)
    state.togglePause()
    state.endNetworkWait()
    XCTAssertEqual(state.currentStage, .paused)
    state.togglePause()
    XCTAssertEqual(state.currentStage, .uploadingToSynology)
  }

  func testNetworkCallbackAfterCancellationCannotRestoreActivity() {
    let state = state()
    state.beginNetworkWait()
    state.requestCancellation()
    state.endNetworkWait()
    XCTAssertEqual(state.currentStage, .cancelling)
    state.finishSession()
    state.beginNetworkWait()
    XCTAssertEqual(state.currentStage, .cancelled)
    XCTAssertFalse(state.isSyncing)
  }

  func testPauseGateSupportsTaskCancellation() async {
    let engine = SyncEngineActor()
    await engine.setPaused(true)
    let waiter = Task { try await engine.waitUntilReady() }
    waiter.cancel()
    do {
      try await waiter.value
      XCTFail("Cancelled pause waiter must throw")
    } catch {}
  }
}
