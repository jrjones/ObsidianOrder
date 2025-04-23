import ArgumentParser
import Foundation
import GraphClient

/// `obs agenda` command: print calendar events
struct Agenda: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print today's calendar pulled from Graph (read-only)")
    @Flag(name: .long, help: "Output raw JSON instead of markdown")
    var json: Bool = false
    func run() throws {
        // Fetch today's events via GraphClient stub
        let today = Date()
        let calendar = Calendar(identifier: .iso8601)
        let startOfDay = calendar.startOfDay(for: today)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? today
        let client = GraphClient()
        let graphEvents: [GraphEvent]
        do {
            graphEvents = try client.fetchEvents(start: startOfDay, end: endOfDay)
        } catch {
            graphEvents = []
        }
        let isoFormatter = ISO8601DateFormatter()
        let events: [[String: Any]] = graphEvents.map { event in
            [
                "id": event.id,
                "title": event.title,
                "start": isoFormatter.string(from: event.start),
                "end": isoFormatter.string(from: event.end),
                "location": event.location ?? "",
                "is_virtual": event.isVirtual
            ]
        }
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: today)
        if json {
            let output: [String: Any] = ["date": dateString, "events": events]
            let data = try JSONSerialization.data(withJSONObject: output, options: .prettyPrinted)
            if let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("# Agenda for \(dateString)\n")
            print("## Events\n")
            if events.isEmpty {
                print("_No events available._")
            } else {
                for event in events {
                    if let start = event["start"] as? String,
                       let title = event["title"] as? String {
                        print("- **\(start)**: \(title)")
                    }
                }
            }
        }
    }
}