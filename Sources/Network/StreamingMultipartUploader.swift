import Foundation

/// Прогресс потоковой выгрузки файла
public struct UploadProgressInfo: Sendable {
  public let fractionCompleted: Double
  public let bytesSent: Int64
  public let totalBytes: Int64
  public let formattedText: String
  public let speedText: String
}

/// Класс для потоковой сборки multipart/form-data на диске и выгрузки без перегрузки RAM
public final class StreamingMultipartUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
  var sharedSession: URLSession?
  var configuration: URLSessionConfiguration = .ephemeral
  private var progressHandler: (@Sendable (UploadProgressInfo) -> Void)?
  private var lastProgressTime: Date = Date()
  private var lastBytesSent: Int64 = 0

  public override init() {
    super.init()
  }

  /// Сборка multipart пакета во временный файл и выгрузка через URLSession
  public func upload(
    url: URL,
    parameters: [(String, String)],
    fileURL: URL,
    filename: String,
    allowInsecureSSL: Bool,
    sessionID: String? = nil,
    progress: @escaping @Sendable (UploadProgressInfo) -> Void
  ) async throws -> (Data, HTTPURLResponse) {
    self.progressHandler = progress
    self.lastProgressTime = Date()
    self.lastBytesSent = 0

    try Task.checkCancellation()
    let (multipartTempURL, boundary) = try Self.makeMultipart(
      parameters: parameters, fileURL: fileURL, filename: filename)
    defer { try? FileManager.default.removeItem(at: multipartTempURL) }

    // 5. Формирование HTTP-запроса
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    if let sessionID {
      request.setValue(try SynologyAPIClient.sessionCookie(sessionID), forHTTPHeaderField: "Cookie")
    }
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: multipartTempURL.path)
    let totalSize = fileAttributes[.size] as? Int64 ?? 0
    request.setValue(String(totalSize), forHTTPHeaderField: "Content-Length")

    let ownsSession = sharedSession == nil
    let fallbackConfiguration = configuration.copy() as! URLSessionConfiguration
    fallbackConfiguration.timeoutIntervalForRequest = 300
    fallbackConfiguration.timeoutIntervalForResource = 3600
    fallbackConfiguration.httpCookieStorage = nil
    fallbackConfiguration.urlCache = nil
    let session =
      sharedSession
      ?? URLSession(
        configuration: fallbackConfiguration,
        delegate: APISessionDelegate(allowInsecureSSL: allowInsecureSSL), delegateQueue: nil)
    defer { if ownsSession { session.finishTasksAndInvalidate() } }
    let (data, response) = try await session.upload(
      for: request, fromFile: multipartTempURL, delegate: self)
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw SynologyError.unexpectedResponse("Отсутствует HTTP-ответ сервера")
    }
    return (data, http)
  }

  static func makeMultipart(parameters: [(String, String)], fileURL: URL, filename: String) throws
    -> (URL, String)
  {
    let boundary = "Boundary-\(UUID().uuidString)"
    let tempDir = FileManager.default.temporaryDirectory
    let multipartTempURL = tempDir.appendingPathComponent("syno_upload_\(UUID().uuidString).tmp")

    // Создаем временный файл для multipart пакета
    guard
      FileManager.default.createFile(
        atPath: multipartTempURL.path, contents: nil,
        attributes: [.posixPermissions: 0o600])
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    var completed = false
    defer { if !completed { try? FileManager.default.removeItem(at: multipartTempURL) } }
    let writeHandle = try FileHandle(forWritingTo: multipartTempURL)
    defer { try? writeHandle.close() }

    // 1. Потоковая запись текстовых полей формы строго в заданном порядке (api, version, method первыми)
    for (key, value) in parameters {
      guard key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }),
        !key.isEmpty
      else {
        throw SynologyError.unexpectedResponse("Недопустимое имя поля формы")
      }
      var fieldHeader = "--\(boundary)\r\n"
      fieldHeader += "Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n"
      fieldHeader += "\(value)\r\n"

      if let headerData = fieldHeader.data(using: .utf8) {
        try writeHandle.write(contentsOf: headerData)
      }
    }

    // 2. Запись заголовка файла (поле "file" строго последним)
    let safeFilename = FilenameSanitizer.sanitize(filename)
    let mimeType = mimeTypeForPath(safeFilename)
    var fileHeader = "--\(boundary)\r\n"
    fileHeader += "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n"
    fileHeader += "Content-Type: \(mimeType)\r\n\r\n"

    if let fileHeaderData = fileHeader.data(using: .utf8) {
      try writeHandle.write(contentsOf: fileHeaderData)
    }

    // 3. Потоковое копирование байтов медиафайла чанками по 1 МБ
    let readHandle = try FileHandle(forReadingFrom: fileURL)
    defer {
      try? readHandle.close()
    }

    let chunkSize = 1024 * 1024  // 1 MB
    while true {
      try Task.checkCancellation()
      let chunk = try readHandle.read(upToCount: chunkSize) ?? Data()
      if chunk.isEmpty {
        break
      }
      try writeHandle.write(contentsOf: chunk)
    }

    // 4. Запись закрывающего boundary
    let footer = "\r\n--\(boundary)--\r\n"
    if let footerData = footer.data(using: .utf8) {
      try writeHandle.write(contentsOf: footerData)
    }

    try writeHandle.close()
    completed = true
    return (multipartTempURL, boundary)

  }

  // MARK: - URLSessionTaskDelegate

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    guard totalBytesExpectedToSend > 0 else { return }

    let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)

    let now = Date()
    let elapsed = now.timeIntervalSince(lastProgressTime)
    guard elapsed >= 0.25 || totalBytesSent >= totalBytesExpectedToSend else { return }
    var speedText = ""

    if elapsed >= 0.5 {
      let bytesDelta = totalBytesSent - lastBytesSent
      let bytesPerSec = Double(bytesDelta) / elapsed
      speedText = formatSpeed(bytesPerSec)
      lastBytesSent = totalBytesSent
      lastProgressTime = now
    }

    let sentMB = Double(totalBytesSent) / (1024 * 1024)
    let totalMB = Double(totalBytesExpectedToSend) / (1024 * 1024)
    let formattedText = String(format: "%.1f МБ из %.1f МБ", sentMB, totalMB)

    let info = UploadProgressInfo(
      fractionCompleted: min(1.0, max(0.0, fraction)),
      bytesSent: totalBytesSent,
      totalBytes: totalBytesExpectedToSend,
      formattedText: formattedText,
      speedText: speedText
    )

    progressHandler?(info)
  }

  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  private func formatSpeed(_ bytesPerSec: Double) -> String {
    if bytesPerSec >= 1024 * 1024 {
      return String(format: "%.1f МБ/с", bytesPerSec / (1024 * 1024))
    } else if bytesPerSec >= 1024 {
      return String(format: "%.0f КБ/с", bytesPerSec / 1024)
    } else {
      return "\(Int(bytesPerSec)) Б/с"
    }
  }

  private static func mimeTypeForPath(_ filename: String) -> String {
    let ext = (filename as NSString).pathExtension.lowercased()
    switch ext {
    case "heic", "heif":
      return "image/heic"
    case "jpg", "jpeg":
      return "image/jpeg"
    case "png":
      return "image/png"
    case "dng", "raw", "cr2", "nef", "arw":
      return "image/x-adobe-dng"
    case "mov":
      return "video/quicktime"
    case "mp4":
      return "video/mp4"
    case "m4v":
      return "video/x-m4v"
    default:
      return "application/octet-stream"
    }
  }
}
