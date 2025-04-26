import ArgumentParser
import Foundation
import Darwin  // for fputs, fflush
import ObsidianModel
import SQLite
import Yams

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
        var doc: Document? = nil
        if fm.fileExists(atPath: noteURL.path) {
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
        // If --update, regenerate full-day summary and inject into the daily note, then exit
        if update {
            // Summarize and update meeting notes first (overwrite placeholders or existing AI summaries)
            let meetingPattern = "%meeting-notes%\(dateString)%"
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
                let path = row[pathExp]
                let fileURL = URL(fileURLWithPath: path)
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                var lines = content.components(separatedBy: "\n")
                var meetingUpdated = false
                for idx in lines.indices {
                    let orig = lines[idx]
                    let trimmed = orig.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let suffix = rawSuffix.trimmingCharacters(in: .whitespaces)
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
                options: .regularExpression
            )
            let summaryRegex = "(?m)^Summary::.*$"
            promptBody = promptBody.replacingOccurrences(
                of: summaryRegex,
                with: "",
                options: .regularExpression
            )
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
            // Inject into lines and write updated note
            var updatedLines = lines
            updatedLines[sumIdx] = "Summary:: \(summaryText)"
            let updated = updatedLines.joined(separator: "\n")
            try updated.write(to: noteURL, atomically: true, encoding: .utf8)
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
}