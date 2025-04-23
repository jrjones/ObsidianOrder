// VaultIndex: Scans an Obsidian vault and populates a SQLite index database.
import Foundation
import ObsidianModel
import SQLite

/// Provides full and incremental indexing of an Obsidian vault into SQLite.
public enum VaultIndex {
    /// Indexes the vault at `vaultPath` into the SQLite database at `dbPath`.
    /// - Parameters:
    ///   - vaultPath: Filesystem path to the vault directory.
    ///   - dbPath: Filesystem path to the SQLite database file.
    ///   - since: Optional cutoff date; files not modified since then are skipped.
    public static func index(vaultPath: String, dbPath: String, since: Date? = nil) throws {
        let fileManager = FileManager.default
        let vaultURL = URL(fileURLWithPath: vaultPath)
        let dbURL = URL(fileURLWithPath: dbPath)
        // Ensure DB directory exists
        let dbDir = dbURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dbDir.path) {
            try fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)
        }
        // Open SQLite connection
        let db = try Connection(dbURL.path)
        // Create tables if needed
        try db.run("""
        CREATE TABLE IF NOT EXISTS notes(
            id INTEGER PRIMARY KEY,
            path TEXT UNIQUE,
            title TEXT,
            created DOUBLE,
            modified DOUBLE,
            tags TEXT,
            is_daily INTEGER,
            is_meeting INTEGER
        )
        """
        )
        try db.run("""
        CREATE TABLE IF NOT EXISTS links(
            from_id INTEGER,
            to_title TEXT
        )
        """
        )
        try db.run("""
        CREATE TABLE IF NOT EXISTS tasks(
            id INTEGER PRIMARY KEY,
            note_id INTEGER,
            line_no INTEGER,
            text TEXT,
            state TEXT
        )
        """
        )
        // Transactional full scan
        try db.transaction {
            // Clear existing entries
            try db.run("DELETE FROM notes;")
            try db.run("DELETE FROM links;")
            try db.run("DELETE FROM tasks;")
            // Enumerate markdown files in vault
            let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
            guard let enumerator = fileManager.enumerator(at: vaultURL, includingPropertiesForKeys: resourceKeys, options: options) else {
                return
            }
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "md" else { continue }
                let attrs = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                if let since = since, let modDate = attrs.contentModificationDate, modDate <= since {
                    continue
                }
                let text = try String(contentsOf: fileURL)
                let doc = try ObsidianModel.parseDocument(text)
                // Derive title
                let title: String
                if let mtitle = doc.metadata["title"] as? String {
                    title = mtitle
                } else {
                    title = fileURL.deletingPathExtension().lastPathComponent
                }
                // Tags
                var tagsCSV = ""
                if let tags = doc.metadata["tags"] as? [Any] {
                    let strs = tags.compactMap { $0 as? String }
                    tagsCSV = strs.joined(separator: ",")
                }
                // Dates
                let created = attrs.creationDate ?? Date()
                let modified = attrs.contentModificationDate ?? Date()
                // Insert or replace note
                try db.run(
                    "INSERT OR REPLACE INTO notes(path, title, created, modified, tags, is_daily, is_meeting) VALUES(?, ?, ?, ?, ?, ?, ?)",
                    fileURL.path,
                    title,
                    created.timeIntervalSince1970,
                    modified.timeIntervalSince1970,
                    tagsCSV,
                    0,
                    0
                )
                let noteID = db.lastInsertRowid
                // Links
                let links = ObsidianModel.parseLinks(doc.body)
                for link in links {
                    try db.run(
                        "INSERT INTO links(from_id, to_title) VALUES(?, ?)",
                        noteID,
                        link.target
                    )
                }
                // Tasks
                let tasks = ObsidianModel.parseTasks(doc.body)
                for task in tasks {
                    let state = (task.state == .done) ? "done" : "todo"
                    try db.run(
                        "INSERT INTO tasks(note_id, line_no, text, state) VALUES(?, ?, ?, ?)",
                        noteID,
                        task.line,
                        task.text,
                        state
                    )
                }
            }
        }
    }
}