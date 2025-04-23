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
        // Transactional scan: full or incremental
        let notesTable = Table("notes")
        let linksTable = Table("links")
        let tasksTable = Table("tasks")
        let idExp = Expression<Int64>("id")
        let pathExp = Expression<String>("path")
        let titleExp = Expression<String>("title")
        let createdExp = Expression<Double>("created")
        let modifiedExp = Expression<Double>("modified")
        let tagsExp = Expression<String>("tags")
        let dailyExp = Expression<Int>("is_daily")
        let meetingExp = Expression<Int>("is_meeting")
        let noteIdExp = Expression<Int64>("note_id")
        let fromIdExp = Expression<Int64>("from_id")
        try db.transaction {
            // Build file list
            let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
            guard let enumerator = fileManager.enumerator(at: vaultURL, includingPropertiesForKeys: resourceKeys, options: options) else {
                return
            }
            var fileInfos: [(url: URL, attrs: URLResourceValues)] = []
            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "md" else { continue }
                let attrs = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                fileInfos.append((url: fileURL, attrs: attrs))
            }
            if since == nil {
                // Full scan: clear all tables
                try db.run(tasksTable.delete())
                try db.run(linksTable.delete())
                try db.run(notesTable.delete())
            } else {
                // Incremental: delete removed files
                var existing: [String: Int64] = [:]
                for row in try db.prepare(notesTable.select(idExp, pathExp)) {
                    existing[row[pathExp]] = row[idExp]
                }
                let currentPaths = Set(fileInfos.map { $0.url.path })
                for (path, id) in existing where !currentPaths.contains(path) {
                    try db.run(tasksTable.filter(noteIdExp == id).delete())
                    try db.run(linksTable.filter(fromIdExp == id).delete())
                    try db.run(notesTable.filter(idExp == id).delete())
                }
            }
            // Process files (full or incremental)
            for (fileURL, attrs) in fileInfos {
                if let since = since, let modDate = attrs.contentModificationDate, modDate <= since {
                    continue
                }
                let text = try String(contentsOf: fileURL)
                let doc = try ObsidianModel.parseDocument(text)
                // Derive fields
                let path = fileURL.path
                let title: String
                if let mtitle = doc.metadata["title"] as? String {
                    title = mtitle
                } else {
                    title = fileURL.deletingPathExtension().lastPathComponent
                }
                let tagsCSV: String
                if let tags = doc.metadata["tags"] as? [Any] {
                    tagsCSV = tags.compactMap { $0 as? String }.joined(separator: ",")
                } else {
                    tagsCSV = ""
                }
                let created = attrs.creationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                let modified = attrs.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                // Upsert note
                let noteID: Int64
                if let existingRow = try db.pluck(notesTable.filter(pathExp == path)), let existingID = existingRow[idExp] {
                    // Delete old links and tasks
                    try db.run(tasksTable.filter(noteIdExp == existingID).delete())
                    try db.run(linksTable.filter(fromIdExp == existingID).delete())
                    // Update metadata
                    try db.run(notesTable.filter(idExp == existingID).update(
                        titleExp <- title,
                        createdExp <- created,
                        modifiedExp <- modified,
                        tagsExp <- tagsCSV,
                        dailyExp <- 0,
                        meetingExp <- 0
                    ))
                    noteID = existingID
                } else {
                    // Insert new note
                    let insert = notesTable.insert(
                        pathExp <- path,
                        titleExp <- title,
                        createdExp <- created,
                        modifiedExp <- modified,
                        tagsExp <- tagsCSV,
                        dailyExp <- 0,
                        meetingExp <- 0
                    )
                    noteID = try db.run(insert)
                }
                // Insert links
                let links = ObsidianModel.parseLinks(doc.body)
                for link in links {
                    try db.run(linksTable.insert(fromIdExp <- noteID, Expression<String>("to_title") <- link.target))
                }
                // Insert tasks
                let tasks = ObsidianModel.parseTasks(doc.body)
                for task in tasks {
                    let state = (task.state == .done) ? "done" : "todo"
                    try db.run(tasksTable.insert(
                        noteIdExp <- noteID,
                        Expression<Int>("line_no") <- task.line,
                        Expression<String>("text") <- task.text,
                        Expression<String>("state") <- state
                    ))
                }
            }
        }
    }
}