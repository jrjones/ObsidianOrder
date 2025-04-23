import Foundation

/// Represents a calendar event fetched from Graph API.
public struct GraphEvent {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let isVirtual: Bool
}

/// Errors thrown by GraphClient.
public enum GraphClientError: Error {
    /// Indicates the client is not yet implemented.
    case notImplemented
}

/// Stub GraphClient for calendar integration.
public class GraphClient {
    public init() {}

    /// Fetches calendar events between the given dates.
    /// - Returns: An array of GraphEvent.
    public func fetchEvents(start: Date, end: Date) throws -> [GraphEvent] {
        // TODO: implement Graph API integration using MSAL.swift
        throw GraphClientError.notImplemented
    }
}