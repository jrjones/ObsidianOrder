import ArgumentParser
import Foundation
import VaultIndex

/// `obs index` command: scan vault and refresh SQLite manifest
struct Index: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan vault, refresh SQLite manifest")
    @Option(name: .long, help: "Path to Obsidian vault (default: ~/Obsidian)")
    var vault: String?
    @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
    var db: String?
    @Option(name: .long, help: "ISO datetime; only scan files modified since then")
    var since: String?
    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let vaultPath = vault ?? "\(home)/Obsidian"
        let dbPath = db ?? "\(home)/.obsidian-order/state.sqlite"
        var sinceDate: Date? = nil
        if let since = since {
            let formatter = ISO8601DateFormatter()
            guard let date = formatter.date(from: since) else {
                throw ValidationError("Invalid --since datetime: \(since)")
            }
            sinceDate = date
        }
        print("Indexing vault at \(vaultPath) into DB at \(dbPath) since=\(sinceDate.map { String(describing: $0) } ?? "<none>")...")
        try VaultIndex.index(vaultPath: vaultPath, dbPath: dbPath, since: sinceDate)
        print("Index complete.")
    }
}