import XCTest

final class ProjectMembershipTests: XCTestCase {
  func testEverySwiftSourceBelongsToXcodeTarget() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(
      contentsOf: root.appendingPathComponent("SynologyPhotoSync.xcodeproj/project.pbxproj"))
    let project = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let objects = try XCTUnwrap(project["objects"] as? [String: [String: Any]])
    let phase = try XCTUnwrap(
      objects.values.first { $0["isa"] as? String == "PBXSourcesBuildPhase" })
    let compiledNames = Set(
      try XCTUnwrap(phase["files"] as? [String]).compactMap { id -> String? in
        guard let ref = objects[id]?["fileRef"] as? String else { return nil }
        return objects[ref]?["path"] as? String
      })
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(
        at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil))
    let sourceNames = Set(
      enumerator.compactMap { ($0 as? URL) }.filter { $0.pathExtension == "swift" }.map(
        \.lastPathComponent))
    XCTAssertEqual(
      compiledNames, sourceNames, "Regenerate the Xcode project when adding Swift files")
  }
}
