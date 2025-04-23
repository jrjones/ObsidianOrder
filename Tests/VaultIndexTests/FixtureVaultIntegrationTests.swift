import XCTest
import Foundation
import SQLite
@testable import VaultIndex

/// Integration test using a fixture vault under Tests/Fixtures/Vault
final class VaultIndexIntegrationTests: XCTestCase {
    func testFixtureVaultIndexing() throws {
        let fileManager = FileManager.default
        // Determine repository root and fixture vault path
        let repoRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let fixtureVault = repoRoot.appendingPathComponent("Tests/Fixtures/Vault")
        XCTAssertTrue(fileManager.fileExists(atPath: fixtureVault.path), "Fixture vault directory not found")
        // Prepare temporary DB path
        let tmpDir = fileManager.temporaryDirectory
        let dbURL = tmpDir.appendingPathComponent("fixture_testdb_\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: dbURL) }
        // Run full index
        try VaultIndex.index(vaultPath: fixtureVault.path, dbPath: dbURL.path, since: nil)
        // Open DB and verify
        let db = try Connection(dbURL.path)
        let notes = Table("notes")
        let tasks = Table("tasks")
        let links = Table("links")
        // Verify counts
        let notesCount = try db.scalar(notes.count)
        XCTAssertEqual(notesCount, 2, "Expected two notes in fixture vault")
        let tasksCount = try db.scalar(tasks.count)
        XCTAssertEqual(tasksCount, 2, "Expected two tasks (one todo, one done)")
        let linksCount = try db.scalar(links.count)
        XCTAssertEqual(linksCount, 1, "Expected one link entry")
        // Verify tags CSV for the Test note
        let titleExp = Expression<String>("title")
        let tagsExp = Expression<String>("tags")
        if let row = try db.pluck(notes.filter(titleExp == "Test")) {
            let tags = row[tagsExp]
            XCTAssertTrue(tags.contains("foo"))
            XCTAssertTrue(tags.contains("collection"))
        } else {
            XCTFail("Test note not found in DB")
        }
    }
}

// For Linux test discovery
extension VaultIndexIntegrationTests {
    static var allTests = [
        ("testFixtureVaultIndexing", testFixtureVaultIndexing),
    ]
}