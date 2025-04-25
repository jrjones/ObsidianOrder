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
        subcommands: [Index.self, Embed.self, Shell.self, DailyReport.self, DailySummary.self, WeeklyPreview.self, Agenda.self, Collections.self, Ask.self],
        defaultSubcommand: Shell.self
    )
    func run() throws {
        // No-op: users must choose a subcommand
    }
}

Obs.main()

