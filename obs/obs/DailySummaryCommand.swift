import ArgumentParser
import Foundation
import Darwin
import SQLite
import GraphClient
import ObsidianModel

/// `obs daily-summary` command: generate a summary of notes, tasks, and meetings for a given date
struct DailySummary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daily-summary",
        abstract: "Generate a markdown or JSON summary of notes, tasks, and meetings for a given date"
    )
    @Option(name: .long, help: "Path to Obsidian vault (default: ~/Obsidian)")
    var vault: String?
    @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
    var db: String?
    @Argument(help: "Date in YYYY-MM-DD format (default: today)")
    var date: String?
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false

    func run() throws {
        // Determine database path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        _ = vault  // vault override not used; note paths are absolute in DB
        let dbPath = db ?? "\(home)/.obsidian-order/state.sqlite"

        // Parse date
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = date ?? dateFormatter.string(from: Date())
        guard let summaryDate = dateFormatter.date(from: dateString) else {
            throw ValidationError("Invalid date format: \(dateString). Expected YYYY-MM-DD.")
        }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: summaryDate)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
            throw ValidationError("Failed to compute end of day for \(dateString)")
        }
        let startTS = startOfDay.timeIntervalSince1970
        let endTS = endOfDay.timeIntervalSince1970

        // Open database
        let conn = try Connection(dbPath)
        let notesTable = Table("notes")
        let tasksTable = Table("tasks")
        let idExp = Expression<Int64>("id")
        let titleExp = Expression<String>("title")
        let pathExp = Expression<String>("path")
        let modifiedExp = Expression<Double>("modified")
        let noteIdExp = Expression<Int64>("note_id")
        let lineExp = Expression<Int>("line_no")
        let textExp = Expression<String>("text")
        let stateExp = Expression<String>("state")

        // Fetch notes modified today
        var notes: [(id: Int64, title: String, path: String)] = []
        for row in try conn.prepare(notesTable.filter(modifiedExp >= startTS && modifiedExp < endTS)) {
            notes.append((row[idExp], row[titleExp], row[pathExp]))
        }

        // Fetch tasks for those notes
        var tasksDone: [(line: Int, text: String, note: String)] = []
        var tasksTodo: [(line: Int, text: String, note: String)] = []
        for note in notes {
            for row in try conn.prepare(tasksTable.filter(noteIdExp == note.id)) {
                let line = row[lineExp]
                let text = row[textExp]
                let state = row[stateExp].lowercased()
                if state == "done" {
                    tasksDone.append((line, text, note.title))
                } else {
                    tasksTodo.append((line, text, note.title))
                }
            }
        }

        // Process meeting notes: generate AI summaries and update files
        let config = try Config.load()
        // Ensure summarization models are configured
        guard let sumCfg = config.summarize_model else {
            throw ValidationError("Missing 'summarize_model' in config; please configure primary and optional fallback")
        }
        let hostURL = config.ollamaHostURL
        let primaryModel = sumCfg.primary
        let fallbackModel = sumCfg.fallback
        let client = OllamaClient(host: hostURL, model: primaryModel)
        var meetingSummaries: [(title: String, summary: String, tasks: [ObsidianModel.Task])] = []
        // Query meeting notes from database by path pattern matching the meeting-notes folder and date
        let pattern = "%meeting-notes%\(dateString)%"
        let meetingQuery = notesTable.filter(pathExp.like(pattern))
        for row in try conn.prepare(meetingQuery) {
            let title = row[titleExp]
            let path = row[pathExp]
            let fileURL = URL(fileURLWithPath: path)
            let content = try String(contentsOf: fileURL)
            var lines = content.components(separatedBy: "\n")
            var updated = false
            for idx in lines.indices {
                let originalLine = lines[idx]
                let trimmed = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "Summary::" || trimmed == "Summary:: Needs Review" {
                    let systemPrompt = "You are Summit, an expert at summarizing meeting notes. Provide a concise one-line summary."
                    // Spinner
                    var spinning = true
                    let spinnerChars = ["|", "/", "-", "\\"]
                    let spinnerThread = Thread {
                        var i = 0
                        while spinning {
                            let frame = spinnerChars[i % spinnerChars.count]
                            fputs("\r\(frame) Summarizing \(title)", stdout)
                            fflush(stdout)
                            i += 1
                            Thread.sleep(forTimeInterval: 0.1)
                        }
                    }
                    spinnerThread.start()
                    // Summarize with retry (strips <think> and prefixes emoji)
                    let summary = try client.summarizeWithRetry(
                        system: systemPrompt,
                        user: content,
                        primaryModel: primaryModel,
                        fallbackModel: fallbackModel
                    )
                    spinning = false
                    fputs("\r", stdout)
                    // Inject summary
                    if let range = originalLine.range(of: "Summary::") {
                        let prefix = String(originalLine[..<range.lowerBound])
                        lines[idx] = "\(prefix)Summary:: \(summary)"
                    } else {
                        lines[idx] = "Summary:: \(summary)"
                    }
                    updated = true
                    let doc = try ObsidianModel.parseDocument(content)
                    let mTasks = ObsidianModel.parseTasks(doc.body)
                    meetingSummaries.append((title: title, summary: summary, tasks: mTasks))
                    break
                }
            }
            if updated {
                let newText = lines.joined(separator: "\n")
                try newText.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
        // Fetch calendar events (fallback if no meeting notes)
        var events: [GraphEvent] = []
        do {
            events = try GraphClient().fetchEvents(start: startOfDay, end: endOfDay)
        } catch {
            events = []
        }

        // Output
        if json {
            // JSON output
            var output: [String: Any] = ["date": dateString]
            output["notes"] = notes.map { ["id": $0.id, "title": $0.title, "path": $0.path] }
            output["tasks_done"] = tasksDone.map { ["line": $0.line, "text": $0.text, "note": $0.note] }
            output["tasks_todo"] = tasksTodo.map { ["line": $0.line, "text": $0.text, "note": $0.note] }
            let isoFmt = ISO8601DateFormatter()
            // JSON meetings or events
            if !meetingSummaries.isEmpty {
                output["meetings"] = meetingSummaries.map { meeting in
                    ["title": meeting.title,
                     "summary": meeting.summary,
                     "tasks": meeting.tasks.map { ["line": $0.line, "text": $0.text, "state": ($0.state == .done ? "done" : "todo")] }
                    ] as [String: Any]
                }
            } else {
                output["events"] = events.map { evt in
                    ["id": evt.id,
                     "title": evt.title,
                     "start": isoFmt.string(from: evt.start),
                     "end": isoFmt.string(from: evt.end),
                     "location": evt.location ?? "",
                     "isVirtual": evt.isVirtual] as [String: Any]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: .prettyPrinted)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            // Markdown output
            let isoFmt = ISO8601DateFormatter()
            print("# Daily Summary for \(dateString)\n")
            // Notes section
            print("## 📄 Notes created\n")
            if notes.isEmpty {
                print("_No notes modified or created on this date._\n")
            } else {
                for note in notes {
                    print("- \(note.title) (\(note.path))")
                }
                print("")
            }
            // Tasks section
            print("## 📌 Tasks completed / still open\n")
            if tasksDone.isEmpty && tasksTodo.isEmpty {
                print("_No tasks found._\n")
            } else {
                for t in tasksDone {
                    print("- [x] \(t.text) (\(t.note), line \(t.line))")
                }
                for t in tasksTodo {
                    print("- [ ] \(t.text) (\(t.note), line \(t.line))")
                }
                print("")
            }
            // Meetings section
            print("## 🤝 Meetings\n")
            if !meetingSummaries.isEmpty {
                for meeting in meetingSummaries {
                    print("- \(meeting.title): ✨\(meeting.summary)")
                    for task in meeting.tasks {
                        let checkbox = task.state == .done ? "[x]" : "[ ]"
                        print("  - \(checkbox) \(task.text)")
                    }
                }
            } else if !events.isEmpty {
                for evt in events {
                    let start = isoFmt.string(from: evt.start)
                    let end = isoFmt.string(from: evt.end)
                    if let loc = evt.location, !loc.isEmpty {
                        print("- \(start) to \(end): \(evt.title) @ \(loc)")
                    } else {
                        print("- \(start) to \(end): \(evt.title)")
                    }
                }
            } else {
                print("_No meetings found._")
            }
        }
    }
}
