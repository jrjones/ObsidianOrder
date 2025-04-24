import ArgumentParser
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif
import SQLite3
import Yams

/// `obs shell` command: interactive REPL for ad-hoc SQL and built-in commands
struct Shell: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell",
        abstract: "Interactive SQL REPL and built-in commands"
    )

    @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
    var db: String?

    func run() throws {
        // Determine home directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Load CLI config (optional)
        struct CLIConfig: Decodable { var db: String? }
        let configPath = "\(home)/.config/obsidian-order/config.yaml"
        var config = CLIConfig(db: nil)
        if FileManager.default.fileExists(atPath: configPath) {
            do {
                let yamlText = try String(contentsOfFile: configPath)
                let decoder = YAMLDecoder()
                config = try decoder.decode(CLIConfig.self, from: yamlText)
            } catch {
                print("Warning: failed to parse config at \(configPath): \(error)")
            }
        }
        // Determine database path (flag > config > default), expanding ~ and validating config path
        let defaultDbPath = "\(home)/.obsidian-order/state.sqlite"
        // Expand db flag and config db paths
        let flagDbPath = db.map { NSString(string: $0).expandingTildeInPath }
        let configDbRaw = config.db
        let configDbPath = configDbRaw.map { NSString(string: $0).expandingTildeInPath }
        // Choose database path: flag > valid config > default
        let dbPath: String
        if let path = flagDbPath {
            dbPath = path
        } else if let cfgPath = configDbPath, FileManager.default.fileExists(atPath: cfgPath) {
            dbPath = cfgPath
        } else {
            if let cfgPath = configDbPath {
                print("Warning: config db path does not exist at \(cfgPath), using default.")
            }
            dbPath = defaultDbPath
        }

        // Open SQLite database (C API)
        var dbHandle: OpaquePointer?
        if sqlite3_open(dbPath, &dbHandle) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(dbHandle))
            throw RuntimeError("Unable to open database at \(dbPath): \(msg)")
        }
        defer { sqlite3_close(dbHandle) }

        print("Connected to database at \(dbPath). Type \"\\q\" to exit.")
        replLoop(dbHandle: dbHandle)
    }

    private func replLoop(dbHandle: OpaquePointer?) {
        var buffer = ""
        while true {
            // Choose prompt: new stmt or continuation
            let prompt = buffer.isEmpty ? "obs> " : "...> "
            print(prompt, terminator: "")
            fflush(stdout)
            guard let line = readLine(strippingNewline: true) else {
                print("")
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip empty input when no buffer
            if buffer.isEmpty && trimmed.isEmpty {
                continue
            }
            // Built-in commands (only when no buffer)
            if buffer.isEmpty && trimmed.hasPrefix("\\") {
                let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
                let cmd = parts[0]
                let arg = parts.count > 1 ? parts[1] : nil
                switch cmd {
                case "\\q", "\\quit":
                    return
                case "\\tables":
                    runAndPrint(query: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", dbHandle: dbHandle)
                case "\\desc":
                    if let table = arg {
                        let sql = "PRAGMA table_info(\(table))"
                        runAndPrint(query: sql, dbHandle: dbHandle)
                    } else {
                        print("Usage: \\desc <table>")
                    }
                case "\\ask":
                    if let q = arg {
                        print("ask not implemented yet: \(q)")
                    } else {
                        print("Usage: \\ask <query>")
                    }
                default:
                    print("Unknown command: \(cmd)")
                }
                continue
            }
            // Accumulate SQL lines
            buffer += line + "\n"
            let stmtText = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            // Execute when statement ends with semicolon
            if stmtText.hasSuffix(";") {
                // Remove trailing semicolon
                let sql = String(stmtText.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                runAndPrint(query: sql, dbHandle: dbHandle)
                buffer = ""
            }
        }
    }

    /// Execute SQL query and print up to 50 rows with aligned columns
    private func runAndPrint(query: String, dbHandle: OpaquePointer?) {
        guard let db = dbHandle else { return }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            print("SQL Error: \(msg)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let colCount = Int(sqlite3_column_count(stmt))
        // Column names
        var colNames = [String]()
        for i in 0..<colCount {
            if let cname = sqlite3_column_name(stmt, Int32(i)) {
                colNames.append(String(cString: cname))
            } else {
                colNames.append("")
            }
        }
        // Fetch rows
        var rows = [[String]]()
        let maxRows = 50
        var rowsTruncated = false
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                if rows.count < maxRows {
                    var rowVals = [String]()
                    for i in 0..<colCount {
                        let ctype = sqlite3_column_type(stmt, Int32(i))
                        let val: String
                        switch ctype {
                        case SQLITE_INTEGER:
                            val = String(sqlite3_column_int64(stmt, Int32(i)))
                        case SQLITE_FLOAT:
                            val = String(sqlite3_column_double(stmt, Int32(i)))
                        case SQLITE_TEXT:
                            if let cstr = sqlite3_column_text(stmt, Int32(i)) {
                                val = String(cString: cstr)
                            } else { val = "" }
                        case SQLITE_NULL:
                            val = "NULL"
                        case SQLITE_BLOB:
                            val = "<BLOB>"
                        default:
                            val = "?"
                        }
                        rowVals.append(val)
                    }
                    rows.append(rowVals)
                } else {
                    rowsTruncated = true
                    break
                }
            } else {
                break
            }
        }
        // Compute natural column widths (header vs cell content)
        let sepWidth = 3 // " | "
        let naturalWidths: [Int] = (0..<colCount).map { i in
            let headerW = colNames[i].count
            let maxCell = rows.map { $0[i].count }.max() ?? 0
            return max(headerW, maxCell)
        }
        // Compute total natural width including separators
        let totalNatural = naturalWidths.reduce(0, +)
        let sepTotal = sepWidth * max(0, colCount - 1)
        let totalWidth = totalNatural + sepTotal
        var colWidths: [Int]
        if let tw = getTerminalWidth(), totalWidth > tw {
            // Available space for columns
            let avail = tw - sepTotal
            var remaining = Array(0..<colCount)
            var alloc = [Int](repeating: 0, count: colCount)
            var availRem = avail
            // Fix columns whose natural width <= average
            while true {
                let remCount = remaining.count
                guard remCount > 0 else { break }
                let avg = availRem / remCount
                let fixed = remaining.filter { naturalWidths[$0] <= avg }
                if fixed.isEmpty { break }
                for idx in fixed {
                    alloc[idx] = naturalWidths[idx]
                    availRem -= naturalWidths[idx]
                }
                remaining.removeAll { fixed.contains($0) }
            }
            // Distribute remaining space evenly among remaining columns
            if !remaining.isEmpty {
                let remCount = remaining.count
                let per = availRem / remCount
                var left = availRem - per * remCount
                for idx in remaining {
                    alloc[idx] = per + (left > 0 ? 1 : 0)
                    if left > 0 { left -= 1 }
                }
            }
            colWidths = alloc
            print("Note: table width (\(totalWidth)) exceeds terminal width (\(tw)); columns adjusted to fit")
        } else {
            colWidths = naturalWidths
        }
        // Helper to truncate cell value with ellipsis
        func truncated(_ text: String, to length: Int) -> String {
            if text.count <= length { return text }
            if length <= 1 { return String(text.prefix(length)) }
            let idx = text.index(text.startIndex, offsetBy: length - 1)
            return String(text[..<idx]) + "…"
        }
        // Print header
        var headerLine = ""
        for i in 0..<colCount {
            let h = truncated(colNames[i], to: colWidths[i])
            headerLine += h.padding(toLength: colWidths[i], withPad: " ", startingAt: 0)
            if i < colCount - 1 { headerLine += " | " }
        }
        print(headerLine)
        // Print separator
        var sepLine = ""
        for i in 0..<colCount {
            sepLine += String(repeating: "-", count: colWidths[i])
            if i < colCount - 1 { sepLine += " | " }
        }
        print(sepLine)
        // Print rows
        for row in rows {
            var rowLine = ""
            for i in 0..<colCount {
                let cell = truncated(row[i], to: colWidths[i])
                rowLine += cell.padding(toLength: colWidths[i], withPad: " ", startingAt: 0)
                if i < colCount - 1 { rowLine += " | " }
            }
            print(rowLine)
        }
        if rowsTruncated {
            print("-- output truncated at \(maxRows) rows --")
        }
    }

    /// Attempts to read the terminal width (columns)
    private func getTerminalWidth() -> Int? {
        #if os(Linux) || os(macOS)
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            let cols = Int(ws.ws_col)
            if cols > 0 { return cols }
        }
        #endif
        return nil
    }
}

// Simple runtime error type
struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}