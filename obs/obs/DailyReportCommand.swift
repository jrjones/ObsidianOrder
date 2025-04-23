import ArgumentParser
import Foundation
import ObsidianModel
import SQLite

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
}