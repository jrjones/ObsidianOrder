import ArgumentParser
import Foundation
import VaultIndex
import Yams

/// `obs index` command: scan vault and refresh SQLite manifest
struct Index: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan vault, refresh SQLite manifest")
    @Option(name: .long, help: "Path to Obsidian vault (flag > config file > default: ~/Obsidian)")
    var vault: String?
    @Option(name: .long, help: "Path to SQLite DB (flag > config file > default: ~/.obsidian-order/state.sqlite)")
    var db: String?
    @Option(name: .long, help: "ISO datetime; only scan files modified since then")
    var since: String?
    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Load CLI config (optional) for vault and db paths
        struct CLIConfig: Decodable { var vault: String?; var db: String? }
        let configPath = "\(home)/.config/obsidian-order/config.yaml"
        var config = CLIConfig(vault: nil, db: nil)
        if FileManager.default.fileExists(atPath: configPath) {
            do {
                let yamlText = try String(contentsOfFile: configPath)
                config = try YAMLDecoder().decode(CLIConfig.self, from: yamlText)
            } catch {
                print("Warning: failed to parse config at \(configPath): \(error)")
            }
        }
        // Determine vault path: flag > config > default
        let defaultVault = "\(home)/Obsidian"
        let flagVault = vault.map { NSString(string: $0).expandingTildeInPath }
        let configVault = config.vault.map { NSString(string: $0).expandingTildeInPath }
        let vaultPath: String
        if let v = flagVault {
            vaultPath = v
        } else if let cv = configVault, FileManager.default.fileExists(atPath: cv) {
            vaultPath = cv
        } else {
            if config.vault != nil {
                print("Warning: config vault path not found at \(config.vault!), using default \(defaultVault).")
            }
            vaultPath = defaultVault
        }
        // Determine db path: flag > config > default
        let defaultDb = "\(home)/.obsidian-order/state.sqlite"
        let flagDb = db.map { NSString(string: $0).expandingTildeInPath }
        let configDb = config.db.map { NSString(string: $0).expandingTildeInPath }
        let dbPath: String
        if let d = flagDb {
            dbPath = d
        } else if let cd = configDb {
            dbPath = cd
        } else {
            dbPath = defaultDb
        }
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