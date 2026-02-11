import Foundation
#if canImport(Yams)
import Yams
#endif

public struct ThemeManifest: Codable {
    public var name: String
    public var version: String
    public var author: String?
    public var entry: String?
}

public struct ThemeTokens: Codable {
    public var colors: [String: String]
    public var colorsLight: [String: String]?
    public var colorsDark: [String: String]?
    public var fonts: [String: String]
    public var spacing: [String: Double]
    public var radius: [String: Double]
    public var animations: [String: String]

    enum CodingKeys: String, CodingKey {
        case colors
        case colorsLight = "colors_light"
        case colorsDark = "colors_dark"
        case fonts
        case spacing
        case radius
        case animations
    }
}

public struct LayoutNode: Codable {
    public enum NodeType: String, Codable { case split, stack, grid }
    public var type: NodeType
    public var direction: String?
    public var ratio: Double?
    public var children: [LayoutNode]?
}

public struct ThemePackage: Codable {
    public var manifest: ThemeManifest
    public var tokens: ThemeTokens
    public var layout: [String: LayoutNode]
    public var components: [String: ComponentStyle]
}

public struct ComponentStyle: Codable {
    public var background: String?
    public var text: String?
    public var hover: String?
    public var active: String?
    public var animation: String?
}

public enum ThemeAppearance: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

public enum ThemeError: Error {
    case invalidPackage
    case missingFile(String)
    case decode(Error)
    case missingDependency(String)
}

public protocol ThemeLoading {
    func loadTheme(at url: URL) throws -> ThemePackage
    func validateTheme(_ package: ThemePackage) -> Bool
}

public final class ThemeLoader: ThemeLoading {
    public init() {}

    public func loadTheme(at url: URL) throws -> ThemePackage {
        let manifestURL = url.appendingPathComponent("theme.yaml")
        let tokensURL = url.appendingPathComponent("tokens.yaml")
        let layoutURL = url.appendingPathComponent("layout.yaml")
        let componentsURL = url.appendingPathComponent("components.yaml")

#if canImport(Yams)
        let decoder = YAMLDecoder()
        do {
            let manifest = try decoder.decode(ThemeManifest.self, from: String(contentsOf: manifestURL))
            let tokens = try decoder.decode(ThemeTokens.self, from: String(contentsOf: tokensURL))
            let layout = try decoder.decode([String: LayoutNode].self, from: String(contentsOf: layoutURL))
            let components = try decoder.decode([String: ComponentStyle].self, from: String(contentsOf: componentsURL))
            return ThemePackage(manifest: manifest, tokens: tokens, layout: layout, components: components)
        } catch {
            throw ThemeError.decode(error)
        }
#else
        throw ThemeError.missingDependency("Yams")
#endif
    }

    public func validateTheme(_ package: ThemePackage) -> Bool {
        return !package.tokens.colors.isEmpty && !package.layout.isEmpty
    }
}
