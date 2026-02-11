import Foundation
#if canImport(Yams)
import Yams
#endif
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

public struct BundleManifest: Codable {
    public var version: String
    public var serverID: UUID
    public var includeWorkspace: Bool
    public var includeTheme: Bool
    public var createdAt: Date

    public init(version: String = "0.1.0",
                serverID: UUID,
                includeWorkspace: Bool,
                includeTheme: Bool,
                createdAt: Date = Date()) {
        self.version = version
        self.serverID = serverID
        self.includeWorkspace = includeWorkspace
        self.includeTheme = includeTheme
        self.createdAt = createdAt
    }
}

public enum BundleExportError: Error {
    case missingDependency(String)
    case invalidDestination
}

public final class BundleExporter {
    public init() {}

    public func exportServerBundle(definition: ServerDefinition,
                                   includeWorkspace: Bool,
                                   includeTheme: Bool,
                                   to destination: URL) throws {
#if canImport(Yams) && canImport(ZIPFoundation)
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifest = BundleManifest(serverID: definition.id,
                                      includeWorkspace: includeWorkspace,
                                      includeTheme: includeTheme)
        let encoder = YAMLEncoder()
        let manifestYAML = try encoder.encode(manifest)
        let serverYAML = try encoder.encode(ServerConfig(definition: definition))

        try manifestYAML.data(using: .utf8)?.write(to: tempDir.appendingPathComponent("manifest.yaml"))
        try serverYAML.data(using: .utf8)?.write(to: tempDir.appendingPathComponent("server.yaml"))

        if includeWorkspace {
            let bookmark = Bookmark(data: definition.workspaceBookmark)
            do {
                try SandboxAccess.withBookmark(bookmark) { workspaceURL in
                    let workspaceDest = tempDir.appendingPathComponent("workspace", isDirectory: true)
                    try fileManager.createDirectory(at: workspaceDest, withIntermediateDirectories: true)
                    try copyDirectory(from: workspaceURL, to: workspaceDest)
                }
            } catch {
                throw BundleExportError.invalidDestination
            }
        }

        if includeTheme {
            // Placeholder: theme export can be wired to the active theme engine later.
            _ = includeTheme
        }

        guard let archive = Archive(url: destination, accessMode: .create) else {
            throw BundleExportError.invalidDestination
        }
        try addDirectory(at: tempDir, to: archive, root: tempDir)
        try? fileManager.removeItem(at: tempDir)
#else
        _ = definition
        _ = includeWorkspace
        _ = includeTheme
        _ = destination
        throw BundleExportError.missingDependency("Yams/ZIPFoundation")
#endif
    }

#if canImport(ZIPFoundation)
    private func addDirectory(at url: URL, to archive: Archive, root: URL) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true { continue }
            let relativePath = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            try archive.addEntry(with: relativePath, relativeTo: root, compressionMethod: .deflate)
        }
    }
#endif

    private func copyDirectory(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }
}
