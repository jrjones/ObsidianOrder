import ArgumentParser
import Foundation
import SQLite

/// `obs ask` command: search notes matching a query (stub implementation)
struct Ask: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Search notes by query (substring match stub; semantic search TBD)"
    )

    @Argument(help: "Query text to search for")
    var query: String

    @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
    var db: String?

    @Option(name: .long, help: "Maximum number of results (default: 5)")
    var top: Int = 5

    @Option(name: .long, help: "Rerank model (not used in stub)")
    var rerank: String?

    func run() throws {
        // Determine database path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = db ?? "\(home)/.obsidian-order/state.sqlite"
        let connection = try Connection(dbPath)

        // Simple substring match on title or path
        let notes = Table("notes")
        let titleExp = Expression<String>("title")
        let pathExp = Expression<String>("path")
        let pattern = "%\(query)%"
        let filterExp = titleExp.like(pattern) || pathExp.like(pattern)
        var stmt = notes.filter(filterExp).limit(top)

        // Execute and print results
        // Display results: two columns (truncated title, raw Obsidian URI) for URL auto-detection
        let displayWidth = 40
        var found = 0
        for row in try connection.prepare(stmt) {
            let title = row[titleExp]
            let path = row[pathExp]
            if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                let uri = "obsidian://open?path=\(encoded)"
                let displayTitle: String
                if title.count <= displayWidth {
                    displayTitle = title + String(repeating: " ", count: displayWidth - title.count)
                } else {
                    displayTitle = String(title.prefix(displayWidth - 1)) + "…"
                }
                print("- \(displayTitle)  \(uri)")
            } else {
                print("- \(title)  (Invalid path URI)")
            }
            found += 1
        }
        if found == 0 {
            print("No matching notes found for query: '\(query)'")
        }
    }
}