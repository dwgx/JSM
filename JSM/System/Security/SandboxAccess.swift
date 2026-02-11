import Foundation

public enum SandboxAccessError: LocalizedError, Equatable {
    case accessDenied
    case invalidBookmark
    case pathOutsideScope(String)
    case fileMissing(String)
    case notReadable(String)
    case notExecutable(String)
    case invalidSelection(String)

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "权限不足：未获得访问授权。"
        case .invalidBookmark:
            return "权限书签无效或已失效。"
        case .pathOutsideScope(let path):
            return "路径不在授权范围内：\(path)"
        case .fileMissing(let path):
            return "文件不存在：\(path)"
        case .notReadable(let path):
            return "文件不可读：\(path)"
        case .notExecutable(let path):
            return "文件不可执行：\(path)"
        case .invalidSelection(let message):
            return message
        }
    }
}

public enum SandboxAccess {
    public static func withBookmark<T>(_ data: Data, _ action: (URL) throws -> T) throws -> T {
        let bookmark = Bookmark(data: data)
        return try withBookmark(bookmark, action)
    }

    public static func withBookmark<T>(_ bookmark: Bookmark, _ action: (URL) throws -> T) throws -> T {
        let resource: SecurityScopedResource
        do {
            resource = try SecurityScopedResource(bookmark: bookmark)
        } catch {
            throw SandboxAccessError.invalidBookmark
        }
        guard resource.startAccessing() else { throw SandboxAccessError.accessDenied }
        defer { resource.stopAccessing() }
        return try action(resource.url)
    }

    public static func resolveRelativePath(base: URL, relative: String) throws -> URL {
        guard !relative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SandboxAccessError.invalidSelection("路径为空。")
        }
        guard !relative.hasPrefix("/") else {
            throw SandboxAccessError.pathOutsideScope(relative)
        }

        let baseURL = base.standardizedFileURL
        let resolved = relative.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appendingPathComponent(String(component))
        }.standardizedFileURL

        let basePrefix = baseURL.path.hasSuffix("/") ? baseURL.path : "\(baseURL.path)/"
        guard resolved.path.hasPrefix(basePrefix) else {
            throw SandboxAccessError.pathOutsideScope(resolved.path)
        }
        return resolved
    }

    public static func validateExecutable(_ url: URL) throws {
        let path = url.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw SandboxAccessError.fileMissing(path) }
        guard fm.isReadableFile(atPath: path) else { throw SandboxAccessError.notReadable(path) }
        guard fm.isExecutableFile(atPath: path) else { throw SandboxAccessError.notExecutable(path) }
    }

    public static func validateFileReadable(_ url: URL) throws {
        let path = url.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { throw SandboxAccessError.fileMissing(path) }
        guard fm.isReadableFile(atPath: path) else { throw SandboxAccessError.notReadable(path) }
    }
}
