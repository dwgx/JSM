import Foundation
import Darwin

enum Quarantine {
    static let attribute = "com.apple.quarantine"

    static func hasQuarantine(at url: URL) -> Bool {
        let path = url.path
        let size = getxattr(path, attribute, nil, 0, 0, 0)
        if size >= 0 { return true }
        return errno != ENOATTR && errno != ENODATA
    }

    @discardableResult
    static func removeQuarantine(at url: URL) -> Bool {
        let path = url.path
        if removexattr(path, attribute, 0) == 0 {
            return true
        }
        return errno == ENOATTR || errno == ENODATA
    }

    static func clearQuarantine(in root: URL,
                                fileExtensions: Set<String>,
                                skipDirectories: Set<String> = ["world", "world_nether", "world_the_end"],
                                includeDirectories: Bool = true,
                                maxItems: Int = 12_000) -> (scanned: Int, removed: Int, failed: Int, lastError: Int32?) {
        let fm = FileManager.default
        var scanned = 0
        var removed = 0
        var failed = 0
        var lastError: Int32? = nil

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return (scanned, removed, failed, lastError)
        }

        for case let fileURL as URL in enumerator {
            if scanned >= maxItems { break }
            if let values = try? fileURL.resourceValues(forKeys: Set(keys)),
               values.isDirectory == true {
                if skipDirectories.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                if includeDirectories && hasQuarantine(at: fileURL) {
                    let path = fileURL.path
                    if removexattr(path, attribute, 0) == 0 {
                        removed += 1
                    } else if errno != ENOATTR && errno != ENODATA {
                        failed += 1
                        lastError = errno
                    }
                }
                continue
            }

            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            guard fileExtensions.contains(ext) else { continue }
            scanned += 1

            if hasQuarantine(at: fileURL) {
                let path = fileURL.path
                if removexattr(path, attribute, 0) == 0 {
                    removed += 1
                } else if errno != ENOATTR && errno != ENODATA {
                    failed += 1
                    lastError = errno
                }
            }
        }

        return (scanned, removed, failed, lastError)
    }
}
