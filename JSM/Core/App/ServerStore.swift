import Foundation
#if canImport(Yams)
import Yams
#endif

public struct ServerStore {
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
            self.fileURL = dir.appendingPathComponent("servers.yaml")
        }
    }

    public func load() throws -> [ServerDefinition] {
#if canImport(Yams)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let yaml = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = YAMLDecoder()
        return try decoder.decode([ServerDefinition].self, from: yaml)
#else
        return []
#endif
    }

    public func save(_ servers: [ServerDefinition]) throws {
#if canImport(Yams)
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(servers)
        try yaml.data(using: .utf8)?.write(to: fileURL)
#else
        _ = servers
#endif
    }
}
