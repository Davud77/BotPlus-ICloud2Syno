import XCTest

@testable import SynologyPhotoSync

private final class MockProtocol: URLProtocol, @unchecked Sendable {
  private final class Storage: @unchecked Sendable {
    let lock = NSLock()
    var handler: ((URLRequest) throws -> (Int, String))?
  }
  private static let storage = Storage()
  static var handler: ((URLRequest) throws -> (Int, String))? {
    get {
      storage.lock.lock()
      defer { storage.lock.unlock() }
      return storage.handler
    }
    set {
      storage.lock.lock()
      defer { storage.lock.unlock() }
      storage.handler = newValue
    }
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let handler = Self.handler
      let (code, body) = try XCTUnwrap(handler)(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: code, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

final class NetworkTests: XCTestCase {
  override func tearDown() {
    MockProtocol.handler = nil
    super.tearDown()
  }

  private func client(handler: @escaping (URLRequest) throws -> (Int, String)) -> SynologyAPIClient
  {
    MockProtocol.handler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    return SynologyAPIClient(
      configuration: config, persistSessions: false,
      credentials: {
        ("https://nas.example", "test-user", "test-password")
      })
  }

  func testConcurrentOperationsShareOneLogin() async throws {
    let lock = NSLock()
    var logins = 0
    let api = client { request in
      lock.lock()
      defer { lock.unlock() }
      if request.url!.path.hasSuffix("auth.cgi") {
        logins += 1
        Thread.sleep(forTimeInterval: 0.02)
        return (200, #"{"success":true,"data":{"sid":"shared-sid"}}"#)
      }
      return (200, #"{"success":true,"data":{"list":[]}}"#)
    }
    try await BoundedTransferQueue.run(count: 16, limit: 8) { _ in
      try await api.validateAccess(targetSpace: .personal, allowInsecureSSL: false)
    }
    XCTAssertEqual(logins, 1)
  }

  func testConcurrentExpiredSIDRefreshesOnceAndLateFailuresReuseNewSID() async throws {
    let lock = NSLock()
    var logins = 0
    let api = client { request in
      lock.lock()
      defer { lock.unlock() }
      if request.url!.path.hasSuffix("auth.cgi") {
        logins += 1
        Thread.sleep(forTimeInterval: 0.02)
        return (
          200,
          logins == 1
            ? #"{"success":true,"data":{"sid":"expired"}}"#
            : #"{"success":true,"data":{"sid":"fresh"}}"#
        )
      }
      if request.value(forHTTPHeaderField: "Cookie") == "id=expired" {
        return (200, #"{"success":false,"error":{"code":119}}"#)
      }
      return (200, #"{"success":true,"data":{"list":[]}}"#)
    }
    try await BoundedTransferQueue.run(count: 16, limit: 8) { _ in
      try await api.validateAccess(targetSpace: .personal, allowInsecureSSL: false)
    }
    XCTAssertEqual(logins, 2)
  }

  func testConnectionUsesPOSTAndDoesNotPutSecretsInURL() async throws {
    var paths: [String] = []
    let api = client { request in
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertNil(request.url?.query)
      paths.append(request.url!.path)
      if request.url!.path.hasSuffix("auth.cgi") {
        return (200, #"{"success":true,"data":{"sid":"mock-sid"}}"#)
      }
      return (200, #"{"success":true,"data":{"list":[],"total":0}}"#)
    }
    let result = try await api.testConnection(
      serverURL: "https://nas.example", username: "test-user", password: "secret+&")
    XCTAssertEqual(result.serverName, "nas.example")
    XCTAssertEqual(paths, ["/webapi/auth.cgi", "/webapi/entry.cgi"])
  }

  func testInterruptedAPIRequestRecoversWithoutReplacingSession() async throws {
    var logins = 0
    var requests = 0
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        logins += 1
        return (200, #"{"success":true,"data":{"sid":"same-session"}}"#)
      }
      requests += 1
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=same-session")
      if requests == 1 { throw URLError(.networkConnectionLost) }
      if requests > 2 { return (200, #"{"success":true,"data":{"list":[],"total":1}}"#) }
      return (200, #"{"success":true,"data":{"list":[{"id":8,"name":"Recovered"}],"total":1}}"#)
    }
    let albums = try await TransferRetry.run(
      checkpoint: {}, wait: { _, _ in }, onRetry: { _, _ in },
      operation: {
        try await api.listAlbums(allowInsecureSSL: false)
      })
    XCTAssertEqual(albums.map(\.id), [8])
    XCTAssertEqual(logins, 1)
    XCTAssertEqual(requests, 2)  // The declared total completes the successful album page.
  }

  func testConnectionRejectsPhotosAPIFailure() async {
    let api = client { request in
      request.url!.path.hasSuffix("auth.cgi")
        ? (200, #"{"success":true,"data":{"sid":"sid"}}"#)
        : (200, #"{"success":false,"error":{"code":102}}"#)
    }
    do {
      _ = try await api.testConnection(
        serverURL: "https://nas.example", username: "user", password: "password")
      XCTFail("Unavailable Photos API must not pass connection testing")
    } catch {}
  }

  func testSessionExpiryRetriesOnceAndStops() async {
    var logins = 0
    var attempts = 0
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        logins += 1
        return (200, #"{"success":true,"data":{"sid":"sid"}}"#)
      }
      attempts += 1
      return (200, #"{"success":false,"error":{"code":119}}"#)
    }
    do {
      _ = try await api.listAlbums(allowInsecureSSL: false)
      XCTFail("Repeated session expiry must fail")
    } catch {
      guard case SynologyError.sessionExpired = error else {
        return XCTFail("Wrong error: \(error)")
      }
    }
    XCTAssertEqual(logins, 2)
    XCTAssertEqual(attempts, 2)
  }

  func testSessionRefreshRecovers() async throws {
    var attempts = 0
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        return (200, #"{"success":true,"data":{"sid":"sid"}}"#)
      }
      attempts += 1
      if attempts == 1 { return (200, #"{"success":false,"error":{"code":106}}"#) }
      return (200, #"{"success":true,"data":{"list":[{"id":5,"name":"Album"}],"total":1}}"#)
    }
    let albums = try await api.listAlbums(allowInsecureSSL: false)
    XCTAssertEqual(albums.map(\.id), [5])
    XCTAssertEqual(attempts, 2)
  }

  func testAddItemsRejectsHTMLAndHTTPFailure() async {
    for response in [(200, "<html>proxy login</html>"), (503, #"{"success":true}"#)] {
      let api = client { request in
        request.url!.path.hasSuffix("auth.cgi")
          ? (200, #"{"success":true,"data":{"sid":"sid"}}"#) : response
      }
      do {
        try await api.addItemsToAlbum(albumId: 1, itemIds: [1, 2], allowInsecureSSL: false)
        XCTFail("Invalid API response must fail")
      } catch {}
    }
  }

  func testAddItemsAcceptsEmptySuccessData() async throws {
    let api = client { request in
      request.url!.path.hasSuffix("auth.cgi")
        ? (200, #"{"success":true,"data":{"sid":"sid"}}"#) : (200, #"{"success":true}"#)
    }
    try await api.addItemsToAlbum(albumId: 1, itemIds: [1, 2], allowInsecureSSL: false)
  }

  func testUploadNeverRecordsMissingIDOrParameterErrorAsSuccess() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([0, 1, 255]).write(to: file)
    for body in [
      #"{"success":false,"error":{"code":120}}"#, #"{"success":true,"data":{}}"#,
      #"{"success":true,"data":{"id":0}}"#,
    ] {
      let api = client { request in
        request.url!.path.hasSuffix("auth.cgi")
          ? (200, #"{"success":true,"data":{"sid":"sid"}}"#) : (200, body)
      }
      do {
        _ = try await api.uploadItem(
          fileURL: file, filename: "a.jpg", creationDate: Date(), targetSpace: .personal,
          allowInsecureSSL: false
        ) { _ in }
        XCTFail("Unconfirmed upload must fail: \(body)")
      } catch {}
    }
  }

  func testUploadReturnsConfirmedID() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([0, 1, 255]).write(to: file)
    let api = client { request in
      XCTAssertNil(request.url?.query)
      if !request.url!.path.hasSuffix("auth.cgi") {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=sid")
      }
      return request.url!.path.hasSuffix("auth.cgi")
        ? (200, #"{"success":true,"data":{"sid":"sid"}}"#)
        : (200, #"{"success":true,"data":{"item_id":123}}"#)
    }
    let id = try await api.uploadItem(
      fileURL: file, filename: "a.jpg", creationDate: Date(), targetSpace: .personal,
      allowInsecureSSL: false
    ) { _ in }
    XCTAssertEqual(id, 123)
  }

  func testAlbumPaginationDoesNotStopAtFirstPage() async throws {
    var pages = 0
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        return (200, #"{"success":true,"data":{"sid":"sid"}}"#)
      }
      pages += 1
      let ids = pages == 1 ? Array(1...500) : [501]
      let list = ids.map { ["id": $0, "name": "Album \($0)"] as [String: Any] }
      let body = try JSONSerialization.data(withJSONObject: [
        "success": true, "data": ["list": list, "total": 501],
      ])
      return (200, String(decoding: body, as: UTF8.self))
    }
    let albums = try await api.listAlbums(allowInsecureSSL: false)
    XCTAssertEqual(albums.count, 501)
    XCTAssertEqual(pages, 2)
  }

  func testRepeatedAlbumPageFailsInsteadOfLooping() async throws {
    var pages = 0
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        return (200, #"{"success":true,"data":{"sid":"sid"}}"#)
      }
      pages += 1
      let list = (1...500).map { ["id": $0, "name": "Album \($0)"] as [String: Any] }
      let body = try JSONSerialization.data(withJSONObject: [
        "success": true, "data": ["list": list, "total": 1000],
      ])
      return (200, String(decoding: body, as: UTF8.self))
    }
    do {
      _ = try await api.listAlbums(allowInsecureSSL: false)
      XCTFail("Repeated pages must not be accepted")
    } catch {}
    XCTAssertEqual(pages, 2)
  }

  func testRedirectDoesNotForwardCredentials() {
    let delegate = APISessionDelegate(allowInsecureSSL: false)
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: URL(string: "https://nas.example")!)
    let redirect = HTTPURLResponse(
      url: URL(string: "https://nas.example")!, statusCode: 307, httpVersion: nil, headerFields: nil
    )!
    let otherServer = URLRequest(url: URL(string: "https://other.example")!)
    var called = false
    delegate.urlSession(
      session, task: task, willPerformHTTPRedirection: redirect, newRequest: otherServer
    ) { request in
      called = true
      XCTAssertNil(request)
    }
    XCTAssertTrue(called)
  }

  func testMultipartParametersMatchRealSynologyJSONContract() throws {
    let fields = try SynologyAPIClient.uploadParameters(
      filename: "IMG_001.JPG", creationDate: Date(timeIntervalSince1970: 1234),
      targetSpace: .personal)
    let parameters = Dictionary(uniqueKeysWithValues: fields)
    XCTAssertEqual(parameters["name"], "\"IMG_001.jpg\"")
    XCTAssertEqual(parameters["duplicate"], "\"ignore\"")
    XCTAssertEqual(parameters["mtime"], "1234")
    XCTAssertNil(
      parameters["_sid"], "DSM authenticates multipart before parsing fields; use the Cookie header"
    )
  }

  func testSessionCookieRejectsHeaderAndCookieInjection() throws {
    XCTAssertEqual(try SynologyAPIClient.sessionCookie("abc_123-xyz="), "id=abc_123-xyz=")
    for bad in ["", "sid; other=evil", "sid\r\nInjected: evil", "sid,other", "сид"] {
      XCTAssertThrowsError(try SynologyAPIClient.sessionCookie(bad))
    }
  }

  func testParameterRejectionReportsActualField() {
    do {
      let _: SynologyUploadData = try SynologyAPIClient.decodeResponse(
        SynologyUploadData.self,
        data: Data(
          #"{"success":false,"error":{"code":120,"errors":{"name":"duplicate","reason":"condition"}}}"#
            .utf8))
      XCTFail("Invalid parameters must fail")
    } catch SynologyError.invalidParameters(let field, let reason) {
      XCTAssertEqual(field, "duplicate")
      XCTAssertEqual(reason, "condition")
    } catch { XCTFail("Wrong error: \(error)") }
  }

  private func fields(_ request: URLRequest) -> [String: String] {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(contentsOf: buffer.prefix(count))
      }
    }
    var parts = URLComponents()
    parts.percentEncodedQuery = String(decoding: body, as: UTF8.self)
    return Dictionary(
      (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { _, last in last })
  }

  func testInventoryTraversesNestedFoldersAndAllShortPages() async throws {
    var itemRequests = 0
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        return (200, #"{"success":true,"data":{"sid":"sid"}}"#)
      }
      XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=sid")
      let f = self.fields(request)
      let offset = Int(f["offset"] ?? "0")!
      if f["api"] == "SYNO.Foto.Browse.Folder" {
        if f["id"] == "0" && offset == 0 {
          return (200, #"{"success":true,"data":{"list":[{"id":1},{"id":2}]}}"#)
        }
        if f["id"] == "1" && offset == 0 {
          return (200, #"{"success":true,"data":{"list":[{"id":2}]}}"#)
        }
        return (200, #"{"success":true,"data":{"list":[]}}"#)
      }
      XCTAssertEqual(f["api"], "SYNO.Foto.Browse.Item")
      XCTAssertNotEqual(f["folder_id"], "0", "The virtual root is not a real media folder")
      itemRequests += 1
      let ids = f["folder_id"] == "1" ? [11, 12] : [21]
      if offset < ids.count {
        return (
          200,
          "{\"success\":true,\"data\":{\"list\":[{\"id\":\(ids[offset]),\"filename\":\"file\(ids[offset]).jpg\",\"filesize\":69,\"time\":1,\"type\":\"photo\"}]}}"
        )
      }
      return (200, #"{"success":true,"data":{"list":[]}}"#)
    }
    let items = try await api.listMedia(targetSpace: .personal, allowInsecureSSL: false)
    XCTAssertEqual(Set(items.map(\.id)), [11, 12, 21])
    XCTAssertEqual(itemRequests, 5)
  }

  func testInventoryFailureDoesNotReturnPartialSuccess() async {
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        return (200, #"{"success":true,"data":{"sid":"sid"}}"#)
      }
      let f = self.fields(request)
      if f["api"] == "SYNO.Foto.Browse.Folder" {
        if f["id"] == "0" && f["offset"] == "0" {
          return (200, #"{"success":true,"data":{"list":[{"id":1}]}}"#)
        }
        return (200, #"{"success":true,"data":{"list":[]}}"#)
      }
      if f["offset"] == "0" {
        return (
          200,
          #"{"success":true,"data":{"list":[{"id":1,"filename":"x.jpg","filesize":1,"time":1,"type":"photo"}]}}"#
        )
      }
      return (503, "unavailable")
    }
    do {
      _ = try await api.listMedia(targetSpace: .personal, allowInsecureSSL: false)
      XCTFail("A failed catalog must never be accepted")
    } catch {}
  }

  func testInvalidInventoryIDsAreRejected() async {
    var mediaRequests = 0
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        return (200, #"{"success":true,"data":{"sid":"sid"}}"#)
      }
      let f = self.fields(request)
      if f["api"] == "SYNO.Foto.Browse.Folder" {
        if f["id"] == "0" && f["offset"] == "0" {
          return (200, #"{"success":true,"data":{"list":[{"id":1}]}}"#)
        }
        return (200, #"{"success":true,"data":{"list":[]}}"#)
      }
      mediaRequests += 1
      if mediaRequests == 1 {
        return (
          200,
          #"{"success":true,"data":{"list":[{"id":-1,"filename":"x.jpg","filesize":1,"time":1,"type":"photo"}]}}"#
        )
      }
      return (200, #"{"success":true,"data":{"list":[]}}"#)
    }
    do {
      _ = try await api.listMedia(targetSpace: .personal, allowInsecureSSL: false)
      XCTFail("Invalid IDs must not be accepted")
    } catch {}
  }

  func testInventoryUsesSeparateSharedNamespace() async throws {
    let api = client { request in
      if request.url!.path.hasSuffix("auth.cgi") {
        return (200, #"{"success":true,"data":{"sid":"sid"}}"#)
      }
      XCTAssertEqual(self.fields(request)["api"], "SYNO.FotoTeam.Browse.Folder")
      return (200, #"{"success":true,"data":{"list":[]}}"#)
    }
    let items = try await api.listMedia(targetSpace: .shared, allowInsecureSSL: false)
    XCTAssertTrue(items.isEmpty)
  }

  func testCancelledOperationDoesNotReachNetwork() async {
    let api = client { _ in
      XCTFail("Cancelled operation reached network")
      return (500, "")
    }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await api.listAlbums(allowInsecureSSL: false)
    }
    do {
      _ = try await task.value
      XCTFail("Cancellation was ignored")
    } catch {}
  }
}
