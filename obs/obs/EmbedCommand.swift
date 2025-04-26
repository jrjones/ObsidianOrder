import ArgumentParser
import Foundation
import SQLite

/// `obs embed` command: compute embeddings for notes and store them in DB
struct Embed: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "embed",
        abstract: "Compute and store embeddings for notes"
    )

    @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
    var db: String?
    
    @Option(name: .long, help: "Ollama host URL (overrides config)")
    var host: String?
    
    @Option(name: .long, help: "Embedding model identifier (overrides config)")
    var model: String?
    /// If set, clear all existing embeddings before running
    @Flag(name: .long, help: "Reset existing embeddings and re-embed entire vault")
    var reset: Bool = false

    @Option(name: .long, help: "Embed notes modified since this ISO8601 timestamp")
    var since: String?

    func run() throws {
        // Load CLI config
        let config = try Config.load()

        // Determine database path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = db ?? config.db ?? "\(home)/.obsidian-order/state.sqlite"
        let connection = try Connection(dbPath)

        // Optionally reset all embeddings
        if reset {
            print("Resetting all embeddings…")
            // Null out existing embedding blobs and timestamps
            try connection.run("UPDATE notes SET embedding = NULL, last_embedded = NULL")
        }
        // Ensure embedding columns exist
        do { try connection.run("ALTER TABLE notes ADD COLUMN embedding BLOB") } catch { }
        do { try connection.run("ALTER TABLE notes ADD COLUMN last_embedded DOUBLE") } catch { }

        // Table and expressions
        let notes = Table("notes")
        let idExp = Expression<Int64>("id")
        let pathExp = Expression<String>("path")
        let modifiedExp = Expression<Double>("modified")
        let lastEmbExp = Expression<Double?>("last_embedded")

        // Build filter: use --since if provided, else incremental since last_embedded
        // Use Expression<Bool?> to handle optional comparators
        let filter: SQLite.Expression<Bool?>
        if let sinceStr = since {
            // Parse ISO8601 timestamp, falling back to plain yyyy-MM-dd
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFullDate]
            var sinceDate = isoFormatter.date(from: sinceStr)
            if sinceDate == nil {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "yyyy-MM-dd"
                df.timeZone = TimeZone.current
                sinceDate = df.date(from: sinceStr)
            }
            guard let sinceDateUnwrapped = sinceDate else {
                throw ValidationError("Invalid --since timestamp: \(sinceStr)")
            }
            let sinceTS = sinceDateUnwrapped.timeIntervalSince1970
            // Embed notes modified since given timestamp
            // Compare as optional to unify with default optional filter type
            filter = SQLite.Expression<Double?>(modifiedExp) > sinceTS
        } else {
            // Default: never embedded or modified since last_embedded
            filter = lastEmbExp == nil || modifiedExp > lastEmbExp
        }
        let toEmbed = notes.filter(filter)
        // Determine Ollama host and model
        let hostString = host ?? config.ollamaHostURL.absoluteString
        guard let hostURL = URL(string: hostString) else {
            throw ValidationError("Invalid host URL: \(hostString)")
        }
        // Determine embedding model: CLI flag > config.yaml > default
        let modelName = model ?? config.embedding_model ?? "ollama/nomic-embed-text"
        print("Embedding notes using Ollama host: \(hostURL), model: \(modelName)")
        let client = OllamaClient(host: hostURL, model: modelName)

        var success = 0
        var failures = 0
        for row in try connection.prepare(toEmbed) {
            let noteID = row[idExp]
            let filePath = row[pathExp]
            do {
                // Read file text
                let text = try String(contentsOfFile: filePath)
                // Generate embedding
                let vector = try client.embed(text: text)
                // Convert to blob data
                var vec = vector
                let blobData = Data(bytes: &vec, count: vector.count * MemoryLayout<Double>.size)
                let blob = Blob(bytes: [UInt8](blobData))
                let nowTS = Date().timeIntervalSince1970
                // Update record
                let update = notes.filter(idExp == noteID).update(
                    Expression<Blob>("embedding") <- blob,
                    Expression<Double>("last_embedded") <- nowTS
                )
                try connection.run(update)
                success += 1
                // Success indicator (green dot)
                FileHandle.standardOutput.write(Data("\u{001B}[32m.\u{001B}[0m".utf8))
            } catch {
                failures += 1
                // Failure indicator (red dot)
                FileHandle.standardOutput.write(Data("\u{001B}[31m.\u{001B}[0m".utf8))
                print(" Warning: failed to embed '\(filePath)': \(error.localizedDescription)")
            }
        }
        // Newline after progress dots
        print("")
        print("Embedded \(success) notes.")
        if failures > 0 {
            print("Skipped \(failures) notes due to errors.")
        }
    }
}