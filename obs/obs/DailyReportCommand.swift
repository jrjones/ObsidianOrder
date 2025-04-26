import ArgumentParser
import Foundation
import Darwin  // for fputs, fflush
import ObsidianModel
import SQLite
import Yams
import GraphClient


/// `obs daily-report` command: render today's merged notes, tasks, meetings
struct DailyReport: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "daily-report", abstract: "Merge today's notes, tasks, meetings to stdout")
    @Argument(help: "Date in YYYY-MM-DD format (default: today)")
    var date: String?
    @Option(name: .long, help: "Path to Obsidian vault (default: ~/Obsidian)")
    var vault: String?
    @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
    var db: String?
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
    @Flag(name: [.short, .long], help: "Update meeting notes and daily page in place")
    var update: Bool = false
    @Flag(name: [.short, .long], help: "Overwrite existing AI-generated summaries in daily and meeting notes")
    var overwrite: Bool = false

    func run() throws {
        // Paths, date, and initial data
        let (vaultPath, dbPath) = resolvePaths(flagVault: vault, flagDb: db)
        print("Using vault path: \(vaultPath)")
        print("Using DB path:    \(dbPath)")
        let dateString = try resolveDate(input: date)
        let noteURL = locateDailyNote(vaultPath: vaultPath, dateString: dateString)
        let doc = try loadDailyDoc(at: noteURL)
        let dbConn = try Connection(dbPath)
        let tasks = try loadTasks(from: dbConn, noteURL: noteURL)

        if update {
            try updateMeetingNotes(in: dbConn,
                                   for: dateString,
                                   dailyNoteURL: noteURL,
                                   overwrite: overwrite)
            try updateDailySummary(at: noteURL,
                                   in: dbConn,
                                   for: dateString,
                                   overwrite: overwrite)
            return
        }

        if json {
            let out = try renderJSON(doc: doc,
                                     tasks: tasks,
                                     dateString: dateString)
            print(out)
            return
        }

        let meetings = try loadMeetingSummaries(from: dbConn,
                                                dateString: dateString)
        let markdown = try renderMarkdown(doc: doc,
                                          tasks: tasks,
                                          meetings: meetings,
                                          dateString: dateString,
                                          noteURL: noteURL)
        print(markdown)
    }
}

