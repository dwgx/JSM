import Foundation
import Combine
#if canImport(Yams)
import Yams
#endif

public struct ThemeInfo: Identifiable {
    public let id: String
    public let name: String
    public let url: URL
    public let manifest: ThemeManifest?
}

public struct ThemeVersion: Identifiable {
    public let id: String
    public let label: String
    public let createdAt: Date
    public let url: URL
}

public enum ThemeLibraryError: Error {
    case invalidThemeFolder
    case accessDenied
    case missingDefaultTheme
}

/// Manages the built-in theme library stored in Application Support.
public final class ThemeLibrary: ObservableObject {
    @Published public private(set) var themes: [ThemeInfo] = []

    private let fileManager: FileManager
    private let bundle: Bundle
    public let themesDirectory: URL

    public init(fileManager: FileManager = .default, bundle: Bundle = .main) {
        self.fileManager = fileManager
        self.bundle = bundle
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.themesDirectory = base.appendingPathComponent("JSM/Themes", isDirectory: true)
        ensureThemesDirectory()
        cleanupLegacyOfficialThemes()
        ensureBundledThemesInstalled()
        migrateBundledThemesIfNeeded()
        refresh()
    }

    public func refresh() {
        var items: [ThemeInfo] = []
        let urls = (try? fileManager.contentsOfDirectory(at: themesDirectory,
                                                        includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let manifestURL = url.appendingPathComponent("theme.yaml")
            let manifest = readManifest(from: manifestURL)
            let name = manifest?.name ?? url.lastPathComponent
            items.append(ThemeInfo(id: url.lastPathComponent, name: name, url: url, manifest: manifest))
        }
        items.sort {
            if $0.name == "JSM Default" { return true }
            if $1.name == "JSM Default" { return false }
            if $0.name == "Codex Mono" { return true }
            if $1.name == "Codex Mono" { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        themes = items
    }

    public func createThemeCopy(from theme: ThemeInfo?) throws -> ThemeInfo {
        let source = theme?.url ?? defaultThemeURL()
        guard fileManager.fileExists(atPath: source.path) else { throw ThemeLibraryError.missingDefaultTheme }
        let baseName = theme?.name ?? "JSM Default"
        let target = uniqueFolderURL(baseName: "\(baseName) Copy")
        try fileManager.copyItem(at: source, to: target)
        seedVersionIfNeeded(at: target, label: "复制")
        refresh()
        return ThemeInfo(id: target.lastPathComponent,
                         name: baseName + " Copy",
                         url: target,
                         manifest: readManifest(from: target.appendingPathComponent("theme.yaml")))
    }

    public func importTheme(from url: URL) throws {
        let bookmark = try Bookmark.create(for: url)
        try SandboxAccess.withBookmark(bookmark) { sourceURL in
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
                throw ThemeLibraryError.invalidThemeFolder
            }
            let manifest = readManifest(from: sourceURL.appendingPathComponent("theme.yaml"))
            let baseName = manifest?.name ?? sourceURL.lastPathComponent
            let target = uniqueFolderURL(baseName: baseName)
            try fileManager.copyItem(at: sourceURL, to: target)
            seedVersionIfNeeded(at: target, label: "导入")
        }
        refresh()
    }

    public func exportTheme(_ theme: ThemeInfo, to destination: URL) throws {
        let bookmark = try Bookmark.create(for: destination)
        try SandboxAccess.withBookmark(bookmark) { targetRoot in
            let target = uniqueFolderURL(baseName: theme.name, in: targetRoot)
            try fileManager.copyItem(at: theme.url, to: target)
        }
    }

    public func readFile(_ filename: String, in theme: ThemeInfo) throws -> String {
        let url = theme.url.appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    public func writeFile(_ filename: String, content: String, in theme: ThemeInfo, recordVersion: Bool = true) throws {
        let url = theme.url.appendingPathComponent(filename)
        try content.data(using: .utf8)?.write(to: url)
        if recordVersion {
            try self.recordVersion(theme, label: "保存")
        }
    }

    public func listVersions(for theme: ThemeInfo) -> [ThemeVersion] {
        let dir = versionsDirectory(for: theme)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        let urls = (try? fileManager.contentsOfDirectory(at: dir,
                                                         includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles])) ?? []
        var results: [ThemeVersion] = []
        for url in urls {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let meta = readVersionMeta(at: url)
            let createdAt: Date
            if let ts = meta?.createdAt {
                createdAt = Date(timeIntervalSince1970: ts)
            } else if let parsed = parseVersionDate(from: url.lastPathComponent) {
                createdAt = parsed
            } else {
                createdAt = Date.distantPast
            }
            let label = meta?.label ?? "版本"
            results.append(ThemeVersion(id: url.lastPathComponent, label: label, createdAt: createdAt, url: url))
        }
        results.sort { $0.createdAt > $1.createdAt }
        return results
    }

    public func restoreVersion(_ version: ThemeVersion, in theme: ThemeInfo) throws {
        try recordVersion(theme, label: "重置前")
        for name in ["theme.yaml", "tokens.yaml", "layout.yaml", "components.yaml"] {
            let src = version.url.appendingPathComponent(name)
            let dst = theme.url.appendingPathComponent(name)
            if fileManager.fileExists(atPath: src.path) {
                if fileManager.fileExists(atPath: dst.path) {
                    try? fileManager.removeItem(at: dst)
                }
                try fileManager.copyItem(at: src, to: dst)
            }
        }
    }

    private func ensureThemesDirectory() {
        if !fileManager.fileExists(atPath: themesDirectory.path) {
            try? fileManager.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        }
    }

    private func versionsDirectory(for theme: ThemeInfo) -> URL {
        theme.url.appendingPathComponent(".versions", isDirectory: true)
    }

    private func ensureVersionsDirectory(at url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func seedVersionIfNeeded(at themeURL: URL, label: String) {
        let versionsDir = themeURL.appendingPathComponent(".versions", isDirectory: true)
        if let contents = try? fileManager.contentsOfDirectory(at: versionsDir,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles]),
           !contents.isEmpty {
            return
        }
        try? recordVersion(at: themeURL, label: label)
    }

    private struct ThemeVersionMeta: Codable {
        let label: String
        let createdAt: TimeInterval
    }

    private func versionMetaURL(in versionURL: URL) -> URL {
        versionURL.appendingPathComponent("meta.json")
    }

    private func readVersionMeta(at versionURL: URL) -> ThemeVersionMeta? {
        let url = versionMetaURL(in: versionURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThemeVersionMeta.self, from: data)
    }

    private func writeVersionMeta(_ meta: ThemeVersionMeta, at versionURL: URL) {
        let url = versionMetaURL(in: versionURL)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: url)
        }
    }

    private func versionFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "v-\(formatter.string(from: date))"
    }

    private func parseVersionDate(from folderName: String) -> Date? {
        guard folderName.hasPrefix("v-") else { return nil }
        let raw = String(folderName.dropFirst(2))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.date(from: raw)
    }

    private func recordVersion(_ theme: ThemeInfo, label: String?) throws {
        try recordVersion(at: theme.url, label: label)
    }

    private func recordVersion(at themeURL: URL, label: String?) throws {
        let versionsDir = themeURL.appendingPathComponent(".versions", isDirectory: true)
        ensureVersionsDirectory(at: versionsDir)
        let now = Date()
        var folderName = versionFolderName(for: now)
        var target = versionsDir.appendingPathComponent(folderName, isDirectory: true)
        var index = 1
        while fileManager.fileExists(atPath: target.path) {
            index += 1
            folderName = "\(versionFolderName(for: now))-\(index)"
            target = versionsDir.appendingPathComponent(folderName, isDirectory: true)
        }
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["theme.yaml", "tokens.yaml", "layout.yaml", "components.yaml"] {
            let src = themeURL.appendingPathComponent(name)
            let dst = target.appendingPathComponent(name)
            if fileManager.fileExists(atPath: src.path) {
                try fileManager.copyItem(at: src, to: dst)
            }
        }
        writeVersionMeta(ThemeVersionMeta(label: label ?? "版本", createdAt: now.timeIntervalSince1970), at: target)
    }

    private func cleanupLegacyOfficialThemes() {
        let legacyNames = [
            "AppleLiquid",
            "CitrusBloom",
            "GraphiteInk",
            "Default"
        ]
        let legacyDefault = themesDirectory.appendingPathComponent("JSM Default", isDirectory: true)
        let newDefault = themesDirectory.appendingPathComponent("JSMDefault", isDirectory: true)
        if fileManager.fileExists(atPath: legacyDefault.path), !fileManager.fileExists(atPath: newDefault.path) {
            try? fileManager.moveItem(at: legacyDefault, to: newDefault)
        }
        for name in legacyNames {
            let url = themesDirectory.appendingPathComponent(name, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private struct BundledTheme {
        let name: String
        let fallbackFiles: [String: String]
    }

    private func ensureBundledThemesInstalled() {
        for theme in bundledThemes() {
            ensureThemeInstalled(theme)
        }
    }

    private func migrateBundledThemesIfNeeded() {
        migrateOfficialThemeIfNeeded(name: "JSMDefault", targetVersion: "1.1.0")
    }

    private func migrateOfficialThemeIfNeeded(name: String, targetVersion: String) {
        let target = themesDirectory.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else { return }
        guard shouldUpgradeOfficialTheme(at: target, name: name, targetVersion: targetVersion) else { return }

        // Keep the current files before replacing with upgraded official defaults.
        try? recordVersion(at: target, label: "升级前")

        let bundled = bundledThemeFiles(named: name)
        let fallback = bundledThemes().first(where: { $0.name == name })?.fallbackFiles ?? [:]
        for file in ["theme.yaml", "tokens.yaml", "layout.yaml", "components.yaml"] {
            let dst = target.appendingPathComponent(file)
            if fileManager.fileExists(atPath: dst.path) {
                try? fileManager.removeItem(at: dst)
            }
            if let src = bundled[file] {
                try? fileManager.copyItem(at: src, to: dst)
            } else if let content = fallback[file] {
                try? content.data(using: .utf8)?.write(to: dst)
            }
        }

        try? recordVersion(at: target, label: "升级到 \(targetVersion)")
    }

    private func shouldUpgradeOfficialTheme(at url: URL, name: String, targetVersion: String) -> Bool {
        let manifestURL = url.appendingPathComponent("theme.yaml")
        let tokensURL = url.appendingPathComponent("tokens.yaml")

        if let manifest = readManifest(from: manifestURL) {
            if compareVersion(manifest.version, targetVersion) == .orderedAscending {
                return true
            }
            if name == "JSMDefault", (manifest.author ?? "").localizedCaseInsensitiveContains("codex") {
                return true
            }
        } else {
            return true
        }

        if name == "JSMDefault", let tokens = try? String(contentsOf: tokensURL, encoding: .utf8) {
            if !tokens.contains("colors_light:") || !tokens.contains("colors_dark:") {
                return true
            }
            if tokens.localizedCaseInsensitiveContains("#5EE0F0") {
                return true
            }
        }
        return false
    }

    private func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(l.count, r.count)
        for i in 0..<count {
            let lv = i < l.count ? l[i] : 0
            let rv = i < r.count ? r[i] : 0
            if lv < rv { return .orderedAscending }
            if lv > rv { return .orderedDescending }
        }
        return .orderedSame
    }

    private func ensureThemeInstalled(_ theme: BundledTheme) {
        let target = themesDirectory.appendingPathComponent(theme.name, isDirectory: true)
        guard !fileManager.fileExists(atPath: target.path) else { return }
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        let bundleFiles = bundledThemeFiles(named: theme.name)
        if bundleFiles.count == 4 {
            for (standardName, src) in bundleFiles {
                let dst = target.appendingPathComponent(standardName)
                if fileManager.fileExists(atPath: src.path) {
                    try? fileManager.copyItem(at: src, to: dst)
                }
            }
        } else {
            for (name, content) in theme.fallbackFiles {
                let dst = target.appendingPathComponent(name)
                try? content.data(using: .utf8)?.write(to: dst)
            }
        }
        seedVersionIfNeeded(at: target, label: "初始版本")
    }

    private func defaultThemeURL() -> URL {
        let primary = themesDirectory.appendingPathComponent("JSMDefault", isDirectory: true)
        if fileManager.fileExists(atPath: primary.path) { return primary }
        let legacy = themesDirectory.appendingPathComponent("JSM Default", isDirectory: true)
        if fileManager.fileExists(atPath: legacy.path) { return legacy }
        let codex = themesDirectory.appendingPathComponent("CodexMono", isDirectory: true)
        if fileManager.fileExists(atPath: codex.path) { return codex }
        return primary
    }

    private func bundledThemeFiles(named name: String) -> [String: URL] {
        let mapping: [String: String] = [
            "theme.yaml": "\(name).theme",
            "tokens.yaml": "\(name).tokens",
            "layout.yaml": "\(name).layout",
            "components.yaml": "\(name).components"
        ]
        var results: [String: URL] = [:]
        for (standard, resourceBase) in mapping {
            if let url = bundle.url(forResource: resourceBase, withExtension: "yaml") {
                results[standard] = url
            }
        }
        return results
    }

    private func bundledThemes() -> [BundledTheme] {
        [
            BundledTheme(name: "JSMDefault", fallbackFiles: fallbackThemeFiles_JSMDefault()),
            BundledTheme(name: "CodexMono", fallbackFiles: fallbackThemeFiles_CodexMono())
        ]
    }

    private func fallbackThemeFiles_JSMDefault() -> [String: String] {
        [
            "theme.yaml": "name: JSM Default\nversion: \"1.1.0\"\nauthor: JSM\nentry: web/console.html\n",
            "tokens.yaml": "colors:\n  surface: \"#F1F3F6\"\n  panel: \"#F7F8FA\"\n  primary: \"#2AAE68\"\n  text: \"#1A1F24\"\n  textMuted: \"#5A6570\"\n  border: \"#D7DCE3\"\n  shadow: \"#12000000\"\n  accent: \"#3A6EA5\"\n  success: \"#2AAE68\"\n  warning: \"#C98A2C\"\n  danger: \"#D25A5A\"\n  hover: \"#E8EBF0\"\ncolors_light:\n  surface: \"#F1F3F6\"\n  panel: \"#F7F8FA\"\n  primary: \"#2AAE68\"\n  text: \"#1A1F24\"\n  textMuted: \"#5A6570\"\n  border: \"#D7DCE3\"\n  shadow: \"#12000000\"\n  accent: \"#3A6EA5\"\n  success: \"#2AAE68\"\n  warning: \"#C98A2C\"\n  danger: \"#D25A5A\"\n  hover: \"#E8EBF0\"\ncolors_dark:\n  surface: \"#0E1115\"\n  panel: \"#14181E\"\n  primary: \"#3CCB74\"\n  text: \"#E2E7ED\"\n  textMuted: \"#9AA5B1\"\n  border: \"#222831\"\n  shadow: \"#66000000\"\n  accent: \"#6B8BB8\"\n  success: \"#3CCB74\"\n  warning: \"#D39A45\"\n  danger: \"#D87070\"\n  hover: \"#1B2028\"\nfonts:\n  body: \"SF Pro Text 13\"\n  title: \"SF Pro Rounded 20\"\nspacing:\n  small: 8\n  medium: 16\n  large: 24\nradius:\n  small: 8\n  medium: 12\n  large: 18\nanimations:\n  fast: \"easeInOut 0.18s\"\n  slow: \"easeInOut 0.45s\"\n",
            "layout.yaml": "home:\n  type: stack\n  direction: vertical\n  children: []\n",
            "components.yaml": "button:\n  background: primary\n  text: surface\n  hover: hover\n  active: primary\n  animation: fast\ncard:\n  background: panel\n  text: text\n  hover: hover\n  active: panel\n  animation: slow\nconsole:\n  background: panel\n  text: text\n"
        ]
    }
    private func fallbackThemeFiles_CodexMono() -> [String: String] {
        [
            "theme.yaml": "name: Codex Mono\nversion: \"1.0.0\"\nauthor: JSM\nentry: web/console.html\n",
            "tokens.yaml": "colors:\n  surface: \"#F7F7F7\"\n  panel: \"#FFFFFF\"\n  primary: \"#2B2B2B\"\n  text: \"#111111\"\n  textMuted: \"#5A5A5A\"\n  border: \"#E3E3E3\"\n  shadow: \"#12000000\"\n  accent: \"#5F5F5F\"\n  success: \"#4A4A4A\"\n  warning: \"#6A6A6A\"\n  danger: \"#3A3A3A\"\n  hover: \"#F0F0F0\"\ncolors_dark:\n  surface: \"#0B0B0B\"\n  panel: \"#141414\"\n  primary: \"#E6E6E6\"\n  text: \"#F2F2F2\"\n  textMuted: \"#A0A0A0\"\n  border: \"#222222\"\n  shadow: \"#66000000\"\n  accent: \"#CFCFCF\"\n  success: \"#C5C5C5\"\n  warning: \"#B8B8B8\"\n  danger: \"#D0D0D0\"\n  hover: \"#1B1B1B\"\nfonts:\n  body: \"SF Pro Text 13\"\n  title: \"SF Pro Rounded 20\"\nspacing:\n  small: 8\n  medium: 16\n  large: 24\nradius:\n  small: 8\n  medium: 12\n  large: 18\nanimations:\n  fast: \"easeInOut 0.18s\"\n  slow: \"easeInOut 0.45s\"\n",
            "layout.yaml": "home:\n  type: stack\n  direction: vertical\n  children: []\n",
            "components.yaml": "button:\n  background: primary\n  text: surface\n  hover: hover\n  active: primary\n  animation: fast\ncard:\n  background: panel\n  text: text\n  hover: hover\n  active: panel\n  animation: slow\nconsole:\n  background: panel\n  text: text\n"
        ]
    }

    private func readManifest(from url: URL) -> ThemeManifest? {
#if canImport(Yams)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? YAMLDecoder().decode(ThemeManifest.self, from: text)
#else
        _ = url
        return nil
#endif
    }

    private func uniqueFolderURL(baseName: String, in root: URL? = nil) -> URL {
        let rootURL = root ?? themesDirectory
        let sanitized = sanitizeFolderName(baseName)
        var target = rootURL.appendingPathComponent(sanitized, isDirectory: true)
        var index = 1
        while fileManager.fileExists(atPath: target.path) {
            index += 1
            target = rootURL.appendingPathComponent("\(sanitized)-\(index)", isDirectory: true)
        }
        return target
    }

    private func sanitizeFolderName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_ "))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let joined = String(cleaned).replacingOccurrences(of: " ", with: "-")
        let trimmed = joined.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "Theme" : trimmed
    }
}
