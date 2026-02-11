import Foundation
#if canImport(Yams)
import Yams
#endif

public enum ConfigError: Error {
    case invalidFile
    case encoding
    case decode(Error)
    case encode(Error)
    case missingDependency(String)
}

public protocol ConfigLoading {
    func loadServerConfig(from url: URL) throws -> ServerConfig
    func saveServerConfig(_ config: ServerConfig, to url: URL) throws
}

/// YAML-only config loader. All file access must be security-scoped by caller.
public final class ConfigLoader: ConfigLoading {
    public init() {}

    public func loadServerConfig(from url: URL) throws -> ServerConfig {
#if canImport(Yams)
        guard let data = try? Data(contentsOf: url) else { throw ConfigError.invalidFile }
        guard let yamlString = String(data: data, encoding: .utf8) else { throw ConfigError.encoding }
        do {
            let decoder = YAMLDecoder()
            if let config = try? decoder.decode(ServerConfig.self, from: yamlString) {
                return config
            }
            let legacy = try decoder.decode(ServerDefinition.self, from: yamlString)
            return ServerConfig(definition: legacy)
        } catch {
            throw ConfigError.decode(error)
        }
#else
        throw ConfigError.missingDependency("Yams")
#endif
    }

    public func saveServerConfig(_ config: ServerConfig, to url: URL) throws {
#if canImport(Yams)
        do {
            let encoder = YAMLEncoder()
            let yaml = try encoder.encode(config)
            try yaml.data(using: .utf8)?.write(to: url)
        } catch {
            throw ConfigError.encode(error)
        }
#else
        _ = config
        throw ConfigError.missingDependency("Yams")
#endif
    }
}
