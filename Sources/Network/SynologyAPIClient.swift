import CryptoKit
import Foundation

/// Serializes session access and bounds authentication retries to one per operation.
public actor SynologyAPIClient {
  public static let shared = SynologyAPIClient()
  private let configuration: URLSessionConfiguration
  private let persistSessions: Bool
  private let credentials: @Sendable () -> (server: String, username: String, password: String?)
  private var requestSessions: [String: URLSession] = [:]
  private var sessions: [String: String] = [:]

  init(
    configuration: URLSessionConfiguration = .ephemeral, persistSessions: Bool = true,
    credentials: @escaping @Sendable () -> (server: String, username: String, password: String?) = {
      (SyncConfig.shared.serverURL, SyncConfig.shared.username, KeychainHelper.shared.getPassword())
    }
  ) {
    self.credentials = credentials
    self.configuration = configuration
    self.persistSessions = persistSessions
  }

  nonisolated public func buildURL(baseURL: String, endpoint: String) -> URL? {
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !base.contains("://") { base = "https://" + base }
    guard var parts = URLComponents(string: base),
      parts.scheme?.lowercased() == "https",
      let host = parts.host, !host.isEmpty,
      parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      parts.port == nil || (1...65535).contains(parts.port!),
      !endpoint.contains(".."), !endpoint.contains("?"), !endpoint.contains("#")
    else { return nil }
    parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    parts.path =
      "/"
      + ([parts.path, endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
        .filter { !$0.isEmpty }.joined(separator: "/"))
    return parts.url
  }

  private func sessionKey(server: String, username: String, insecure: Bool) throws -> String {
    guard let url = buildURL(baseURL: server, endpoint: "webapi/entry.cgi") else {
      throw SynologyError.invalidURL
    }
    let identity = "\(url.absoluteString)|\(username)|\(insecure)"
    return "session_"
      + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  deinit {
    for session in requestSessions.values { session.invalidateAndCancel() }
  }

  private func makeSession(insecure: Bool, upload: Bool = false) -> URLSession {
    let key = "\(insecure)-\(upload)"
    if let existing = requestSessions[key] { return existing }
    let config = configuration.copy() as! URLSessionConfiguration
    config.timeoutIntervalForRequest = upload ? 300 : 30
    config.timeoutIntervalForResource = upload ? 3600 : 60
    config.urlCache = nil
    config.httpCookieStorage = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(
      configuration: config, delegate: APISessionDelegate(allowInsecureSSL: insecure),
      delegateQueue: nil)
    requestSessions[key] = session
    return session
  }

  private func reportSessionRefresh() async {
    await MainActor.run {
      AppLogger.shared.warning("Сессия NAS отклонена. Выполняется одна повторная авторизация.")
    }
  }

  nonisolated static func sessionCookie(_ sid: String) throws -> String {
    guard !sid.isEmpty, sid.utf8.count <= 4096,
      sid.utf8.allSatisfy({
        $0 == 0x21 || (0x23...0x2B).contains($0) || (0x2D...0x3A).contains($0)
          || (0x3C...0x5B).contains($0) || (0x5D...0x7E).contains($0)
      })
    else {
      throw SynologyError.unexpectedResponse("Некорректный идентификатор сессии NAS")
    }
    return "id=" + sid
  }

  nonisolated static func jsonString(_ value: String) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
  }

  nonisolated static func uploadParameters(
    filename: String, creationDate: Date, targetSpace: TargetSpace
  ) throws -> [(String, String)] {
    let seconds = creationDate.timeIntervalSince1970
    guard seconds.isFinite else {
      throw SynologyError.unexpectedResponse("Некорректная дата файла")
    }
    let time = String(Int64(max(1, min(seconds, Double(Int64.max / 2)))))
    return [
      ("api", targetSpace.uploadApiPath), ("version", "1"), ("method", "upload"),
      ("name", try jsonString(FilenameSanitizer.sanitize(filename))),
      ("duplicate", try jsonString("ignore")),
      ("mtime", time), ("crtime", time),
    ]
  }

  nonisolated static func formBody(_ fields: [(String, String)]) -> Data {
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    return Data(
      fields.map { key, value in
        "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
      }.joined(separator: "&").utf8)
  }

  private func request<T: Decodable>(
    server: String, endpoint: String = "webapi/entry.cgi",
    fields: [(String, String)], insecure: Bool, sessionID: String? = nil
  ) async throws -> T {
    try Task.checkCancellation()
    guard let url = buildURL(baseURL: server, endpoint: endpoint) else {
      throw SynologyError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(
      "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formBody(fields)
    if let sessionID {
      request.setValue(try Self.sessionCookie(sessionID), forHTTPHeaderField: "Cookie")
    }
    let session = makeSession(insecure: insecure)
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw SynologyError.unexpectedResponse(
        "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    return try Self.decodeResponse(T.self, data: data)
  }

  nonisolated static func decodeResponse<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
    let result = try JSONDecoder().decode(SynologyAPIResponse<T>.self, from: data)
    guard result.success else {
      if result.error?.code == 120 {
        throw SynologyError.invalidParameters(
          field: result.error?.parameter?.name, reason: result.error?.parameter?.reason)
      }
      throw SynologyError.mapCode(result.error?.code ?? 100)
    }
    if T.self == EmptyAPIData.self, result.data == nil { return EmptyAPIData() as! T }
    guard let value = result.data else {
      throw SynologyError.unexpectedResponse("Отсутствуют данные результата")
    }
    return value
  }

  public func login(
    serverURL: String, username: String, password: String,
    otpCode: String? = nil, allowInsecureSSL: Bool = false
  ) async throws -> String {
    let key = try sessionKey(server: serverURL, username: username, insecure: allowInsecureSSL)
    sessions[key] = nil
    if persistSessions { KeychainHelper.shared.delete(key: key) }
    var fields = [
      ("api", "SYNO.API.Auth"), ("version", "6"), ("method", "login"),
      ("account", username), ("passwd", password), ("format", "sid"),
    ]
    if let otp = otpCode?.trimmingCharacters(in: .whitespacesAndNewlines), !otp.isEmpty {
      fields.append(("otp_code", otp))
    }
    let auth: SynologyAuthData = try await request(
      server: serverURL, endpoint: "webapi/auth.cgi", fields: fields, insecure: allowInsecureSSL)
    guard !auth.sid.isEmpty else {
      throw SynologyError.unexpectedResponse("Пустой идентификатор сессии")
    }
    if persistSessions { try KeychainHelper.shared.save(key: key, value: auth.sid) }
    sessions[key] = auth.sid
    return auth.sid
  }

  private func session(insecure: Bool, refresh: Bool = false) async throws -> String {
    let config = credentials()
    let key = try sessionKey(server: config.server, username: config.username, insecure: insecure)
    if !refresh,
      let sid = sessions[key] ?? (persistSessions ? KeychainHelper.shared.get(key: key) : nil)
    {
      return sid
    }
    guard let password = config.password, !password.isEmpty else {
      throw SynologyError.invalidCredentials
    }
    return try await login(
      serverURL: config.server, username: config.username, password: password,
      allowInsecureSSL: insecure)
  }

  private func authenticated<T: Decodable>(fields: [(String, String)], insecure: Bool) async throws
    -> T
  {
    for attempt in 0...1 {
      let sid = try await session(insecure: insecure, refresh: attempt > 0)
      do {
        return try await request(
          server: credentials().server, fields: fields, insecure: insecure, sessionID: sid)
      } catch SynologyError.sessionExpired where attempt == 0 {
        await reportSessionRefresh()
        continue
      }
    }
    throw SynologyError.sessionExpired
  }

  public func validateAccess(targetSpace: TargetSpace, allowInsecureSSL: Bool) async throws {
    let _: SynologyAlbumListData = try await authenticated(
      fields: [
        (
          "api",
          targetSpace == .shared
            ? "SYNO.FotoTeam.Browse.NormalAlbum" : "SYNO.Foto.Browse.NormalAlbum"
        ),
        ("version", "1"), ("method", "list"), ("offset", "0"), ("limit", "1"),
      ], insecure: allowInsecureSSL)
  }

  public func testConnection(
    serverURL: String, username: String, password: String,
    otpCode: String? = nil, allowInsecureSSL: Bool = false
  ) async throws -> (serverName: String, dsmVersion: String) {
    let sid = try await login(
      serverURL: serverURL, username: username, password: password, otpCode: otpCode,
      allowInsecureSSL: allowInsecureSSL)
    let _: SynologyAlbumListData = try await request(
      server: serverURL,
      fields: [
        ("api", "SYNO.Foto.Browse.NormalAlbum"), ("version", "1"), ("method", "list"),
        ("offset", "0"), ("limit", "1"),
      ], insecure: allowInsecureSSL, sessionID: sid)
    return (buildURL(baseURL: serverURL, endpoint: "")!.host!, "Synology Photos доступен")
  }

  public func uploadItem(
    fileURL: URL, filename: String, creationDate: Date, targetSpace: TargetSpace,
    allowInsecureSSL: Bool, progress: @escaping @Sendable (UploadProgressInfo) -> Void
  ) async throws -> Int {
    guard let url = buildURL(baseURL: credentials().server, endpoint: "webapi/entry.cgi") else {
      throw SynologyError.invalidURL
    }
    for attempt in 0...1 {
      let sid = try await session(insecure: allowInsecureSSL, refresh: attempt > 0)
      let fields = try Self.uploadParameters(
        filename: filename, creationDate: creationDate, targetSpace: targetSpace)
      let uploader = StreamingMultipartUploader()
      uploader.configuration = configuration
      uploader.sharedSession = makeSession(insecure: allowInsecureSSL, upload: true)
      let (data, response) = try await uploader.upload(
        url: url, parameters: fields, fileURL: fileURL,
        filename: filename, allowInsecureSSL: allowInsecureSSL, sessionID: sid, progress: progress)
      guard (200...299).contains(response.statusCode) else {
        throw SynologyError.uploadFailed(
          code: response.statusCode, message: "HTTP \(response.statusCode)")
      }
      do {
        let result = try Self.decodeResponse(SynologyUploadData.self, data: data)
        guard let id = result.effectiveId, id > 0 else {
          throw SynologyError.unexpectedResponse(
            "Сервер не подтвердил ID файла; запись не отмечена как синхронизированная")
        }
        return id
      } catch SynologyError.sessionExpired where attempt == 0 {
        await reportSessionRefresh()
        continue
      }
    }
    throw SynologyError.sessionExpired
  }

  /// Walks every actual folder; the virtual root (0) cannot be queried for items on DSM.
  func listMedia(
    targetSpace: TargetSpace, allowInsecureSSL: Bool,
    rootFolderID: Int = 0,
    progress: @Sendable (Int, Int) async -> Void = { _, _ in },
    checkpoint: @Sendable () async throws -> Void = {}
  ) async throws -> [SynologyMediaItem] {
    let prefix = targetSpace == .shared ? "SYNO.FotoTeam" : "SYNO.Foto"
    var pending = [rootFolderID]
    var visited = Set<Int>()
    var items: [Int: SynologyMediaItem] = [:]
    var position = 0
    while position < pending.count {
      try await checkpoint()
      try Task.checkCancellation()
      let folder = pending[position]
      position += 1
      guard visited.insert(folder).inserted else { continue }
      var offset = 0
      var childIDs = Set<Int>()
      while true {
        try await checkpoint()
        let page: SynologyFolderPage = try await authenticated(
          fields: [
            ("api", prefix + ".Browse.Folder"), ("version", "1"), ("method", "list"),
            ("id", String(folder)), ("offset", String(offset)), ("limit", "500"),
          ], insecure: allowInsecureSSL)
        if page.list.isEmpty { break }
        guard page.list.allSatisfy({ $0.id > 0 }) else {
          throw SynologyError.unexpectedResponse("NAS вернул некорректный ID папки")
        }
        guard page.list.contains(where: { !childIDs.contains($0.id) }) else {
          throw SynologyError.unexpectedResponse("NAS повторил страницу папок")
        }
        for child in page.list where childIDs.insert(child.id).inserted { pending.append(child.id) }
        offset += page.list.count
      }
      if folder != 0 {
        offset = 0
        var pageIDs = Set<Int>()
        while true {
          try await checkpoint()
          let page: SynologyMediaPage = try await authenticated(
            fields: [
              ("api", prefix + ".Browse.Item"), ("version", "1"), ("method", "list"),
              ("folder_id", String(folder)), ("offset", String(offset)), ("limit", "500"),
            ], insecure: allowInsecureSSL)
          if page.list.isEmpty { break }
          guard page.list.allSatisfy({ $0.id > 0 && $0.filesize >= 0 && !$0.filename.isEmpty })
          else { throw SynologyError.unexpectedResponse("NAS вернул некорректную запись каталога") }
          guard page.list.contains(where: { !pageIDs.contains($0.id) }) else {
            throw SynologyError.unexpectedResponse("NAS повторил страницу файлов")
          }
          for item in page.list where item.id > 0 {
            pageIDs.insert(item.id)
            items[item.id] = item
          }
          offset += page.list.count
          await progress(items.count, visited.count - (rootFolderID == 0 ? 1 : 0))
        }
      }
      await progress(items.count, visited.count - (rootFolderID == 0 ? 1 : 0))
    }
    return Array(items.values)
  }

  /// A single source file is streamed to disk, then hashed in bounded chunks. No filename-only legacy matches.
  func originalFingerprint(itemID: Int, targetSpace: TargetSpace, allowInsecureSSL: Bool)
    async throws -> FileFingerprint
  {
    guard let url = buildURL(baseURL: credentials().server, endpoint: "webapi/entry.cgi") else {
      throw SynologyError.invalidURL
    }
    for attempt in 0...1 {
      try Task.checkCancellation()
      let sid = try await session(insecure: allowInsecureSSL, refresh: attempt > 0)
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.setValue(try Self.sessionCookie(sid), forHTTPHeaderField: "Cookie")
      request.httpBody = Self.formBody([
        ("api", targetSpace == .shared ? "SYNO.FotoTeam.Download" : "SYNO.Foto.Download"),
        ("version", "2"), ("method", "download"), ("item_id", "[\(itemID)]"),
        ("download_type", try Self.jsonString("source")),
      ])
      let (file, response) = try await makeSession(insecure: allowInsecureSSL, upload: true)
        .download(for: request)
      defer { try? FileManager.default.removeItem(at: file) }
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw SynologyError.unexpectedResponse("Не удалось прочитать оригинал с NAS")
      }
      if http.mimeType == "application/json" {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65536) ?? Data()
        do {
          let _: SynologyUploadData = try Self.decodeResponse(SynologyUploadData.self, data: data)
        } catch SynologyError.sessionExpired where attempt == 0 {
          await reportSessionRefresh()
          continue
        }
        throw SynologyError.unexpectedResponse("NAS вернул JSON вместо исходного файла")
      }
      return try FileFingerprint.read(file)
    }
    throw SynologyError.sessionExpired
  }

  public func listAlbums(allowInsecureSSL: Bool, targetSpace: TargetSpace = .personal) async throws
    -> [SynologyAlbumItem]
  {
    var albums: [SynologyAlbumItem] = []
    let pageSize = 500
    while true {
      try Task.checkCancellation()
      let page: SynologyAlbumListData = try await authenticated(
        fields: [
          (
            "api",
            targetSpace == .shared
              ? "SYNO.FotoTeam.Browse.NormalAlbum" : "SYNO.Foto.Browse.NormalAlbum"
          ), ("version", "1"), ("method", "list"),
          ("offset", String(albums.count)), ("limit", String(pageSize)),
        ], insecure: allowInsecureSSL)
      guard !page.list.isEmpty else { break }
      let existing = Set(albums.map(\.id))
      guard page.list.contains(where: { !existing.contains($0.id) }) else {
        throw SynologyError.unexpectedResponse("Сервер повторил страницу альбомов")
      }
      albums.append(contentsOf: page.list)
      if page.list.count < pageSize || albums.count >= (page.total ?? Int.max) { break }
    }
    return albums
  }

  public func createAlbum(
    name: String, allowInsecureSSL: Bool, targetSpace: TargetSpace = .personal
  ) async throws -> Int {
    let result: SynologyAlbumCreateData = try await authenticated(
      fields: [
        (
          "api",
          targetSpace == .shared
            ? "SYNO.FotoTeam.Browse.NormalAlbum" : "SYNO.Foto.Browse.NormalAlbum"
        ), ("version", "1"), ("method", "create"), ("name", try Self.jsonString(name)),
      ], insecure: allowInsecureSSL)
    guard let id = result.albumId, id > 0 else {
      throw SynologyError.unexpectedResponse("Отсутствует ID альбома")
    }
    return id
  }

  public func addItemsToAlbum(
    albumId: Int, itemIds: [Int], allowInsecureSSL: Bool, targetSpace: TargetSpace = .personal
  ) async throws {
    let ids = Array(Set(itemIds.filter { $0 > 0 })).sorted()
    for offset in stride(from: 0, to: ids.count, by: 500) {
      let batch = Array(ids[offset..<min(offset + 500, ids.count)])
      let json = String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)
      // Some DSM versions return success without a data object for this operation.
      let _: EmptyAPIData = try await authenticated(
        fields: [
          (
            "api",
            targetSpace == .shared
              ? "SYNO.FotoTeam.Browse.NormalAlbum" : "SYNO.Foto.Browse.NormalAlbum"
          ), ("version", "1"), ("method", "add_item"),
          ("id", String(albumId)), ("item", json),
        ], insecure: allowInsecureSSL)
    }
  }
}

private struct EmptyAPIData: Decodable {}

/// Reject redirects so credentials and media never leave the requested endpoint.
final class APISessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let allowInsecureSSL: Bool
  init(allowInsecureSSL: Bool) { self.allowInsecureSSL = allowInsecureSSL }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if allowInsecureSSL,
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    {
      completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
      completionHandler(.performDefaultHandling, nil)
    }
  }
}
