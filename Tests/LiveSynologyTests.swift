import XCTest

@testable import SynologyPhotoSync

/// Explicit opt-in only. Credentials are supplied by the runner, never stored in source or Keychain.
final class LiveSynologyTests: XCTestCase {
  func testRealFullInventoryReadOnly() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["SYNOPHOTOS_LIVE_FULL_SCAN"] == "1", let server = env["SYNOPHOTOS_LIVE_URL"],
      let username = env["SYNOPHOTOS_LIVE_USER"], let password = env["SYNOPHOTOS_LIVE_PASSWORD"]
    else {
      throw XCTSkip("Full NAS inventory requires explicit opt-in")
    }
    let api = SynologyAPIClient(
      persistSessions: false, credentials: { (server, username, password) })
    let sid = try await api.login(serverURL: server, username: username, password: password)
    let started = Date()
    do {
      let items = try await api.listMedia(
        targetSpace: .personal, allowInsecureSSL: false,
        progress: { files, folders in
          if folders > 0 && folders % 100 == 0 {
            print("NAS_SCAN_PROGRESS files=\(files) folders=\(folders)")
          }
        })
      XCTAssertEqual(items.count, Set(items.map(\.id)).count)
      XCTAssertTrue(items.allSatisfy { $0.id > 0 && $0.filesize >= 0 })
      print(
        "NAS_SCAN_RESULT files=\(items.count) seconds=\(Int(Date().timeIntervalSince(started)))")
    } catch {
      try await logout(server: server, sid: sid)
      throw error
    }
    try await logout(server: server, sid: sid)
  }

  private func logout(server: String, sid: String) async throws {
    var request = URLRequest(url: URL(string: server)!.appendingPathComponent("webapi/entry.cgi"))
    request.httpMethod = "POST"
    request.httpBody = SynologyAPIClient.formBody([
      ("api", "SYNO.API.Auth"), ("version", "6"), ("method", "logout"),
    ])
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue(try SynologyAPIClient.sessionCookie(sid), forHTTPHeaderField: "Cookie")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let (data, _) = try await session.data(for: request)
    let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(response["success"] as? Bool, true)
  }

  func testRealUploadDuplicateAndAlbum() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let server = env["SYNOPHOTOS_LIVE_URL"], let username = env["SYNOPHOTOS_LIVE_USER"],
      let password = env["SYNOPHOTOS_LIVE_PASSWORD"]
    else {
      throw XCTSkip("Real NAS tests require explicit credentials in the environment")
    }
    let api = SynologyAPIClient(
      persistSessions: false, credentials: { (server, username, password) })
    let sid = try await api.login(serverURL: server, username: username, password: password)
    let name = "APhotos2Syno-Diagnostic-\(UUID().uuidString).png"
    let albumName = "APhotos2Syno-Diagnostic-\(UUID().uuidString)"
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    // A small valid 1x1 PNG, unrelated to the user's media library.
    let png = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQz1sLAAICAUNEpakIAAAAAElFTkSuQmCC"
    )!
    try png.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    var uploadedID: Int?
    var albumID: Int?

    func request(_ fields: [(String, String)]) async throws -> [String: Any] {
      var request = URLRequest(url: URL(string: server)!.appendingPathComponent("webapi/entry.cgi"))
      request.httpMethod = "POST"
      request.httpBody = SynologyAPIClient.formBody(fields)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue(try SynologyAPIClient.sessionCookie(sid), forHTTPHeaderField: "Cookie")
      let session = URLSession(configuration: .ephemeral)
      defer { session.invalidateAndCancel() }
      let (data, _) = try await session.data(for: request)
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func cleanup() async throws {
      if let albumID {
        let albums = try await api.listAlbums(allowInsecureSSL: false)
        guard albums.contains(where: { $0.id == albumID && $0.name == albumName }) else {
          throw SynologyError.unexpectedResponse("Refusing to delete an unverified test album")
        }
        let response = try await request([
          ("api", "SYNO.Foto.Browse.Album"), ("version", "1"), ("method", "delete"),
          ("id", "[\(albumID)]"),
        ])
        XCTAssertEqual(response["success"] as? Bool, true, "Test album cleanup failed")
      }
      if let uploadedID {
        let response = try await request([
          ("api", "SYNO.Foto.Browse.Item"), ("version", "1"), ("method", "get"),
          ("id", "[\(uploadedID)]"),
        ])
        let items = (response["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        guard items.contains(where: { ($0["filename"] as? String) == name }) else {
          throw SynologyError.unexpectedResponse("Refusing to delete an unverified test image")
        }
        let deleted = try await request([
          ("api", "SYNO.Foto.Browse.Item"), ("version", "1"), ("method", "delete"),
          ("id", "[\(uploadedID)]"),
        ])
        XCTAssertEqual(deleted["success"] as? Bool, true, "Test image cleanup failed")
      }
      _ = try await request([("api", "SYNO.API.Auth"), ("version", "6"), ("method", "logout")])
    }

    do {
      _ = try await api.listAlbums(allowInsecureSSL: false)
      let id = try await api.uploadItem(
        fileURL: file, filename: name, creationDate: Date(), targetSpace: .personal,
        allowInsecureSSL: false
      ) { _ in }
      uploadedID = id
      XCTAssertGreaterThan(id, 0)
      let own = try await request([
        ("api", "SYNO.Foto.Browse.Item"), ("version", "1"), ("method", "get"), ("id", "[\(id)]"),
      ])
      let ownItems = (own["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
      let ownItem = try XCTUnwrap(ownItems.first(where: { $0["filename"] as? String == name }))
      let folderID = try XCTUnwrap(ownItem["folder_id"] as? Int)
      var catalog: [SynologyMediaItem] = []
      for _ in 0..<4 {
        catalog = try await api.listMedia(
          targetSpace: .personal, allowInsecureSSL: false, rootFolderID: folderID)
        if catalog.contains(where: { $0.id == id }) { break }
        try await Task.sleep(for: .milliseconds(500))
      }
      let foundItem = try XCTUnwrap(catalog.first(where: { $0.id == id && $0.filename == name }))
      XCTAssertEqual(foundItem.filesize, Int64(png.count))
      let fingerprint = try await api.originalFingerprint(
        itemID: id, targetSpace: .personal, allowInsecureSSL: false)
      XCTAssertEqual(
        fingerprint, try FileFingerprint.read(file),
        "The NAS original must match byte-for-byte before a legacy file is skipped")
      let duplicate = try await api.uploadItem(
        fileURL: file, filename: name, creationDate: Date(), targetSpace: .personal,
        allowInsecureSSL: false
      ) { _ in }
      XCTAssertEqual(duplicate, id, "Duplicate must resolve to the existing NAS object")
      let album = try await api.createAlbum(name: albumName, allowInsecureSSL: false)
      albumID = album
      try await api.addItemsToAlbum(albumId: album, itemIds: [id], allowInsecureSSL: false)
      let found = try await api.listAlbums(allowInsecureSSL: false)
      XCTAssertTrue(found.contains(where: { $0.id == album && $0.name == albumName }))
    } catch {
      do { try await cleanup() } catch {
        XCTFail("Diagnostic cleanup failed: \(error.localizedDescription)")
      }
      throw error
    }
    try await cleanup()
  }
}
