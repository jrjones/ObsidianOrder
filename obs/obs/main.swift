//
//  main.swift
//  obs
//
//  Created by Joseph R. Jones on 4/23/25.
//

import Foundation

import ArgumentParser
import Foundation
import ObsidianModel

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
        print("[stub] Indexing vault at \(vaultPath) into DB at \(dbPath), since=\(since ?? "<none>")")
    }
}

/// `obs daily-report` command: render today's merged notes, tasks, meetings
struct DailyReport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "daily-report", abstract: "Merge today's notes, tasks, meetings to stdout")
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
    func run() throws {
        print("[stub] daily-report (json=\(json))")
    }
}

/// `obs weekly-preview` command: render ISO-week dashboard
struct WeeklyPreview: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "weekly-preview", abstract: "Render ISO-week dashboard (no file write)")
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
    func run() throws {
        print("[stub] weekly-preview (json=\(json))")
    }
}

/// `obs agenda` command: print calendar events
struct Agenda: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print today's calendar pulled from Graph (read-only)")
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
    func run() throws {
        print("[stub] agenda (json=\(json))")
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
        func run() throws {
            print("[stub] collections ls")
        }
    }
    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a named collection")
        @Argument(help: "Name of the collection to show")
        var name: String
        func run() throws {
            print("[stub] collections show \(name)")
        }
    }
}

Obs.main()

