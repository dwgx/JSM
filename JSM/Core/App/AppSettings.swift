import Foundation
#if canImport(Yams)
import Yams
#endif

public enum ProcessStopStrategy: String, Codable, CaseIterable {
    case stopSignalThenManualForce
    case stopSignalThenAutoForce
    case immediateForceKill

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "stopSignalThenManualForce", "gracefulManualForce":
            self = .stopSignalThenManualForce
        case "stopSignalThenAutoForce", "gracefulThenForce":
            self = .stopSignalThenAutoForce
        case "immediateForceKill", "forceImmediate":
            self = .immediateForceKill
        default:
            self = .stopSignalThenManualForce
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AppSettings: Codable {
    public var javaExecutable: String?
    public var javaExecutableBookmark: Data?
    public var metricsInterval: TimeInterval
    public var consoleRenderer: ConsoleRenderer
    public var lastStartedServerIDs: [UUID]
    public var themeAppearance: ThemeAppearance
    public var processStopStrategy: ProcessStopStrategy

    public init(javaExecutable: String? = nil,
                javaExecutableBookmark: Data? = nil,
                metricsInterval: TimeInterval = 2.0,
                consoleRenderer: ConsoleRenderer = .native,
                lastStartedServerIDs: [UUID] = [],
                themeAppearance: ThemeAppearance = .system,
                processStopStrategy: ProcessStopStrategy = .stopSignalThenManualForce) {
        self.javaExecutable = javaExecutable
        self.javaExecutableBookmark = javaExecutableBookmark
        self.metricsInterval = metricsInterval
        self.consoleRenderer = consoleRenderer
        self.lastStartedServerIDs = lastStartedServerIDs
        self.themeAppearance = themeAppearance
        self.processStopStrategy = processStopStrategy
    }

    enum CodingKeys: String, CodingKey {
        case javaExecutable
        case javaExecutableBookmark
        case metricsInterval
        case consoleRenderer
        case lastStartedServerIDs
        case themeAppearance
        case processStopStrategy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        javaExecutable = try container.decodeIfPresent(String.self, forKey: .javaExecutable)
        javaExecutableBookmark = try container.decodeIfPresent(Data.self, forKey: .javaExecutableBookmark)
        metricsInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .metricsInterval) ?? 2.0
        consoleRenderer = try container.decodeIfPresent(ConsoleRenderer.self, forKey: .consoleRenderer) ?? .native
        lastStartedServerIDs = try container.decodeIfPresent([UUID].self, forKey: .lastStartedServerIDs) ?? []
        themeAppearance = try container.decodeIfPresent(ThemeAppearance.self, forKey: .themeAppearance) ?? .system
        processStopStrategy = try container.decodeIfPresent(ProcessStopStrategy.self, forKey: .processStopStrategy) ?? .stopSignalThenManualForce
    }
}

public struct SettingsStore {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = base.appendingPathComponent("JSM", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            self.fileURL = dir.appendingPathComponent("settings.yaml")
        }
    }

    public func load() throws -> AppSettings {
#if canImport(Yams)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppSettings() }
        let yaml = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode(AppSettings.self, from: yaml)
#else
        return AppSettings()
#endif
    }

    public func save(_ settings: AppSettings) throws {
#if canImport(Yams)
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(settings)
        try yaml.data(using: .utf8)?.write(to: fileURL)
#else
        _ = settings
#endif
    }
}
