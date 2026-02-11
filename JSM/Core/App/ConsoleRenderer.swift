import Foundation

public enum ConsoleRenderer: String, CaseIterable, Identifiable, Codable {
    case native
    case web

    public var id: String { rawValue }
}
