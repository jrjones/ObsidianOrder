import XCTest
import Foundation
import SQLite
@testable import VaultIndex

final class VaultIndexTests: XCTestCase {
    func testFullScanCreatesEntries() throws {
        // Create a temporary vault directory
        let fileManager = FileManager.default
        let tmpDir = fileManager.temporaryDirectory
        let vaultDir = tmpDir.appendingPathComponent("TestVault_\(UUID().uuidString)")
        try fileManager.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: vaultDir) }
        // Create a simple markdown file
        let md = """
        ---
        title: Alpha
        tags:
          - tag1
          - tag2
        ---
        # Heading
        Content here
        """
        let noteURL = vaultDir.appendingPathComponent("alpha.md")
        try md.write(to: noteURL, atomically: true, encoding: .utf8)
        // Prepare a temporary DB path
        let dbURL = tmpDir.appendingPathComponent("testdb_\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: dbURL) }
        // Run index
        try VaultIndex.index(vaultPath: vaultDir.path, dbPath: dbURL.path, since: nil)
        // Open DB and verify
        let db = try Connection(dbURL.path)
        let notes = Table("notes")
        let count = try db.scalar(notes.count)
        XCTAssertEqual(count, 1, "Expected exactly one note entry")
        // Verify tags string
        if let row = try db.pluck(notes) {
            let tags: String = row[Expression<String>("tags")]
            XCTAssertEqual(tags, "tag1,tag2")
        } else {
            XCTFail("No note row found")
        }
    }
}

// For Linux test discovery
extension VaultIndexTests {
    static var allTests = [
        ("testFullScanCreatesEntries", testFullScanCreatesEntries),
    ]
}