import Foundation
#if canImport(Yams)
import Yams
#endif
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

public enum BundleImportError: Error {
    case missingDependency(String)
    case invalidBundle
    case decode(Error)
}

public final class BundleImporter {
    public init() {}

    public func validateBundle(at url: URL) throws -> Bool {
#if canImport(ZIPFoundation)
        guard let archive = Archive(url: url, accessMode: .read) else { return false }
        return archive["manifest.yaml"] != nil && archive["server.yaml"] != nil
#else
        _ = url
        throw BundleImportError.missingDependency("ZIPFoundation")
#endif
    }

    public func extractServerConfig(from url: URL) throws -> ServerConfig {
#if canImport(ZIPFoundation) && canImport(Yams)
        guard let archive = Archive(url: url, accessMode: .read),
              let entry = archive["server.yaml"] else { throw BundleImportError.invalidBundle }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let serverURL = tempDir.appendingPathComponent("server.yaml")
        try archive.extract(entry, to: serverURL)
        let yaml = try String(contentsOf: serverURL, encoding: .utf8)
        let decoder = YAMLDecoder()
        do {
            if let config = try? decoder.decode(ServerConfig.self, from: yaml) {
                return config
            }
            let legacy = try decoder.decode(ServerDefinition.self, from: yaml)
            return ServerConfig(definition: legacy)
        } catch {
            throw BundleImportError.decode(error)
        }
#else
        _ = url
        throw BundleImportError.missingDependency("Yams/ZIPFoundation")
#endif
    }
}
