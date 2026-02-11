import Foundation

public protocol ThemeEngineType {
    var currentTheme: ThemePackage? { get }
    func loadTheme(at url: URL) throws
    func reload() throws
    func resolveColor(_ name: String) -> String?
    func resolveFont(_ name: String) -> String?
}

/// Thin wrapper around ThemeLoader that keeps resolved theme in memory and allows hot reload.
public final class ThemeEngine: ThemeEngineType {
    private let loader: ThemeLoading
    private(set) public var currentTheme: ThemePackage?
    private var themeURL: URL?

    public init(loader: ThemeLoading = ThemeLoader()) {
        self.loader = loader
    }

    public func loadTheme(at url: URL) throws {
        let pkg = try loader.loadTheme(at: url)
        guard loader.validateTheme(pkg) else { throw ThemeError.invalidPackage }
        currentTheme = pkg
        themeURL = url
    }

    public func reload() throws {
        guard let url = themeURL else { throw ThemeError.missingFile("theme root") }
        try loadTheme(at: url)
    }

    public func resolveColor(_ name: String) -> String? {
        currentTheme?.tokens.colors[name]
    }

    public func resolveFont(_ name: String) -> String? {
        currentTheme?.tokens.fonts[name]
    }
}
