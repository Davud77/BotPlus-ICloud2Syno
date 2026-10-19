import CryptoKit
import XCTest

@testable import SynologyPhotoSync

final class RemoteInventoryTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testGeneratedIdentityRestoresMappingWithoutLocalCache() {
    let name = FilenameSanitizer.assetFilename("IMG_001.JPG", identifier: "unique-photo")
    let item = SynologyMediaItem(id: 7, filename: name, filesize: 40, time: 1, type: "photo")
    XCTAssertEqual(RemoteMediaInventory(items: [item]).knownItem(filename: name)?.id, 7)
    XCTAssertNil(RemoteMediaInventory(items: []).knownItem(filename: name, cachedID: 7))
  }

  func testReusedRemoteIDWithDifferentFilenameIsNotTrusted() {
    let item = SynologyMediaItem(
      id: 7, filename: "unrelated.jpg", filesize: 40, time: 1, type: "photo")
    XCTAssertNil(
      RemoteMediaInventory(items: [item]).knownItem(
        filename: "expected.jpg", cachedID: 7, originalFilename: "original.jpg"))
  }

  func testSameNameIsNotAutomaticallyRecognizedAsAnExistingAsset() {
    let item = SynologyMediaItem(
      id: 7, filename: "IMG_001.jpg", filesize: 40, time: 1, type: "photo")
    let inventory = RemoteMediaInventory(items: [item])
    XCTAssertNil(
      inventory.knownItem(
        filename: FilenameSanitizer.assetFilename("IMG_001.jpg", identifier: "new-photo")))
    XCTAssertEqual(inventory.legacyCandidates(originalFilename: "IMG_001.jpg").map(\.id), [7])
  }

  func testAmbiguousNamesRequireContentVerification() {
    let items = [1, 2].map {
      SynologyMediaItem(id: $0, filename: "same.jpg", filesize: 40, time: 1, type: "photo")
    }
    let inventory = RemoteMediaInventory(items: items)
    XCTAssertNil(inventory.knownItem(filename: "same.jpg"))
    XCTAssertEqual(inventory.legacyCandidates(originalFilename: "same.jpg").count, 2)
    XCTAssertEqual(inventory.knownItem(filename: "same.jpg", cachedID: 2)?.id, 2)
  }

  func testLegacyUnicodeAndTransliteratedNamesAreCandidates() {
    let original = "Без даты (12).JPG"
    let item = SynologyMediaItem(
      id: 5, filename: FilenameSanitizer.sanitize(original), filesize: 2, time: 1, type: "photo")
    XCTAssertEqual(
      RemoteMediaInventory(items: [item]).legacyCandidates(originalFilename: original).map(\.id),
      [5])
  }

  func testFingerprintsRejectDifferentBytesWithSameSize() throws {
    let folder = try directory()
    let left = folder.appendingPathComponent("a")
    let right = folder.appendingPathComponent("b")
    let data = Data((0..<(2 * 1024 * 1024 + 19)).map { UInt8($0 % 255) })
    try data.write(to: left)
    var changed = data
    changed[changed.count - 1] ^= 1
    try changed.write(to: right)
    let hash = try FileFingerprint.read(left)
    XCTAssertEqual(hash.size, Int64(data.count))
    XCTAssertEqual(hash.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    XCTAssertNotEqual(hash, try FileFingerprint.read(right))
  }

  func testReconciliationInvalidatesDeletedFilesAndPreservesUnselectedMappings() throws {
    let file = try directory().appendingPathComponent("state.json")
    let db = SyncDatabase(fileURL: file)
    for (key, id) in [("deleted", 1), ("present", 2), ("out-of-scope", 3)] {
      try db.recordAssetSynced(
        appleId: key, synologyId: id, filename: key, type: .photo, sizeBytes: 1)
    }
    db.recordFailure(appleId: "present", filename: "present", errorMessage: "old error")
    try db.reconcileAssets(
      selectedIDs: ["deleted", "present"], confirmed: ["present": 22],
      resources: ["present": ["a.heic": 22, "a.mov": 23]])
    let restored = SyncDatabase(fileURL: file)
    XCTAssertFalse(restored.isAssetSynced(appleId: "deleted"))
    XCTAssertEqual(restored.synologyItemId(for: "present"), 22)
    XCTAssertEqual(restored.synologyItemId(for: "out-of-scope"), 3)
    XCTAssertTrue(restored.getFailedItems().isEmpty)
    XCTAssertEqual(restored.resourceItemIDs(for: "present")["a.mov"], 23)
  }

  func testPartialLivePhotoRemainsUnsyncedButKeepsConfirmedPhotoID() throws {
    let db = SyncDatabase(fileURL: try directory().appendingPathComponent("state.json"))
    try db.reconcileAssets(
      selectedIDs: ["live"], confirmed: [:], resources: ["live": ["a.heic": 5]])
    XCTAssertFalse(db.isAssetSynced(appleId: "live"))
    XCTAssertEqual(db.resourceItemIDs(for: "live"), ["a.heic": 5])
  }

  func testPre12DatabaseMigratesWithoutDroppingMappings() throws {
    let file = try directory().appendingPathComponent("state.json")
    try Data(#"{"syncedAssets":{"old":7},"syncedAlbums":{},"history":[],"failedItems":[]}"#.utf8)
      .write(to: file)
    let db = SyncDatabase(fileURL: file)
    XCTAssertEqual(db.synologyItemId(for: "old"), 7)
    XCTAssertTrue(db.resourceItemIDs(for: "old").isEmpty)
    try db.reconcileAssets(selectedIDs: ["old"], confirmed: ["old": 7])
    XCTAssertEqual(SyncDatabase(fileURL: file).synologyItemId(for: "old"), 7)
  }

  func testIncompleteJSONDatabaseIsNotSilentlyReset() throws {
    let file = try directory().appendingPathComponent("state.json")
    try Data("{}".utf8).write(to: file)
    let db = SyncDatabase(fileURL: file)
    XCTAssertThrowsError(try db.reconcileAssets(selectedIDs: ["a"], confirmed: ["a": 1]))
    XCTAssertEqual(try String(contentsOf: file), "{}")
  }

  func testReconciliationFailureDoesNotMarkConfirmedAssetsInMemory() throws {
    let folder = try directory()
    let blockingFile = folder.appendingPathComponent("blocker")
    try Data([1]).write(to: blockingFile)
    let db = SyncDatabase(fileURL: blockingFile.appendingPathComponent("state.json"))
    XCTAssertThrowsError(try db.reconcileAssets(selectedIDs: ["a"], confirmed: ["a": 1]))
    XCTAssertFalse(db.isAssetSynced(appleId: "a"))
  }

  @MainActor func testCountersDistinguishExistingFilesAndNewUploads() throws {
    let state = SyncState(
      database: SyncDatabase(fileURL: try directory().appendingPathComponent("state.json")))
    state.startNewSession(totalFiles: 10, totalAlbums: 0)
    state.setStage(.checkingSynology)
    state.updateNASScan(files: 1000, folders: 40)
    state.setReconciliationSummary(total: 10, alreadyPresent: 9, toUpload: 1)
    XCTAssertEqual(state.alreadyPresentCount, 9)
    XCTAssertEqual(state.nasScannedFileCount, 1000)
    XCTAssertEqual(state.remainingCount, 1)
    XCTAssertEqual(state.syncedCount, 0)
    state.finishSession()
    XCTAssertEqual(state.currentStage, .attention)
  }
}
