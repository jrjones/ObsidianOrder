import ArgumentParser
import Foundation
import SQLite
import ObsidianModel

/// `obs collections` command namespace
struct Collections: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collections",
        abstract: "Operations on note collections",
        subcommands: [List.self, Show.self],
        defaultSubcommand: List.self
    )
    func run() throws {}
}

extension Collections {
    /// `obs collections ls` command: list notes tagged 'collection'
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "List all notes tagged 'collection'")
        @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
        var db: String?
        func run() throws {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let dbPath = db ?? "\(home)/.obsidian-order/state.sqlite"
            let connection = try Connection(dbPath)
            let notes = Table("notes")
            let tagsExp = Expression<String>("tags")
            let titleExp = Expression<String>("title")
            for row in try connection.prepare(notes.filter(tagsExp.like("%collection%"))) {
                print("- \(row[titleExp])")
            }
        }
    }

    /// `obs collections show` command: show a named collection
    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a named collection")
        @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
        var db: String?
        @Argument(help: "Name of the collection to show")
        var name: String
        func run() throws {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let dbPath = db ?? "\(home)/.obsidian-order/state.sqlite"
            let connection = try Connection(dbPath)
            let notes = Table("notes")
            let titleExp = Expression<String>("title")
            let pathExp = Expression<String>("path")
            guard let row = try connection.pluck(notes.filter(titleExp == name)) else {
                throw ValidationError("Collection '\(name)' not found")
            }
            let filePath = row[pathExp]
            let text = try String(contentsOfFile: filePath)
            let doc = try ObsidianModel.parseDocument(text)
            print(doc.body)
        }
    }
}