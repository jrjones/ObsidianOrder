//
//  CommandHelpers.swift
//  obsidian-order
//
//  Created by Joseph R. Jones on 4/26/25.
//

import ArgumentParser
import Foundation
import Darwin  // for fputs, fflush
import ObsidianModel
import SQLite
import Yams
import GraphClient

private struct CLIConfig: Decodable {
    var vault: String?
    var db: String?
}


/// Resolve vault and DB paths (flag > config file > default)
func resolvePaths(flagVault: String?, flagDb: String?) -> (vaultPath: String, dbPath: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // Load YAML config
    let configPath = "\(home)/.config/obsidian-order/config.yaml"
    var config = CLIConfig(vault: nil, db: nil)
    if FileManager.default.fileExists(atPath: configPath) {
        if let yaml = try? String(contentsOfFile: configPath),
           let loaded = try? YAMLDecoder().decode(CLIConfig.self, from: yaml) {
            config = loaded
        }
    }
    // Vault path
    let defaultVault = "\(home)/Obsidian"
    let flagVaultPath = flagVault.map { NSString(string: $0).expandingTildeInPath }
    let configVaultPath = config.vault.map { NSString(string: $0).expandingTildeInPath }
    let vaultPath: String
    if let v = flagVaultPath {
        vaultPath = v
    } else if let cv = configVaultPath, FileManager.default.fileExists(atPath: cv) {
        vaultPath = cv
    } else {
        vaultPath = defaultVault
    }
    // DB path
    let defaultDb = "\(home)/.obsidian-order/state.sqlite"
    let flagDbPath = flagDb.map { NSString(string: $0).expandingTildeInPath }
    let configDbPath = config.db.map { NSString(string: $0).expandingTildeInPath }
    let dbPath: String
    if let d = flagDbPath {
        dbPath = d
    } else if let cd = configDbPath {
        dbPath = cd
    } else {
        dbPath = defaultDb
    }
    return (vaultPath, dbPath)
}

/// Parse and validate date string (YYYY-MM-DD) or default to today
func resolveDate(input: String?) throws -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    if let d = input {
        guard formatter.date(from: d) != nil else {
            throw ValidationError("Invalid date format: \(d). Expected YYYY-MM-DD.")
        }
        return d
    }
    return formatter.string(from: Date())
}

/// Locate the daily note URL for a given date
func locateDailyNote(vaultPath: String, dateString: String) -> URL {
    let filename = "\(dateString).md"
    let dailyDir = URL(fileURLWithPath: vaultPath).appendingPathComponent("daily")
    let candidate = dailyDir.appendingPathComponent(filename)
    let fm = FileManager.default
    if fm.fileExists(atPath: candidate.path) {
        return candidate
    }
    if let enumr = fm.enumerator(at: dailyDir, includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
        for case let url as URL in enumr {
            if url.lastPathComponent == filename {
                return url
            }
        }
    }
    return URL(fileURLWithPath: vaultPath).appendingPathComponent(filename)
}
// MARK: - End Helpers
// MARK: - Data Loaders
/// Load and parse the daily note document at the given URL
func loadDailyDoc(at url: URL) throws -> Document? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let text = try String(contentsOf: url)
    return try ObsidianModel.parseDocument(text)
}

/// Load tasks for the daily note from the SQLite database
func loadTasks(from db: Connection, noteURL: URL) throws -> [ObsidianModel.Task] {
    let notesTable = Table("notes")
    let tasksTable = Table("tasks")
    let idExp = Expression<Int64>("id")
    let pathExp = Expression<String>("path")
    let lineExp = Expression<Int>("line_no")
    let textExp = Expression<String>("text")
    let stateExp = Expression<String>("state")
    // Find note ID
    guard let row = try db.pluck(notesTable.select(idExp).filter(pathExp == noteURL.path)) else {
        return []
    }
    let noteID = row[idExp]
    var tasks: [ObsidianModel.Task] = []
    for row in try db.prepare(tasksTable.filter(Expression<Int64>("note_id") == noteID)) {
        let stateStr = row[stateExp]
        let state: ObsidianModel.TaskState = stateStr.lowercased() == "done" ? .done : .todo
        let task = ObsidianModel.Task(line: row[lineExp], text: row[textExp], state: state)
        tasks.append(task)
    }
    return tasks
}

/// Load existing meeting summaries (fileName -> summaryText) for the given date
func loadMeetingSummaries(from db: Connection, dateString: String) throws -> [String:String] {
    let notesTable = Table("notes")
    let pathExp = Expression<String>("path")
    let pattern = "%\(dateString)%"
    var summaryMap: [String:String] = [:]
    for row in try db.prepare(notesTable.filter(pathExp.like(pattern))) {
        let fileURL = URL(fileURLWithPath: row[pathExp])
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
              content.contains("Summary::")
        else { continue }
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        if let sumLine = content.components(separatedBy: "\n").first(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Summary::")
        }) {
            // Strip any "Summary::" prefix
            let text = sumLine
                .replacingOccurrences(of: "^Summary::\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            summaryMap[fileName] = text
        }
    }
    return summaryMap
}

/// Fetch calendar events between start and end dates (fallback if no meetings)
func loadCalendarEvents(start: Date, end: Date) -> [GraphEvent] {
    do {
        return try GraphClient().fetchEvents(start: start, end: end)
    } catch {
        return []
    }
}
// MARK: - End Data Loaders


// MARK: - Update Helpers
/// Summarize and update all meeting notes for a date (skipping the daily note itself)
func updateMeetingNotes(in db: Connection, for dateString: String, dailyNoteURL: URL, overwrite: Bool) throws {
    let notesTable = Table("notes")
    let pathExp = Expression<String>("path")
    let pattern = "%\(dateString)%"
    let query = notesTable.filter(pathExp.like(pattern))
    let cfg = try Config.load()
    guard let sumCfg = cfg.summarize_model else {
        throw ValidationError("Missing 'summarize_model' in config; please configure primary and optional fallback")
    }
    let client = OllamaClient(host: cfg.ollamaHostURL, model: sumCfg.primary)
    for row in try db.prepare(query) {
        let fileURL = URL(fileURLWithPath: row[pathExp])
        // skip the daily note itself
        if fileURL.lastPathComponent == dailyNoteURL.lastPathComponent { continue }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8), content.contains("Summary::") else { continue }
        var lines = content.components(separatedBy: "\n")
        var updated = false
        for idx in lines.indices {
            let orig = lines[idx]
            let trimmed = orig.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "Summary::" || trimmed.hasPrefix("Summary:: ✨") || (overwrite && trimmed.hasPrefix("Summary::")) {
                let summary = try client.summarizeWithRetry(system: "You are Summit, an expert at summarizing meeting notes. Provide a concise one-line summary.",
                                                         user: content,
                                                         primaryModel: sumCfg.primary,
                                                         fallbackModel: sumCfg.fallback)
                if let range = orig.range(of: "Summary::") {
                    let prefix = String(orig[..<range.lowerBound])
                    lines[idx] = "\(prefix)Summary:: \(summary)"
                } else {
                    lines[idx] = "Summary:: \(summary)"
                }
                updated = true
                break
            }
        }
        if updated {
            try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            print("✅ Updated meeting note: \(fileURL.lastPathComponent)")
        }
    }
}

/// Summarize and update the daily note's Summary:: line
func updateDailySummary(at noteURL: URL, in db: Connection, for dateString: String, overwrite: Bool) throws {
    let original = try String(contentsOf: noteURL, encoding: .utf8)
    let lines = original.components(separatedBy: "\n")
    guard let sumIdx = lines.firstIndex(where: { $0.starts(with: "Summary::") }) else {
        throw ValidationError("No 'Summary::' line found in daily note")
    }
    let rawSuffix = lines[sumIdx].dropFirst("Summary::".count)
    let suffix = rawSuffix.trimmingCharacters(in: .whitespaces)
    if !overwrite && !suffix.isEmpty && !suffix.lowercased().hasPrefix("needs review") {
        print("ℹ️ Existing summary present and not marked 'Needs Review', skipping update.")
        return
    }
    // Build prompt body by stripping fences and old summary
    var body = original
    let fenceRegex = "(?ms)```(?:dataview|dataviewjs|task)[\\s\\S]*?```"
    body = body.replacingOccurrences(of: fenceRegex, with: "", options: .regularExpression)
    let summaryRegex = "(?m)^Summary::.*$"
    body = body.replacingOccurrences(of: summaryRegex, with: "", options: .regularExpression)
    // Inject meeting summaries
    let meetingSummaries = try loadMeetingSummaries(from: db, dateString: dateString)
    let promptLines = body.components(separatedBy: "\n")
    var injected: [String] = []
    for line in promptLines {
        injected.append(line)
        if line.hasPrefix("### ") {
            let heading = String(line.dropFirst(4))
            if let sum = meetingSummaries[heading] {
                injected.append("Summary:: \(sum)")
            }
        }
    }
    let promptBody = injected.joined(separator: "\n")
    // Summarize daily note
    let cfg = try Config.load()
    guard let sumCfg = cfg.summarize_model else {
        throw ValidationError("Missing 'summarize_model' in config; please configure primary and optional fallback")
    }
    let client = OllamaClient(host: cfg.ollamaHostURL, model: sumCfg.primary)
    let summary = try client.summarizeWithRetry(system: "You are Summit, an expert at summarizing daily notes succinctly.",
                                              user: promptBody,
                                              primaryModel: sumCfg.primary,
                                              fallbackModel: sumCfg.fallback)
    // Write updated summary line
    var outLines = lines
    outLines[sumIdx] = "Summary:: \(summary)"
    try outLines.joined(separator: "\n").write(to: noteURL, atomically: true, encoding: .utf8)
    print("✅ Updated daily note: \(noteURL.lastPathComponent)")
}

/// Render JSON output for the daily report
func renderJSON(doc: Document?, tasks: [ObsidianModel.Task], dateString: String) throws -> String {
    var out: [String: Any] = ["date": dateString]
    if let d = doc {
        out["metadata"] = d.metadata
        out["body"] = d.body
    }
    out["tasks"] = tasks.map { ["line": $0.line, "text": $0.text, "state": ($0.state == .done ? "done" : "todo")] }
    let data = try JSONSerialization.data(withJSONObject: out, options: .prettyPrinted)
    return String(data: data, encoding: .utf8) ?? ""
}

/// Render Markdown output for the daily report
func renderMarkdown(doc: Document?, tasks: [ObsidianModel.Task], meetings: [String:String], dateString: String, noteURL: URL) throws -> String {
    var result = "# Daily Report for \(dateString)\n\n"
    result += "## Daily Note\n\n"
    if let _ = doc {
        var text = try String(contentsOf: noteURL, encoding: .utf8)
        let fenceRegex = "(?ms)```(?:dataview|dataviewjs|task)[\\s\\S]*?```"
        text = text.replacingOccurrences(of: fenceRegex, with: "", options: .regularExpression)
        let summaryRegex = "(?m)^Summary::.*$"
        text = text.replacingOccurrences(of: summaryRegex, with: "", options: .regularExpression)
        let lines = text.components(separatedBy: "\n")
        var final: [String] = []
        for line in lines {
            final.append(line)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("### [[") && trimmed.contains("]]") {
                let open = trimmed.range(of: "[[")!.upperBound
                let close = trimmed.range(of: "]]", options: .backwards)!.lowerBound
                let linkContent = String(trimmed[open..<close])
                let heading = linkContent.split(separator: "|").first.map(String.init) ?? linkContent
                if let sum = meetings[heading] {
                    final.append(sum)
                }
            }
        }
        result += final.joined(separator: "\n") + "\n\n"
    } else {
        result += "_No daily note found._\n\n"
    }
    result += "## Tasks\n\n"
    if tasks.isEmpty {
        result += "_No tasks found._\n\n"
    } else {
        for t in tasks {
            let box = t.state == .done ? "[x]" : "[ ]"
            result += "- \(box) \(t.text)\n"
        }
        result += "\n"
    }
    result += "## Events\n\n"
    let events = loadCalendarEvents(start: ISO8601DateFormatter().date(from: dateString + "T00:00:00Z") ?? Date(),
                                    end: ISO8601DateFormatter().date(from: dateString + "T23:59:59Z") ?? Date())
    if events.isEmpty {
        result += "_No events available._"
    } else {
        for ev in events {
            result += "- \(ev.title) (\(ev.start) - \(ev.end))\n"
        }
    }
    return result
}
