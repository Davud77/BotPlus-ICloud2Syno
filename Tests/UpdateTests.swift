import CryptoKit
import XCTest

@testable import SynologyPhotoSync

@MainActor
final class UpdateTests: XCTestCase {
  func testVersionIncludesMarketingVersionAndBuild() {
    let version = AppVersion(info: ["CFBundleShortVersionString": "1.4.0", "CFBundleVersion": "5"])
    XCTAssertEqual(version.display, "Версия 1.4.0 (5)")
    XCTAssertEqual(AppVersion(info: [:]).display, "Версия — (—)")
  }

  func testInstallationWaitsForSyncCleanupAndRunsExactlyOnce() {
    let gate = UpdateInstallationGate()
    var installed = 0
    XCTAssertTrue(gate.postpone(isSyncing: true) { installed += 1 })
    gate.syncStateChanged(isSyncing: true)  // Includes a user-paused session.
    XCTAssertEqual(installed, 0)
    gate.syncStateChanged(isSyncing: false)
    gate.syncStateChanged(isSyncing: false)
    XCTAssertEqual(installed, 1)
  }

  func testAbortedUpdateNeverInstallsOnLaterSyncCompletion() {
    let gate = UpdateInstallationGate()
    var installed = false
    XCTAssertTrue(gate.postpone(isSyncing: true) { installed = true })
    gate.cancel()
    gate.syncStateChanged(isSyncing: false)
    XCTAssertFalse(installed)
  }

  func testIdleInstallIsHandledBySparkleWithoutRetainingCallback() {
    let gate = UpdateInstallationGate()
    var installed = false
    XCTAssertFalse(gate.postpone(isSyncing: false) { installed = true })
    gate.syncStateChanged(isSyncing: false)
    XCTAssertFalse(installed)
  }

  func testReleaseRequiresSignedFeedAndVerificationBeforeExtraction() throws {
    let info = try releaseInfo()
    XCTAssertEqual(
      info["SUFeedURL"] as? String,
      "https://raw.githubusercontent.com/Davud77/BotPlus-ICloud2Syno/main/appcast.xml")
    XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
    XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
    XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
    XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
    XCTAssertEqual(info["LSUIElement"] as? Bool, false)
    XCTAssertFalse(BuildEnvironment.isScreenshotPreview)
  }

  func testTrustedReleaseKeyRejectsTamperedDataAndWrongKey() throws {
    let publicKey = try XCTUnwrap(try releaseInfo()["SUPublicEDKey"] as? String)
    let key = try Curve25519.Signing.PublicKey(
      rawRepresentation: XCTUnwrap(Data(base64Encoded: publicKey)))
    let payload = Data("SynologyPhotoSync update signature fixture v1\n".utf8)
    let signature = try XCTUnwrap(
      Data(
        base64Encoded:
          "NMrLRJCgbamq3p7x/gbvapPBnhuBEnwX5JJDRBbP5Zoxwxjd0zKRaUCzr7oB9ta9p13mFVznaMHNIrJl2RlWCA=="
      ))
    XCTAssertTrue(key.isValidSignature(signature, for: payload))
    XCTAssertFalse(key.isValidSignature(signature, for: payload + Data([0])))
    XCTAssertFalse(
      Curve25519.Signing.PrivateKey().publicKey.isValidSignature(signature, for: payload))
  }

  private func releaseInfo() throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    return try XCTUnwrap(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil)
        as? [String: Any])
  }
}
