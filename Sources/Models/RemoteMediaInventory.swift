import CryptoKit
import Foundation

struct SynologyMediaItem: Decodable, Sendable {
  let id: Int
  let filename: String
  let filesize: Int64
  let time: Int64
  let type: String
}

struct SynologyMediaPage: Decodable { let list: [SynologyMediaItem] }
struct SynologyFolder: Decodable { let id: Int }
struct SynologyFolderPage: Decodable { let list: [SynologyFolder] }

struct FileFingerprint: Equatable, Sendable {
  let size: Int64
  let sha256: String

  static func read(_ url: URL) throws -> Self {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    var size: Int64 = 0
    while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
      try Task.checkCancellation()
      size += Int64(bytes.count)
      hash.update(data: bytes)
    }
    return Self(size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
}

/// Filename identity is sufficient only for app-generated names containing the Photos asset ID hash.
/// Legacy filename candidates must be compared byte-for-byte via their SHA-256 fingerprints.
struct RemoteMediaInventory: Sendable {
  private let byID: [Int: SynologyMediaItem]
  private let byName: [String: [SynologyMediaItem]]
  var count: Int { byID.count }

  init(items: [SynologyMediaItem]) {
    byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    byName = Dictionary(grouping: byID.values, by: { Self.nameKey($0.filename) })
  }

  private static func nameKey(_ name: String) -> String {
    name.precomposedStringWithCanonicalMapping.lowercased()
  }

  func knownItem(filename: String, cachedID: Int? = nil, originalFilename: String? = nil)
    -> SynologyMediaItem?
  {
    var allowedNames = Set([Self.nameKey(filename)])
    if let originalFilename {
      allowedNames.insert(Self.nameKey(originalFilename))
      allowedNames.insert(Self.nameKey(FilenameSanitizer.sanitize(originalFilename)))
    }
    if let cachedID, let item = byID[cachedID], allowedNames.contains(Self.nameKey(item.filename)) {
      return item
    }
    let matches = byName[Self.nameKey(filename)] ?? []
    return matches.count == 1 ? matches[0] : nil
  }

  func legacyCandidates(originalFilename: String) -> [SynologyMediaItem] {
    let names = Set(
      [originalFilename, FilenameSanitizer.sanitize(originalFilename)].map(Self.nameKey))
    var found: [Int: SynologyMediaItem] = [:]
    for name in names { for item in byName[name] ?? [] { found[item.id] = item } }
    return found.values.sorted { $0.id < $1.id }
  }
}
