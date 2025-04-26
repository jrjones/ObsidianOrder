import XCTest
@testable import obs
import Foundation
import SQLite
import ObsidianModel
import GraphClient
import ArgumentParser

final class DailyReportHelpersTests: XCTestCase {
    // MARK: resolveDate

    func testResolveDate_withValidString() throws {
        let input = "2023-12-31"
        let output = try resolveDate(input: input)
        XCTAssertEqual(output, input)
    }

    func testResolveDate_withInvalidString_throwsValidationError() {
        XCTAssertThrowsError(try resolveDate(input: "banana")) { error in
            if let ve = error as? ValidationError {
                XCTAssertEqual(ve.description, "Invalid date format: banana. Expected YYYY-MM-DD.")
            } else {
                XCTFail("Expected ValidationError, got \(error)")
            }
        }
    }

    func testResolveDate_nil_returnsToday() throws {
        let output = try resolveDate(input: nil)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let expected = formatter.string(from: Date())
        XCTAssertEqual(output, expected)
    }

    // MARK: resolvePaths

    func testResolvePaths_withFlags() {
        let (vaultPath, dbPath) = resolvePaths(flagVault: "~/myvault", flagDb: "~/mydb.sqlite")
        XCTAssertTrue(vaultPath.hasSuffix("/myvault"))
        XCTAssertTrue(dbPath.hasSuffix("/mydb.sqlite"))
    }

    func testResolvePaths_noFlags_expandsTilde() {
        let (vaultPath, dbPath) = resolvePaths(flagVault: nil, flagDb: nil)
        // No tilde should remain in expanded paths
        XCTAssertFalse(vaultPath.contains("~"))
        XCTAssertFalse(dbPath.contains("~"))
    }

    // MARK: locateDailyNote

    func testLocateDailyNote_directChild() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let dailyDir = URL(fileURLWithPath: vault).appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let dateString = "2024-01-01"
        let fileURL = dailyDir.appendingPathComponent("\(dateString).md")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        let result = locateDailyNote(vaultPath: vault, dateString: dateString)
        // Compare standardized paths to handle /private vs /var symlink differences
        let standardizedResult = URL(fileURLWithPath: result.path).standardizedFileURL.path
        let standardizedExpected = fileURL.standardizedFileURL.path
        XCTAssertEqual(standardizedResult, standardizedExpected)
    }

    func testLocateDailyNote_recursive() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let nested = URL(fileURLWithPath: vault).appendingPathComponent("daily/2024")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let dateString = "2024-01-02"
        let fileURL = nested.appendingPathComponent("\(dateString).md")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        let result = locateDailyNote(vaultPath: vault, dateString: dateString)
        // Compare standardized paths to handle /private vs /var symlink differences
        let standardizedResult = URL(fileURLWithPath: result.path).standardizedFileURL.path
        let standardizedExpected = fileURL.standardizedFileURL.path
        XCTAssertEqual(standardizedResult, standardizedExpected)
    }

    func testLocateDailyNote_fallback() {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let dateString = "2024-01-03"
        let expected = URL(fileURLWithPath: vault).appendingPathComponent("\(dateString).md")
        let result = locateDailyNote(vaultPath: vault, dateString: dateString)
        // Compare standardized paths to handle /private vs /var symlink differences
        let standardizedResult = URL(fileURLWithPath: result.path).standardizedFileURL.path
        let standardizedExpected = expected.standardizedFileURL.path
        XCTAssertEqual(standardizedResult, standardizedExpected)
    }

    // MARK: loadDailyDoc

    func testLoadDailyDoc_fileExists() throws {
        let tmp = FileManager.default.temporaryDirectory
        let note = tmp.appendingPathComponent(UUID().uuidString + ".md")
        let text =
        """
        ---
        title: Test
        tags: [a, b]
        ---
        Hello, world!
        """
        try text.write(to: note, atomically: true, encoding: .utf8)
        let doc = try loadDailyDoc(at: note)
        XCTAssertEqual(doc?.metadata["title"] as? String, "Test")
        XCTAssertEqual(doc?.metadata["tags"] as? [String], ["a","b"])
        XCTAssertEqual(doc?.body.trimmingCharacters(in: .whitespacesAndNewlines), "Hello, world!")
    }

    func testLoadDailyDoc_fileMissing_returnsNil() throws {
        let tmp = FileManager.default.temporaryDirectory
        let note = tmp.appendingPathComponent(UUID().uuidString + ".md")
        let doc = try loadDailyDoc(at: note)
        XCTAssertNil(doc)
    }

    // MARK: loadTasks

    func testLoadTasks_withEntries() throws {
        let db = try Connection(.inMemory)
        try db.execute("CREATE TABLE notes(id INTEGER PRIMARY KEY, path TEXT)")
        try db.execute("CREATE TABLE tasks(id INTEGER PRIMARY KEY, note_id INTEGER, line_no INTEGER, text TEXT, state TEXT)")
        let noteURL = URL(fileURLWithPath: "/foo/bar.md")
        try db.run("INSERT INTO notes(path) VALUES(?)", noteURL.path)
        let noteID = db.lastInsertRowid
        try db.run("INSERT INTO tasks(note_id,line_no,text,state) VALUES (?,?,?,?)", noteID, 1, "First task", "todo")
        try db.run("INSERT INTO tasks(note_id,line_no,text,state) VALUES (?,?,?,?)", noteID, 2, "Done task", "done")
        let tasks = try loadTasks(from: db, noteURL: noteURL)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].line, 1)
        XCTAssertEqual(tasks[0].text, "First task")
        XCTAssertEqual(tasks[0].state, .todo)
        XCTAssertEqual(tasks[1].state, .done)
        let empty = try loadTasks(from: db, noteURL: URL(fileURLWithPath: "/no/such.md"))
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: loadMeetingSummaries

    func testLoadMeetingSummaries_picksUpSummary() throws {
        let db = try Connection(.inMemory)
        try db.execute("CREATE TABLE notes(path TEXT)")
        let tmp = FileManager.default.temporaryDirectory
        let file = tmp.appendingPathComponent("meeting-2024-02-02.md")
        let content =
        """
        # Meeting
        Summary::  Conference call summary.
        Other lines
        """
        try content.write(to: file, atomically: true, encoding: .utf8)
        try db.run("INSERT INTO notes(path) VALUES(?)", file.path)
        let map = try loadMeetingSummaries(from: db, dateString: "2024-02-02")
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[file.deletingPathExtension().lastPathComponent], "Conference call summary.")
    }

    func testLoadMeetingSummaries_skipsNoSummary() throws {
        let db = try Connection(.inMemory)
        try db.execute("CREATE TABLE notes(path TEXT)")
        let tmp = FileManager.default.temporaryDirectory
        let file = tmp.appendingPathComponent("meeting-2024-02-03.md")
        try "# No summary here".write(to: file, atomically: true, encoding: .utf8)
        try db.run("INSERT INTO notes(path) VALUES(?)", file.path)
        let map = try loadMeetingSummaries(from: db, dateString: "2024-02-03")
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: loadCalendarEvents

    func testLoadCalendarEvents_errorsSwallowed() {
        let ev = loadCalendarEvents(start: Date(), end: Date())
        XCTAssertTrue(ev.isEmpty)
    }
}