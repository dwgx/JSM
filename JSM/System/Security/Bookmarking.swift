import Foundation
import AppKit

/// Wraps security-scoped bookmark handling to ensure all file access obeys sandbox rules.
public struct Bookmark: Codable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public static func create(for url: URL) throws -> Bookmark {
        // When `url` comes from a sandboxed file picker (Powerbox), it is security-scoped.
        // We must start accessing before reading metadata / generating bookmark data, otherwise
        // bookmark creation can fail with "Could not open() the item" (NSCocoaErrorDomain Code=256).
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started { url.stopAccessingSecurityScopedResource() }
        }
        let data = try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        return Bookmark(data: data)
    }

    public func resolve() throws -> URL {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data,
                          options: [.withSecurityScope],
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        guard isStale else { return url }

        // Refreshing a stale bookmark can fail if we don't activate the security scope first, which can surface as
        // "Could not open() the item" in sandboxed builds. Refresh best-effort and fall back to the original URL.
        do {
            let started = url.startAccessingSecurityScopedResource()
            defer {
                if started { url.stopAccessingSecurityScopedResource() }
            }
            let refreshed = try url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
            var refreshedStale = false
            return try URL(resolvingBookmarkData: refreshed,
                           options: [.withSecurityScope],
                           relativeTo: nil,
                           bookmarkDataIsStale: &refreshedStale)
        } catch {
            return url
        }
    }
}

/// RAII wrapper to keep security scope open during an operation.
public final class SecurityScopedResource {
    private var isAccessing = false
    public let url: URL

    public init(bookmark: Bookmark) throws {
        self.url = try bookmark.resolve()
    }

    @discardableResult
    public func startAccessing() -> Bool {
        guard !isAccessing else { return true }
        isAccessing = url.startAccessingSecurityScopedResource()
        return isAccessing
    }

    public func stopAccessing() {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
            isAccessing = false
        }
    }

    deinit {
        stopAccessing()
    }
}
