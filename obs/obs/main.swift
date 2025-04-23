//
//  main.swift
//  obs
//
//  Created by Joseph R. Jones on 4/23/25.
//

import ArgumentParser
import Foundation
import ObsidianModel
import VaultIndex
import SQLite
import GraphClient

/// Main entrypoint for the `obs` CLI.
struct Obs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "obs",
        abstract: "Obsidian Order: headless vault indexer and reporter",
        version: "0.1.0",
        subcommands: [Index.self, DailyReport.self, WeeklyPreview.self, Agenda.self, Collections.self],
        defaultSubcommand: nil
    )
    func run() throws {
        // No-op: users must choose a subcommand
    }
}

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

/// `obs daily-report` command: render today's merged notes, tasks, meetings
struct DailyReport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "daily-report", abstract: "Merge today's notes, tasks, meetings to stdout")
    @Option(name: .long, help: "Path to Obsidian vault (default: ~/Obsidian)")
    var vault: String?
    @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
    var db: String?
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
    func run() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let vaultPath = vault ?? "\(home)/Obsidian"
        let dbPath = db ?? "\(home)/.obsidian-order/state.sqlite"
        // Today's date
        let today = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: today)
        // Load daily note
        let noteFilename = "\(dateString).md"
        let noteURL = URL(fileURLWithPath: vaultPath).appendingPathComponent(noteFilename)
        var doc: Document? = nil
        if FileManager.default.fileExists(atPath: noteURL.path) {
            let text = try String(contentsOf: noteURL)
            doc = try ObsidianModel.parseDocument(text)
        }
        // Open DB
        let connection = try Connection(dbPath)
        let notesTable = Table("notes")
        let pathExp = Expression<String>("path")
        let idExp = Expression<Int64>("id")
        let tasksTable = Table("tasks")
        let noteID: Int64? = {
            guard doc != nil else { return nil }
            let query = notesTable.select(idExp).filter(pathExp == noteURL.path)
            if let row = try? connection.pluck(query) {
                return row[idExp]
            }
            return nil
        }()
        // Fetch tasks for daily note
        var tasks: [ObsidianModel.Task] = []
        if let nid = noteID {
            let lineExp = Expression<Int>("line_no")
            let textExp = Expression<String>("text")
            let stateExp = Expression<String>("state")
            for row in try connection.prepare(tasksTable.filter(Expression<Int64>("note_id") == nid)) {
                let stateStr = row[stateExp]
                let state: ObsidianModel.TaskState = stateStr.lowercased() == "done" ? .done : .todo
                let task = ObsidianModel.Task(line: row[lineExp], text: row[textExp], state: state)
                tasks.append(task)
            }
        }
        // Render report
        if json {
            var out: [String: Any] = ["date": dateString]
            if let doc = doc {
                out["metadata"] = doc.metadata
                out["body"] = doc.body
            }
            out["tasks"] = tasks.map { ["line": $0.line, "text": $0.text, "state": ($0.state == .done ? "done" : "todo")] }
            out["events"] = []
            let data = try JSONSerialization.data(withJSONObject: out, options: .prettyPrinted)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("# Daily Report for \(dateString)\n")
            print("## Daily Note\n")
            if let doc = doc {
                print(doc.body + "\n")
            } else {
                print("_No daily note found._\n")
            }
            print("## Tasks\n")
            if tasks.isEmpty {
                print("_No tasks found._\n")
            } else {
                for t in tasks {
                    let checkbox = t.state == .done ? "[x]" : "[ ]"
                    print("- \(checkbox) \(t.text)")
                }
                print("")
            }
            print("## Events\n")
            print("_No events available._")
        }
}

/// `obs weekly-preview` command: render ISO-week dashboard
struct WeeklyPreview: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "weekly-preview", abstract: "Render ISO-week dashboard (no file write)")
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
    func run() throws {
        // Stubbed weekly preview; to be implemented
        let today = Date()
        let calendar = Calendar(identifier: .iso8601)
        let weekOfYear = calendar.component(.weekOfYear, from: today)
        let yearForWeek = calendar.component(.yearForWeekOfYear, from: today)
        let weekString = String(format: "%04d-W%02d", yearForWeek, weekOfYear)
        let items: [[String: Any]] = []
        if json {
            let output: [String: Any] = ["week": weekString, "items": items]
            let data = try JSONSerialization.data(withJSONObject: output, options: .prettyPrinted)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("# Weekly Preview for \(weekString)\n")
            if items.isEmpty {
                print("_No preview available._")
            } else {
                // TODO: render items
            }
        }
    }
}

/// `obs agenda` command: print calendar events
struct Agenda: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print today's calendar pulled from Graph (read-only)")
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
        func run() throws {
        // Fetch today's events via GraphClient stub
        let today = Date()
        let calendar = Calendar(identifier: .iso8601)
        let startOfDay = calendar.startOfDay(for: today)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? today
        let client = GraphClient()
        let graphEvents: [GraphEvent]
        do {
            graphEvents = try client.fetchEvents(start: startOfDay, end: endOfDay)
        } catch {
            graphEvents = []
        }
        let isoFormatter = ISO8601DateFormatter()
        let events: [[String: Any]] = graphEvents.map { event in
            [
                "id": event.id,
                "title": event.title,
                "start": isoFormatter.string(from: event.start),
                "end": isoFormatter.string(from: event.end),
                "location": event.location ?? "",
                "is_virtual": event.isVirtual
            ]
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: today)
        if json {
            let output: [String: Any] = ["date": dateString, "events": events]
                let data = try JSONSerialization.data(withJSONObject: output, options: .prettyPrinted)
                if let str = String(data: data, encoding: .utf8) {
                    print(str)
                }
            } else {
                print("# Agenda for \(dateString)\n")
                print("## Events\n")
                if events.isEmpty {
                    print("_No events available._")
                } else {
                    for event in events {
                        if let start = event["start"] as? String,
                           let title = event["title"] as? String {
                            print("- **\(start)**: \(title)")
                        }
                    }
                }
            }
        }
}

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

Obs.main()

