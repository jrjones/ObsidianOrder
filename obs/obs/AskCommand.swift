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
        // ANSI hyperlink helper: wraps text as a clickable URI in supporting terminals
        func hyperlink(_ text: String, uri: String) -> String {
            let esc = "\u{001B}]8;;\(uri)\u{0007}"
            let escEnd = "\u{001B}]8;;\u{0007}"
            return "\(esc)\(text)\(escEnd)"
        }
        var found = 0
        for row in try connection.prepare(stmt) {
            let title = row[titleExp]
            let path = row[pathExp]
            // Percent-encode path for Obsidians URI
            if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                let uri = "obsidian://open?path=\(encoded)"
                let link = hyperlink(title, uri: uri)
                print("- \(link) (\(path))")
            } else {
                print("- \(title) (\(path))")
            }
            found += 1
        }
        if found == 0 {
            print("No matching notes found for query: '\(query)'")
        }
    }
}