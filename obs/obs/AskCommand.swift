import ArgumentParser
import Foundation
import SQLite

/// `obs ask` command: search notes matching a query (stub implementation)
struct Ask: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Search notes by query (substring match stub; semantic search TBD)"
    )

    @Argument(help: "Query text to search for")
    var query: String

    @Option(name: .long, help: "Path to SQLite DB (default: ~/.obsidian-order/state.sqlite)")
    var db: String?

    @Option(name: .long, help: "Maximum number of results (default: 5)")
    var top: Int = 5

    @Option(name: .long, help: "Rerank model (not used in stub)")
    var rerank: String?
    
    @Flag(name: .long, help: "Use substring match instead of semantic embeddings")
    var substring: Bool = false

    func run() throws {
        // Load CLI config (optional overrides)
        let config = try Config.load()
        // Determine database path: flag > config > default
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dbPath = db ?? config.db ?? "\(home)/.obsidian-order/state.sqlite"
        let connection = try Connection(dbPath)

        // If user requests substring-only, or no embeddings exist, perform substring search
        if substring {
            performSubstringSearch(on: connection)
            return
        }
        // Attempt semantic search
        let results = try performSemanticSearch(on: connection, config: config)
        if results.isEmpty {
            // No embeddings found: fallback
            performSubstringSearch(on: connection)
            return
        }
        // Build RAG prompt: include each document's content
        // Determine chat model
        let chatModel = config.summarize_model?.primary ?? "llama3:70b"
        let hostURL = config.ollamaHostURL
        let client = OllamaClient(host: hostURL, model: chatModel)
        // System prompt
        let systemPrompt = "You are a helpful assistant. Use the provided notes to answer the question."
        // Assemble user prompt with contexts
        var userPrompt = ""
        for (title, path, score) in results {
            // Include note heading with score
            let scoreStr = String(format: "%.3f", score)
            userPrompt += "### Note: \(title) (score: \(scoreStr))\n"
            if let text = try? String(contentsOfFile: path) {
                userPrompt += text + "\n"
            }
            userPrompt += "\n"
        }
        userPrompt += "Question: \(query)\nAnswer:"
        // Call chat completion
        let answer = try client.chatCompletion(system: systemPrompt, user: userPrompt, model: chatModel)
        print(answer)
    }

    /// Execute simple substring search on title or path
    private func performSubstringSearch(on connection: Connection) {
        let notes = Table("notes")
        let titleExp = Expression<String>("title")
        let pathExp = Expression<String>("path")
        let pattern = "%\(query)%"
        let filterExp = titleExp.like(pattern) || pathExp.like(pattern)
        let stmt = notes.filter(filterExp).limit(top)
        let displayWidth = 40
        var found = 0
        for row in try! connection.prepare(stmt) {
            let title = row[titleExp]
            let path = row[pathExp]
            if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                let uri = "obsidian://open?path=\(encoded)"
                let displayTitle: String
                if title.count <= displayWidth {
                    displayTitle = title + String(repeating: " ", count: displayWidth - title.count)
                } else {
                    displayTitle = String(title.prefix(displayWidth - 1)) + "…"
                }
                print("- \(displayTitle)  \(uri)")
            } else {
                print("- \(title)  (Invalid path URI)")
            }
            found += 1
        }
        if found == 0 {
            print("No matching notes found for query: '\(query)'")
        }
    }

    /// Execute semantic search using local embeddings
    private func performSemanticSearch(on connection: Connection, config: Config) throws -> [(String, String, Double)] {
        // Prepare client for query embedding
        let hostURL = config.ollamaHostURL
        let model = config.embedding_model ?? "ollama/nomic-embed-text"
        let client = OllamaClient(host: hostURL, model: model)
        // Embed the query
        let queryVector = try client.embed(text: query)
        // Precompute query norm
        let qnorm = sqrt(queryVector.map { $0 * $0 }.reduce(0, +))

        // Read all note embeddings
        let notes = Table("notes")
        let titleExp = Expression<String>("title")
        let pathExp = Expression<String>("path")
        let embExp = Expression<Blob>("embedding")
        var scored: [(String, String, Double)] = []
        for row in try connection.prepare(notes.select(titleExp, pathExp, embExp)) {
            let title = row[titleExp]
            let path = row[pathExp]
            let blob = row[embExp]
            let byteArray = blob.bytes
            guard !byteArray.isEmpty else { continue }
            let data = Data(byteArray)
            let dim = MemoryLayout<Double>.size
            let count = data.count / dim
            guard data.count == count * dim else { continue }
            // Decode blob to [Double]
            var vector = [Double](repeating: 0, count: count)
            _ = vector.withUnsafeMutableBytes { ptr in
                data.copyBytes(to: ptr)
            }
            // Compute cosine similarity
            let dot = zip(queryVector, vector).map(*).reduce(0, +)
            let vnorm = sqrt(vector.map { $0 * $0 }.reduce(0, +))
            guard vnorm > 0, qnorm > 0 else { continue }
            let score = dot / (qnorm * vnorm)
            scored.append((title, path, score))
        }
        // Sort by score descending, take top-k
        let sorted = scored.sorted { $0.2 > $1.2 }.prefix(top)
        return Array(sorted)
    }
}