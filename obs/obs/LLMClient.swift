import Foundation

/// Simple synchronous HTTP client for Ollama embeddings
struct OllamaClient {
    let host: URL
    let model: String

    
    init(host: URL, model: String) {
        self.host = host
        self.model = model
    }

    /// Returns an embedding vector for the given text via the Ollama /api/embed endpoint.
    func embed(text: String) throws -> [Double] {
        // Determine full embed endpoint URL
        let url: URL
        if host.path.lowercased().hasSuffix("/api/embed") {
            url = host
        } else {
            url = host.appendingPathComponent("api/embed")
        }

        // Prepare HTTP request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Use local model name (strip any registry prefix)
        let modelName: String
        if let idx = model.lastIndex(of: "/") {
            modelName = String(model[model.index(after: idx)...])
        } else {
            modelName = model
        }
        let payload: [String: Any] = ["model": modelName, "input": [text]]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        // Execute request synchronously
        let (data, response, error) = URLSession.shared.synchronousDataTask(with: request)
        if let err = error {
            throw NSError(domain: "OllamaClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Network error: \(err.localizedDescription)"])
        }
        guard let http = response as? HTTPURLResponse, let data = data else {
            throw NSError(domain: "OllamaClient", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-text>"
            throw NSError(domain: "OllamaClient", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }

        // Decode JSON embeddings
        let decoder = JSONDecoder()
        let resp = try decoder.decode(EmbeddingsResponse.self, from: data)
        guard let vector = resp.embeddings.first else {
            throw NSError(domain: "OllamaClient", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Empty embeddings array"])
        }
        return vector
    }
    
    /// Sends a text generation request to Ollama (/api/generate) and returns the generated text
    func chatCompletion(system: String? = nil, user: String, model: String) throws -> String {
        // Determine endpoint URL (/api/generate)
        let endpoint = "api/generate"
        let url: URL
        if host.path.lowercased().hasSuffix(endpoint) {
            url = host
        } else {
            url = host.appendingPathComponent(endpoint)
        }
        // Build request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Assemble prompt: optional system message, then user prompt
        var prompt = ""
        if let sys = system {
            prompt += sys + "\n\n"
        }
        prompt += user
        // Payload
        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        // Send synchronously
        let (data, response, error) = URLSession.shared.synchronousDataTask(with: request)
        if let err = error {
            throw NSError(domain: "OllamaClient", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Chat network error: \(err.localizedDescription)"])
        }
        guard let http = response as? HTTPURLResponse, let data = data else {
            throw NSError(domain: "OllamaClient", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid chat HTTP response"])
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<non-text>"
            throw NSError(domain: "OllamaClient", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Chat HTTP \(http.statusCode): \(body)"])
        }
        // Decode JSON response dynamically
        let rawJSON = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = rawJSON as? [String: Any] else {
            // Return raw text if unable to parse
            return String(data: data, encoding: .utf8) ?? ""
        }
        // Common response fields
        if let resp = dict["response"] as? String {
            return resp
        }
        if let completion = dict["completion"] as? String {
            return completion
        }
        if let text = dict["text"] as? String {
            return text
        }
        // Legacy fields
        if let generations = dict["generations"] as? [[String: Any]],
           let first = generations.first,
           let t = first["text"] as? String {
            return t
        }
        if let results = dict["results"] as? [[String: Any]],
           let first = results.first,
           let t = first["text"] as? String {
            return t
        }
        if let choices = dict["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        // Fallback to raw JSON string
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Response from Ollama embeddings endpoint
private struct EmbeddingsResponse: Codable {
    let embeddings: [[Double]]
}
// NOTE: dynamic JSON parsing used in chatCompletion — GenerateResponse no longer needed.

// MARK: - URLSession synchronous helper
private extension URLSession {
    func synchronousDataTask(with request: URLRequest) -> (Data?, URLResponse?, Error?) {
        var data: Data?
        var response: URLResponse?
        var error: Error?
        let semaphore = DispatchSemaphore(value: 0)
        dataTask(with: request) { d, r, e in
            data = d
            response = r
            error = e
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return (data, response, error)
    }
}

// MARK: - Summit summarization with chain-of-thought stripping and retry
extension OllamaClient {
    /// Summarize given user text with optional system prompt, stripping out <think> tags and retrying up to two fallback attempts.
    /// - Parameters:
    ///   - system: Optional system prompt prefix.
    ///   - user: The user content to summarize.
    ///   - primaryModel: Name of the primary model to use.
    ///   - fallbackModel: Name of a fallback model (if primary fails).
    /// - Returns: A one-line cleaned summary.
    func summarizeWithRetry(system: String? = nil,
                            user: String,
                            primaryModel: String,
                            fallbackModel: String? = nil) throws -> String {
        // Try primary model once, fallback to secondary on error
        let raw: String
        do {
            raw = try chatCompletion(system: system, user: user, model: primaryModel)
        } catch let primaryError {
            if let fallback = fallbackModel {
                raw = try chatCompletion(system: system, user: user, model: fallback)
            } else {
                throw primaryError
            }
        }
        // Clean chain-of-thought and whitespace
        var cleaned = raw
            .replacingOccurrences(of: "<think>[\\s\\S]*?</think>",
                                 with: "",
                                 options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Sanity transforms
        cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "*", with: "")
        cleaned = cleaned.replacingOccurrences(of: "Summary - ", with: "")
        // Remove ISO dates (YYYY-MM-DD)
        cleaned = cleaned.replacingOccurrences(
            of: "\\b\\d{4}-\\d{2}-\\d{2}\\b",
            with: "",
            options: .regularExpression
        )
        // Remove textual dates (Month D, YYYY)
        cleaned = cleaned.replacingOccurrences(
            of: "[A-Za-z]+\\s+\\d{1,2},\\s+\\d{4}",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return "✨" + cleaned
    }
}