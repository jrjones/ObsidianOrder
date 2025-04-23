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
    
    func testIncrementalRemovesDeletedFiles() throws {
        // Create a temporary vault directory with two markdown files
        let fileManager = FileManager.default
        let tmpDir = fileManager.temporaryDirectory
        let vaultDir = tmpDir.appendingPathComponent("TestVault_\(UUID().uuidString)")
        try fileManager.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: vaultDir) }
        // Create two markdown files
        let md1 = """
        # Note One
        Content A
        """
        let noteURL1 = vaultDir.appendingPathComponent("one.md")
        try md1.write(to: noteURL1, atomically: true, encoding: .utf8)
        let md2 = """
        # Note Two
        Content B
        """
        let noteURL2 = vaultDir.appendingPathComponent("two.md")
        try md2.write(to: noteURL2, atomically: true, encoding: .utf8)
        // Prepare a temporary DB path
        let dbURL = tmpDir.appendingPathComponent("testdb_\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: dbURL) }
        // Run full index
        try VaultIndex.index(vaultPath: vaultDir.path, dbPath: dbURL.path, since: nil)
        // Verify both notes indexed
        let db = try Connection(dbURL.path)
        let notes = Table("notes")
        let countFull = try db.scalar(notes.count)
        XCTAssertEqual(countFull, 2, "Expected two notes after full scan")
        // Remove first file and run incremental index
        try fileManager.removeItem(at: noteURL1)
        // Use a since date to trigger incremental deletion logic
        let sinceDate = Date()
        try VaultIndex.index(vaultPath: vaultDir.path, dbPath: dbURL.path, since: sinceDate)
        // Verify only one note remains
        let countInc = try db.scalar(notes.count)
        XCTAssertEqual(countInc, 1, "Expected one note after incremental scan removes deleted files")
        if let row = try db.pluck(notes) {
            let title: String = row[Expression<String>("title")]
            XCTAssertEqual(title, "two", "Expected remaining note to be 'two'")
        } else {
            XCTFail("No note row found after incremental scan")
        }
    }
}

// For Linux test discovery
extension VaultIndexTests {
    static var allTests = [
        ("testFullScanCreatesEntries", testFullScanCreatesEntries),
        ("testIncrementalRemovesDeletedFiles", testIncrementalRemovesDeletedFiles),
    ]
}