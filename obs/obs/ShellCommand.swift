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
    @Option(name: .long, help: "Maximum number of rows to display (0 = no limit, default: 100)")
    var rowLimit: Int = 100

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
        // Switch terminal to raw mode
        var oldt = termios()
        tcgetattr(STDIN_FILENO, &oldt)
        var raw = oldt
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        raw.c_cc.2 = 1  // VMIN
        raw.c_cc.6 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer { tcsetattr(STDIN_FILENO, TCSANOW, &oldt) }

        var buffer = ""
        var history: [String] = []
        var historyIndex: Int? = nil

        let promptMain = "obs> "
        let promptCont = "...> "

        loop: while true {
            let prompt = buffer.isEmpty ? promptMain : promptCont
            fputs(prompt, stdout)
            fflush(stdout)

            // Read raw input (handle backspace and arrows)
            var lineBytes: [UInt8] = []
            historyIndex = nil
            rawLoop: while true {
                var b: UInt8 = 0
                let n = read(STDIN_FILENO, &b, 1)
                if n <= 0 {
                    fputs("\n", stdout)
                    return
                }
                switch b {
                case 0x0A, 0x0D:
                    fputs("\n", stdout)
                    break rawLoop
                case 0x7F, 0x08:
                    if !lineBytes.isEmpty {
                        lineBytes.removeLast()
                        fputs("\u{8} \u{8}", stdout)
                        fflush(stdout)
                    }
                case 0x1B:
                    // Arrow key sequence
                    var seq1: UInt8 = 0, seq2: UInt8 = 0
                    let m1 = read(STDIN_FILENO, &seq1, 1)
                    let m2 = read(STDIN_FILENO, &seq2, 1)
                    guard m1 > 0 && m2 > 0 && seq1 == UInt8(ascii: "[") else { continue }
                    let promptText = buffer.isEmpty ? promptMain : promptCont
                    if seq2 == UInt8(ascii: "A") {
                        // Up arrow
                        guard !history.isEmpty else { continue }
                        if historyIndex == nil {
                            historyIndex = history.count - 1
                        } else if historyIndex! > 0 {
                            historyIndex! -= 1
                        }
                        let entry = history[historyIndex!]
                        fputs("\r\u{1B}[2K", stdout)
                        fputs(promptText, stdout)
                        fputs(entry, stdout)
                        fflush(stdout)
                        lineBytes = Array(entry.utf8)
                    } else if seq2 == UInt8(ascii: "B") {
                        // Down arrow
                        guard !history.isEmpty else { continue }
                        if let idx = historyIndex {
                            if idx < history.count - 1 {
                                historyIndex! += 1
                                let entry = history[historyIndex!]
                                fputs("\r\u{1B}[2K", stdout)
                                fputs(promptText, stdout)
                                fputs(entry, stdout)
                                fflush(stdout)
                                lineBytes = Array(entry.utf8)
                            } else {
                                historyIndex = nil
                                fputs("\r\u{1B}[2K", stdout)
                                fputs(promptText, stdout)
                                fflush(stdout)
                                lineBytes = []
                            }
                        }
                    }
                default:
                    lineBytes.append(b)
                    var c = b
                    _ = write(STDIN_FILENO, &c, 1)
                    fflush(stdout)
                }
            }

            let line = String(decoding: lineBytes, as: UTF8.self)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Built-in commands
            if buffer.isEmpty && trimmed.hasPrefix("\\") {
                history.append(trimmed)
                historyIndex = nil
                let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
                let cmdRaw = parts[0], arg = parts.count > 1 ? parts[1] : nil
                let cmd = cmdRaw.lowercased()
                switch cmd {
                case "\\q", "\\quit":
                    return
                case "\\tables":
                    runAndPrint(query: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", dbHandle: dbHandle)
                case "\\desc":
                    if let tbl = arg?.lowercased() {
                        runAndPrint(query: "PRAGMA table_info(\(tbl))", dbHandle: dbHandle)
                    } else {
                        print("Usage: \\desc <table>")
                    }
                case "\\ask":
                    if let q = arg { print("ask not implemented yet: \(q)") }
                    else { print("Usage: \\ask <query>") }
                case "\\open":
                    if let s = arg, let nid = Int64(s) {
                        guard let db = dbHandle else {
                            print("Database not available")
                            break
                        }
                        var stmt2: OpaquePointer? = nil
                        let openSQL = "SELECT path FROM notes WHERE id = ?1 LIMIT 1"
                        if sqlite3_prepare_v2(db, openSQL, -1, &stmt2, nil) == SQLITE_OK {
                            sqlite3_bind_int64(stmt2, 1, nid)
                            if sqlite3_step(stmt2) == SQLITE_ROW,
                               let cstr = sqlite3_column_text(stmt2, 0) {
                                let path = String(cString: cstr)
                                if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                                    let uri = "obsidian://open?path=\(encoded)"
                                    let proc = Process()
                                    proc.launchPath = "/usr/bin/open"
                                    proc.arguments = [uri]
                                    do { try proc.run() }
                                    catch { print("Failed to open URI \(uri): \(error)") }
                                } else {
                                    print("Invalid path for URI: \(path)")
                                }
                            } else {
                                print("No note found with id: \(nid)")
                            }
                            sqlite3_finalize(stmt2)
                        } else {
                            let err = String(cString: sqlite3_errmsg(db))
                            print("Error preparing open: \(err)")
                        }
                    } else {
                        print("Usage: \\open <id>")
                    }
                default:
                    print("Unknown command: \(cmdRaw)")
                }
                continue
            }

            // Blank line runs pending SQL buffer
            if !buffer.isEmpty && trimmed.isEmpty {
                let sql = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                history.append(sql)
                historyIndex = nil
                runAndPrint(query: sql, dbHandle: dbHandle)
                buffer = ""
                continue
            }

            // Skip pure blank when no buffer
            if buffer.isEmpty && trimmed.isEmpty {
                continue
            }

            // Accumulate SQL lines
            buffer += line + "\n"
            let stmt = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if stmt.hasSuffix(";") {
                let sql = String(stmt.dropLast())
                history.append(sql)
                historyIndex = nil
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
        let maxRows = rowLimit
        var rowsTruncated = false
        while true {
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_ROW { break }
            // Enforce row limit if > 0
            if maxRows > 0 && rows.count >= maxRows {
                rowsTruncated = true
                break
            }
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
        // Helper to build ANSI hyperlink
        func hyperlink(_ text: String, uri: String) -> String {
            let escStart = "\u{001B}]8;;\(uri)\u{0007}"
            let escEnd = "\u{001B}]8;;\u{0007}"
            return "\(escStart)\(text)\(escEnd)"
        }
        // Determine if hyperlinks are supported (e.g. iTerm2)
        let termProgram = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? ""
        let useHyperlinks = (termProgram == "iTerm.app")
        // Print rows
        for row in rows {
            var rowLine = ""
            for i in 0..<colCount {
                let rawVal = row[i]
                let width = colWidths[i]
                let lowerName = colNames[i].lowercased()
                let cellOutput: String
                if lowerName == "path", let encoded = rawVal.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    // Truncate raw path text, pad it, then wrap in hyperlink
                    let trunc = truncated(rawVal, to: width)
                    let padded = trunc.padding(toLength: width, withPad: " ", startingAt: 0)
                    let uri = "obsidian://open?path=\(encoded)"
                    cellOutput = hyperlink(padded, uri: uri)
                } else {
                    // Normal cell: truncate and pad
                    let trunc = truncated(rawVal, to: width)
                    cellOutput = trunc.padding(toLength: width, withPad: " ", startingAt: 0)
                }
                rowLine += cellOutput
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