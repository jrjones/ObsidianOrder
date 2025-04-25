import Foundation
import Yams

/// Configuration for chat/summarization models
struct SummarizeModel: Codable {
    let primary: String
    let fallback: String?
}

/// Loads and holds CLI configuration from ~/.config/obsidian-order/config.yaml
struct Config: Codable {
    /// Path to Obsidian vault (overridden by --vault flag)
    let vault: String?
    /// Path to SQLite DB (overridden by --db flag)
    let db: String?
    /// Embedding model identifier (e.g. "ollama/nomic-embed")
    let embedding_model: String?
    /// Ollama API hosts per machine (e.g. ["mac": "http://127.0.0.1:11434"])
    let ollama_hosts: [String: String]?
    /// Models to use for summarization / chat completions
    let summarize_model: SummarizeModel?

    /// Load configuration from XDG_CONFIG_HOME or ~/.config
    static func load() throws -> Config {
        let fm = FileManager.default
        let configHome: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] {
            configHome = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            configHome = fm.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        }
        let configURL = configHome.appendingPathComponent("obsidian-order/config.yaml")
        guard fm.fileExists(atPath: configURL.path) else {
            // Return defaults if no config file
            return Config(
                vault: nil,
                db: nil,
                embedding_model: nil,
                ollama_hosts: nil,
                summarize_model: nil
            )
        }
        let text = try String(contentsOf: configURL)
        return try YAMLDecoder().decode(Config.self, from: text)
    }

    /// Determine the Ollama host URL (defaults to localhost if not configured)
    var ollamaHostURL: URL {
        if let hosts = ollama_hosts,
           let mac = hosts["mac"],
           let url = URL(string: mac) {
            return url
        }
        return URL(string: "http://127.0.0.1:11434")!
    }
}