import Foundation
import SwiftUI
import Combine

/// Adapts Theme tokens into SwiftUI-friendly values. In AppKit layer we can bridge via NSColor/NSFont.
public final class ThemeBinder: ObservableObject {
    @Published public private(set) var theme: ThemePackage?
    @Published public private(set) var appearance: ThemeAppearance = .system
    @Published public private(set) var systemColorScheme: ColorScheme = .light

    public init(theme: ThemePackage? = ThemeDefaults.fallback) {
        self.theme = theme ?? ThemeDefaults.fallback
    }

    public func apply(_ theme: ThemePackage) {
        self.theme = theme
    }

    public func setAppearance(_ value: ThemeAppearance) {
        appearance = value
    }

    public func setSystemColorScheme(_ value: ColorScheme) {
        systemColorScheme = value
    }

    public func color(_ name: String, fallback: Color = .primary) -> Color {
        guard let hex = resolvedColorToken(name), let color = Color(hex: hex) else {
            return fallback
        }
        return color
    }

    public func resolvedColorToken(_ name: String) -> String? {
        guard let theme else { return nil }
        let base = theme.tokens.colors
        let overrides: [String: String]
        switch appearance {
        case .system:
            if systemColorScheme == .dark {
                overrides = theme.tokens.colorsDark ?? [:]
            } else {
                overrides = theme.tokens.colorsLight ?? [:]
            }
        case .light:
            overrides = theme.tokens.colorsLight ?? [:]
        case .dark:
            overrides = theme.tokens.colorsDark ?? [:]
        }
        if overrides.isEmpty {
            return base[name]
        }
        let merged = base.merging(overrides) { _, new in new }
        return merged[name] ?? base[name]
    }
}

private extension Color {
    init?(hex: String) {
        var string = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if string.count == 6 { string = "FF" + string }
        guard let int = UInt64(string, radix: 16) else { return nil }
        let a = Double((int & 0xFF000000) >> 24) / 255.0
        let r = Double((int & 0x00FF0000) >> 16) / 255.0
        let g = Double((int & 0x0000FF00) >> 8) / 255.0
        let b = Double(int & 0x000000FF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
