import XCTest

@testable import SynologyPhotoSync

final class SecurityAndStorageTests: XCTestCase {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testURLRequiresHTTPSAndRejectsEmbeddedCredentials() {
    let client = SynologyAPIClient(persistSessions: false)
    for bad in [
      "", "https://", "http://nas.local", "ftp://nas.local", "https://a:b@nas.local",
      "https://nas.local?q=secret", "https://nas.local#fragment", "https://nas.local:0",
      "https://nas.local:99999",
    ] {
      XCTAssertNil(client.buildURL(baseURL: bad, endpoint: "webapi/auth.cgi"), bad)
    }
    XCTAssertEqual(
      client.buildURL(baseURL: " nas.local:5001/proxy/ ", endpoint: "/webapi/auth.cgi")?
        .absoluteString,
      "https://nas.local:5001/proxy/webapi/auth.cgi")
  }

  func testFormEscapesPasswordAndUnicode() {
    let data = SynologyAPIClient.formBody([("passwd", "a+b&c=d% пароль"), ("otp_code", "001234")])
    let form = String(decoding: data, as: UTF8.self)
    XCTAssertTrue(form.hasPrefix("passwd=a%2Bb%26c%3Dd%25%20"))
    XCTAssertTrue(form.hasSuffix("&otp_code=001234"))
    XCTAssertFalse(form.contains("пароль"))
  }

  func testResponseRejectsFalseSuccessAndInvalidJSON() throws {
    XCTAssertThrowsError(
      try SynologyAPIClient.decodeResponse(
        SynologyUploadData.self, data: Data("<html>proxy</html>".utf8)))
    XCTAssertThrowsError(
      try SynologyAPIClient.decodeResponse(
        SynologyUploadData.self, data: Data(#"{"success":false,"error":{"code":120}}"#.utf8)))
    XCTAssertThrowsError(
      try SynologyAPIClient.decodeResponse(
        SynologyUploadData.self, data: Data(#"{"success":true}"#.utf8)))
    let value = try SynologyAPIClient.decodeResponse(
      SynologyUploadData.self, data: Data(#"{"success":true,"data":{"item_id":42}}"#.utf8))
    XCTAssertEqual(value.effectiveId, 42)
  }

  func testFilenameCannotInjectHeadersOrPaths() {
    for name in ["../a\r\nInjected: yes.JPG", "\\bad/\"file\u{0}.MOV", "😀.HEIC", ".", ""] {
      let result = FilenameSanitizer.sanitize(name)
      XCTAssertFalse(result.isEmpty)
      XCTAssertFalse(
        result.contains(where: {
          $0 == "\r" || $0 == "\n" || $0 == "\u{0}" || $0 == "/" || $0 == "\\" || $0 == "\""
        }))
      XCTAssertTrue(result.allSatisfy(\.isASCII))
    }
  }

  func testAssetNamesAreStableDistinctAndPreserveLivePair() {
    let name = FilenameSanitizer.assetFilename("IMG_0001.HEIC", identifier: "asset/a")
    XCTAssertEqual(name, FilenameSanitizer.assetFilename("IMG_0001.HEIC", identifier: "asset/a"))
    XCTAssertNotEqual(name, FilenameSanitizer.assetFilename("IMG_0001.HEIC", identifier: "asset/b"))
    let video = FilenameSanitizer.assetFilename("IMG_0001.MOV", identifier: "asset/a")
    XCTAssertEqual(
      (name as NSString).deletingPathExtension, (video as NSString).deletingPathExtension)
    let long = FilenameSanitizer.assetFilename(
      String(repeating: "Ж", count: 500) + ".HEIC", identifier: "asset/a")
    XCTAssertEqual(long, FilenameSanitizer.sanitize(long))
    XCTAssertLessThan(long.utf8.count, 255)
  }

  func testMultipartPreservesBinaryAndUsesPrivateFile() throws {
    let folder = try temporaryDirectory()
    let source = folder.appendingPathComponent("original.bin")
    // Crosses multiple 1 MiB read boundaries and contains every byte value.
    let original = Data((0..<(2 * 1024 * 1024 + 17)).map { UInt8($0 % 256) })
    try original.write(to: source)
    let (bodyURL, boundary) = try StreamingMultipartUploader.makeMultipart(
      parameters: [("api", "upload"), ("_sid", "secret")], fileURL: source,
      filename: "a\r\nInjected.jpg")
    defer { try? FileManager.default.removeItem(at: bodyURL) }
    let body = try Data(contentsOf: bodyURL)
    let headerEnd = try XCTUnwrap(body.range(of: Data("Content-Type: image/jpeg\r\n\r\n".utf8)))
    XCTAssertEqual(body[headerEnd.upperBound..<(headerEnd.upperBound + original.count)], original)
    XCTAssertTrue(
      body.suffix(Data("\r\n--\(boundary)--\r\n".utf8).count).elementsEqual(
        Data("\r\n--\(boundary)--\r\n".utf8)))
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: bodyURL.path)[.posixPermissions]
        as? NSNumber)?.intValue, 0o600)
  }

  func testMultipartRejectsHeaderInjectionInFieldName() throws {
    let folder = try temporaryDirectory()
    let source = folder.appendingPathComponent("x")
    try Data([0]).write(to: source)
    XCTAssertThrowsError(
      try StreamingMultipartUploader.makeMultipart(
        parameters: [("x\r\nInjected", "value")], fileURL: source, filename: "x"))
  }

  func testDatabaseRoundTripAndFailureRecovery() throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let db = SyncDatabase(fileURL: file)
    db.recordFailure(appleId: "a", filename: "a.jpg", errorMessage: "first")
    db.recordFailure(appleId: "a", filename: "a.jpg", errorMessage: "latest")
    XCTAssertEqual(db.getFailedItems().first?.errorMessage, "latest")
    XCTAssertEqual(db.getFailedItems().first?.retryCount, 2)
    try db.recordAssetSynced(
      appleId: "a", synologyId: 5, filename: "a.jpg", type: .photo, sizeBytes: 10)
    let loaded = SyncDatabase(fileURL: file)
    XCTAssertEqual(loaded.synologyItemId(for: "a"), 5)
    XCTAssertTrue(loaded.getFailedItems().isEmpty)
    XCTAssertTrue(loaded.getRecentHistory(limit: -1).isEmpty)
    XCTAssertThrowsError(
      try loaded.recordAssetSynced(
        appleId: "invalid", synologyId: 0, filename: "x", type: .photo, sizeBytes: 0))
    XCTAssertFalse(loaded.isAssetSynced(appleId: "invalid"))
  }

  func testSuccessfulAlbumRetryClearsPreviousFailure() throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let db = SyncDatabase(fileURL: file)
    db.recordFailure(appleId: "album", filename: "Album", errorMessage: "offline")
    try db.recordAlbumSynced(appleAlbumId: "album", synologyAlbumId: 7, title: "Album")
    XCTAssertTrue(SyncDatabase(fileURL: file).getFailedItems().isEmpty)
  }

  func testDatabaseDoesNotOverwriteCorruption() throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let broken = Data("corrupt existing mapping".utf8)
    try broken.write(to: file)
    let db = SyncDatabase(fileURL: file)
    XCTAssertThrowsError(
      try db.recordAssetSynced(
        appleId: "a", synologyId: 4, filename: "a", type: .photo, sizeBytes: 0))
    XCTAssertFalse(db.isAssetSynced(appleId: "a"))
    XCTAssertEqual(try Data(contentsOf: file), broken)
  }

  func testDatabaseRollsBackWhenDiskWriteFails() throws {
    let folder = try temporaryDirectory()
    let blocker = folder.appendingPathComponent("not-a-directory")
    try Data([1]).write(to: blocker)
    let db = SyncDatabase(fileURL: blocker.appendingPathComponent("state.json"))
    XCTAssertThrowsError(
      try db.recordAssetSynced(
        appleId: "a", synologyId: 7, filename: "a", type: .photo, sizeBytes: 0))
    XCTAssertFalse(db.isAssetSynced(appleId: "a"))
  }

  func testDestinationIsolation() throws {
    let db = SyncDatabase(fileURL: try temporaryDirectory().appendingPathComponent("legacy.json"))
    func select(_ server: String, _ user: String, _ target: TargetSpace, _ live: Bool = true) throws
    {
      try db.selectDestination(
        server: server, username: user, target: target, livePhotos: live, editedCopies: false)
    }
    try select("https://one", "user", .personal)
    try db.recordAssetSynced(appleId: "a", synologyId: 9, filename: "a", type: .photo, sizeBytes: 0)
    for (server, user, target, live) in [
      ("https://two", "user", TargetSpace.personal, true),
      ("https://one", "other", .personal, true), ("https://one", "user", .shared, true),
      ("https://one", "user", .personal, false),
    ] {
      try select(server, user, target, live)
      XCTAssertFalse(db.isAssetSynced(appleId: "a"))
    }
    try select("https://one", "user", .personal)
    XCTAssertEqual(db.synologyItemId(for: "a"), 9)
  }

  @MainActor func testPauseKeepsCurrentStageAndResumesIt() throws {
    let db = SyncDatabase(fileURL: try temporaryDirectory().appendingPathComponent("state.json"))
    let state = SyncState(database: db)
    state.startNewSession(totalFiles: 1, totalAlbums: 0)
    state.setCurrentFile(name: "a", stage: .downloadingFromICloud)
    state.togglePause()
    XCTAssertEqual(state.currentStage, .paused)
    state.setCurrentFile(name: "a", stage: .uploadingToSynology)
    XCTAssertEqual(state.currentStage, .paused)
    state.togglePause()
    XCTAssertEqual(state.currentStage, .uploadingToSynology)
  }

  @MainActor func testSessionProgressIgnoresHistoricalErrorsAndAlbums() throws {
    let db = SyncDatabase(fileURL: try temporaryDirectory().appendingPathComponent("state.json"))
    db.recordFailure(appleId: "old", filename: "old", errorMessage: "old error")
    let state = SyncState(database: db)
    state.startNewSession(totalFiles: 2, totalAlbums: 1)
    XCTAssertEqual(state.remainingCount, 2)
    let error = SyncErrorItem(
      assetIdentifier: "album", filename: "album", errorMessage: "error", timestamp: Date())
    state.markFileFailed(errorItem: error, isAlbum: true)
    XCTAssertEqual(state.remainingCount, 2)
    state.finishSession()
    XCTAssertEqual(state.currentStage, .error)
    state.startNewSession(totalFiles: 0, totalAlbums: 0)
    state.finishSession(cancelled: true)
    XCTAssertEqual(state.currentStage, .cancelled)
    XCTAssertFalse(state.isPaused)
  }
}
