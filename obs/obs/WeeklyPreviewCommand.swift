import ArgumentParser
import Foundation

/// `obs weekly-preview` command: render ISO-week dashboard
struct WeeklyPreview: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "weekly-preview", abstract: "Render ISO-week dashboard (no file write)")
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
    func run() throws {
        // Stubbed weekly preview; to be implemented
        let today = Date()
        let calendar = Calendar(identifier: .iso8601)
        let weekOfYear = calendar.component(.weekOfYear, from: today)
        let yearForWeek = calendar.component(.yearForWeekOfYear, from: today)
        let weekString = String(format: "%04d-W%02d", yearForWeek, weekOfYear)
        let items: [[String: Any]] = []
        if json {
            let output: [String: Any] = ["week": weekString, "items": items]
            let data = try JSONSerialization.data(withJSONObject: output, options: .prettyPrinted)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("# Weekly Preview for \(weekString)\n")
            if items.isEmpty {
                print("_No preview available._")
            } else {
                // TODO: render items
            }
        }
    }
}