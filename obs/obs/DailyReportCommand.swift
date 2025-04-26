import ArgumentParser
import Foundation
import Darwin  // for fputs, fflush
import ObsidianModel
import SQLite
import Yams
import GraphClient

// MARK: - Helper Functions
private struct CLIConfig: Decodable {
    var vault: String?
    var db: String?
}

/// Resolve vault and DB paths (flag > config file > default)
private func resolvePaths(flagVault: String?, flagDb: String?) -> (vaultPath: String, dbPath: String) {
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
private func resolveDate(input: String?) throws -> String {
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
private func locateDailyNote(vaultPath: String, dateString: String) -> URL {
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
private func loadDailyDoc(at url: URL) throws -> Document? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let text = try String(contentsOf: url)
    return try ObsidianModel.parseDocument(text)
}

/// Load tasks for the daily note from the SQLite database
private func loadTasks(from db: Connection, noteURL: URL) throws -> [ObsidianModel.Task] {
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
private func loadMeetingSummaries(from db: Connection, dateString: String) throws -> [String:String] {
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
private func loadCalendarEvents(start: Date, end: Date) -> [GraphEvent] {
    do {
        return try GraphClient().fetchEvents(start: start, end: end)
    } catch {
        return []
    }
}
// MARK: - End Data Loaders

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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Load CLI config (flag > config file > default)
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
        // Print used paths
        print("Using vault path: \(vaultPath)")
        print("Using DB path:    \(dbPath)")
        // Determine target date (default: today)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString: String
        if let input = date {
            // Validate provided date
            guard dateFormatter.date(from: input) != nil else {
                throw ValidationError("Invalid date format: \(input). Expected YYYY-MM-DD.")
            }
            dateString = input
        } else {
            dateString = dateFormatter.string(from: Date())
        }
        // Locate daily note under ~/Obsidian/daily/ (or year subfolders), or fallback to vault root
        let fm = FileManager.default
        let noteFilename = "\(dateString).md"
        let dailyDirURL = URL(fileURLWithPath: vaultPath).appendingPathComponent("daily")
        // Candidate URL: direct child
        let candidate1 = dailyDirURL.appendingPathComponent(noteFilename)
        // Recursive search under dailyDirURL
        let noteURL: URL = {
            if fm.fileExists(atPath: candidate1.path) {
                return candidate1
            }
            if let enumerator = fm.enumerator(at: dailyDirURL,
                                               includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let url as URL in enumerator {
                    if url.lastPathComponent == noteFilename {
                        return url
                    }
                }
            }
            // Fallback to vault root
            return URL(fileURLWithPath: vaultPath).appendingPathComponent(noteFilename)
        }()
        // Load daily note document
        let doc = try loadDailyDoc(at: noteURL)
        // Open database connection
        let connection = try Connection(dbPath)
        // Prepare for meeting-note lookups
        let notesTable = Table("notes")
        let pathExp = Expression<String>("path")
        // Load tasks from DB
        let tasks = try loadTasks(from: connection, noteURL: noteURL)
        // If --update: regenerate summaries in both meeting notes and daily note
        if update {
            // Summarize and update meeting notes first (overwrite placeholders or existing AI summaries)
            let meetingPattern = "%\(dateString)%"
            let meetingQuery = notesTable.filter(pathExp.like(meetingPattern))
            // Load summarization models
            let cfg = try Config.load()
            guard let sumCfg2 = cfg.summarize_model else {
                throw ValidationError("Missing 'summarize_model' in config; please configure primary and optional fallback")
            }
            let primaryModel2 = sumCfg2.primary
            let fallbackModel2 = sumCfg2.fallback
            let client2 = OllamaClient(host: cfg.ollamaHostURL, model: primaryModel2)
            for row in try connection.prepare(meetingQuery) {
                let fileURL = URL(fileURLWithPath: row[pathExp])
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                // Only update meeting notes that already contain a Summary:: placeholder
                guard content.contains("Summary::") else { continue }
                var lines = content.components(separatedBy: "\n")
                var meetingUpdated = false
                for idx in lines.indices {
                    let orig = lines[idx]
                    let trimmed = orig.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if trimmed == "Summary::" || trimmed == "Summary:: Needs Review" || (overwrite && trimmed.hasPrefix("Summary:: ✨")) {
                        let systemPrompt2 = "You are Summit, an expert at summarizing meeting notes. Provide a concise one-line summary."
                        let summary2 = try client2.summarizeWithRetry(
                            system: systemPrompt2,
                            user: content,
                            primaryModel: primaryModel2,
                            fallbackModel: fallbackModel2
                        )
                        if let range = orig.range(of: "Summary::") {
                            let prefix = String(orig[..<range.lowerBound])
                            lines[idx] = "\(prefix)Summary:: \(summary2)"
                        } else {
                            lines[idx] = "Summary:: \(summary2)"
                        }
                        meetingUpdated = true
                        break
                    }
                }
                if meetingUpdated {
                    let newText = lines.joined(separator: "\n")
                    try newText.write(to: fileURL, atomically: true, encoding: .utf8)
                    print("✅ Updated meeting note: \(fileURL.lastPathComponent)")
                }
            }
            // Load original daily note
            guard let original = try? String(contentsOf: noteURL, encoding: .utf8) else {
                print("❌ Daily note not found at \(noteURL.path)")
                throw ExitCode(1)
            }
            let lines = original.components(separatedBy: "\n")
            // Find Summary:: placeholder
            guard let sumIdx = lines.firstIndex(where: { $0.starts(with: "Summary::") }) else {
                print("❌ No 'Summary::' line found in \(noteURL.lastPathComponent)")
                throw ExitCode(1)
            }
            let rawSuffix = lines[sumIdx].dropFirst("Summary::".count)
            let suffix = rawSuffix.trimmingCharacters(in: CharacterSet.whitespaces)
            let lowerSuffix = suffix.lowercased()
            // Only proceed if empty or marked 'Needs Review' (with or without trailing period)
            guard overwrite || suffix.isEmpty || lowerSuffix.hasPrefix("needs review") else {
                print("ℹ️ Existing summary present and not marked 'Needs Review', skipping update.")
                throw ExitCode(0)
            }
            // Build clean prompt by stripping dataview/task fences and old Summary line
            var promptBody = original
            let fenceRegex = "(?ms)```(?:dataview|dataviewjs|task)[\\s\\S]*?```"
                promptBody = promptBody.replacingOccurrences(
                    of: fenceRegex,
                    with: "",
                    options: String.CompareOptions.regularExpression
                )
            let summaryRegex = "(?m)^Summary::.*$"
            promptBody = promptBody.replacingOccurrences(
                of: summaryRegex,
                with: "",
                options: String.CompareOptions.regularExpression
            )
            // Strip inline dataview summary queries (e.g., `= [[...]].Summary`)
            let inlineSummaryRegex = "(?m)^`[^`]*\\.Summary[^`]*`$"
            promptBody = promptBody.replacingOccurrences(
                of: inlineSummaryRegex,
                with: "",
                options: String.CompareOptions.regularExpression
            )
            // Insert meeting summaries under each "###" heading in the prompt
            var summaryMap: [String: String] = [:]
            // Build SQL LIKE pattern matching files containing the date
            let meetingPatternExpr = "%\(dateString)%"
                for row in try connection.prepare(notesTable.filter(pathExp.like(meetingPatternExpr))) {
                    let fileURL = URL(fileURLWithPath: row[pathExp])
                    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                    // Only include files that have an existing Summary:: line
                    guard content.contains("Summary::") else { continue }
                    let fileName = fileURL.deletingPathExtension().lastPathComponent
                    // Extract the first Summary:: line
                    if let sumLine = content
                        .components(separatedBy: "\n")
                        .first(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Summary::") }) {
                        let summaryText = sumLine
                            .replacingOccurrences(of: "^Summary::\\s*", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        summaryMap[fileName] = summaryText
                    }
                }
            let promptLines = promptBody.components(separatedBy: "\n")
            var injected: [String] = []
            for line in promptLines {
                injected.append(line)
                if line.hasPrefix("### ") {
                    let heading = String(line.dropFirst(4))
                    if let summary = summaryMap[heading] {
                        injected.append("Summary:: \(summary)")
                    }
                }
            }
            promptBody = injected.joined(separator: "\n")
            // Construct prompt
            let systemPrompt = "You are Summit, an expert at summarizing daily notes succinctly."
            let userPrompt = "Summarize the following daily journal for \(dateString):\n\n" + promptBody
            // Call summarizer with spinner
            let config = try Config.load()
            // Ensure summarization models are configured
            guard let sumCfg = config.summarize_model else {
                throw ValidationError("Missing 'summarize_model' in config; please configure primary and optional fallback")
            }
            let primaryModel = sumCfg.primary
            let fallbackModel = sumCfg.fallback
            let client = OllamaClient(host: config.ollamaHostURL, model: primaryModel)
            // Spinner thread
            var spinning = true
            let spinnerChars = ["|", "/", "-", "\\"]
            let spinnerThread = Thread {
                var idx = 0
                while spinning {
                    let frame = spinnerChars[idx % spinnerChars.count]
                    fputs("\r\(frame) Summarizing daily note \(dateString)", stdout)
                    fflush(stdout)
                    idx += 1
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            spinnerThread.start()
            // Perform summarization with retry
            let summaryText = try client.summarizeWithRetry(
                system: systemPrompt,
                user: userPrompt,
                primaryModel: primaryModel,
                fallbackModel: fallbackModel
            )
            // Stop spinner
            spinning = false
            fputs("\r", stdout)
            // Write only the updated Summary:: line into the daily note file
            var updatedLines = lines
            updatedLines[sumIdx] = "Summary:: \(summaryText)"
            let updatedText = updatedLines.joined(separator: "\n")
            try updatedText.write(to: noteURL, atomically: true, encoding: .utf8)
            print("✅ Updated daily note: \(noteURL.lastPathComponent)")
            return
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
            if let _ = doc {
                // Show cleaned in-memory note (dataview/task fences and old summaries removed)
                // Read original note text
                let original = try String(contentsOf: noteURL, encoding: .utf8)
                // Strip dataview/dataviewjs/task code fences
                let fenceRegex = "(?ms)```(?:dataview|dataviewjs|task)[\\s\\S]*?```"
                var promptBody = original.replacingOccurrences(
                    of: fenceRegex,
                    with: "",
                    options: String.CompareOptions.regularExpression
                )
                // Strip existing Summary:: lines
                let summaryRegex = "(?m)^Summary::.*$"
                promptBody = promptBody.replacingOccurrences(
                    of: summaryRegex,
                    with: "",
                    options: String.CompareOptions.regularExpression
                )
                // Strip inline dataview summary queries (e.g., `= [[...]].Summary`)
                let inlineSummaryRegex = "(?m)^`[^`]*\\.Summary[^`]*`$"
                promptBody = promptBody.replacingOccurrences(
                    of: inlineSummaryRegex,
                    with: "",
                    options: String.CompareOptions.regularExpression
                )
                // Insert meeting note summaries into the cleaned prompt under each meeting heading
                var summaryMap: [String: String] = [:]
                let meetingPattern = "%\(dateString)%"
                for row in try connection.prepare(notesTable.filter(pathExp.like(meetingPattern))) {
                    let fileURL = URL(fileURLWithPath: row[pathExp])
                    guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                    // Only include files that have an existing Summary:: line
                    guard content.contains("Summary::") else { continue }
                    let fileName = fileURL.deletingPathExtension().lastPathComponent
                    // Extract the first Summary:: line
                    if let sumLine = content.components(separatedBy: "\n").first(where: {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Summary::")
                    }) {
                        // Strip leading "Summary::" and any stray occurrences
                        var summaryText = sumLine
                            .replacingOccurrences(of: "^Summary::\\s*", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        summaryText = summaryText
                            .replacingOccurrences(of: "Summary::", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        summaryMap[fileName] = summaryText
                    }
                }
                // DEBUG: log loaded meeting summary keys
                print("DEBUG: meeting summaries loaded for \(dateString): \(Array(summaryMap.keys))")
                let promptLines = promptBody.components(separatedBy: "\n")
                var finalLines: [String] = []
                for line in promptLines {
                    finalLines.append(line)
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Match headings of form "### [[FileName]]" and extract FileName
                    if trimmed.hasPrefix("### [["),
                       let open = trimmed.range(of: "[["),
                       let close = trimmed.range(of: "]]", options: .backwards) {
                        let linkContent = String(trimmed[open.upperBound..<close.lowerBound])
                        let headingName = linkContent.components(separatedBy: "|").first ?? linkContent
                        if let summary = summaryMap[headingName] {
                            // Append only the summary text itself
                            finalLines.append(summary)
                        }
                    }
                }
                let finalPrompt = finalLines.joined(separator: "\n")
                // DEBUG: log number of summaries injected
                let injectedCount = finalLines.count - promptLines.count
                print("DEBUG: injected \(injectedCount) meeting summaries")
                print(finalPrompt + "\n")
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
}
