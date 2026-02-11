import Foundation

public enum ThemeDefaults {
    public static let fallback = ThemePackage(
        manifest: ThemeManifest(name: "JSM Default",
                                version: "1.1.0",
                                author: "JSM",
                                entry: "web/console.html"),
        tokens: ThemeTokens(
            colors: [
                "surface": "#F1F3F6",
                "panel": "#F7F8FA",
                "primary": "#2AAE68",
                "text": "#1A1F24",
                "textMuted": "#5A6570",
                "border": "#D7DCE3",
                "shadow": "#12000000",
                "accent": "#3A6EA5",
                "success": "#2AAE68",
                "warning": "#C98A2C",
                "danger": "#D25A5A",
                "hover": "#E8EBF0"
            ],
            colorsLight: [
                "surface": "#F1F3F6",
                "panel": "#F7F8FA",
                "primary": "#2AAE68",
                "text": "#1A1F24",
                "textMuted": "#5A6570",
                "border": "#D7DCE3",
                "shadow": "#12000000",
                "accent": "#3A6EA5",
                "success": "#2AAE68",
                "warning": "#C98A2C",
                "danger": "#D25A5A",
                "hover": "#E8EBF0"
            ],
            colorsDark: [
                "surface": "#0E1115",
                "panel": "#14181E",
                "primary": "#3CCB74",
                "text": "#E2E7ED",
                "textMuted": "#9AA5B1",
                "border": "#222831",
                "shadow": "#66000000",
                "accent": "#6B8BB8",
                "success": "#3CCB74",
                "warning": "#D39A45",
                "danger": "#D87070",
                "hover": "#1B2028"
            ],
            fonts: [
                "body": "SF Pro Text 13",
                "title": "SF Pro Rounded 20"
            ],
            spacing: [
                "small": 8,
                "medium": 16,
                "large": 24
            ],
            radius: [
                "small": 8,
                "medium": 12,
                "large": 18
            ],
            animations: [
                "fast": "easeInOut 0.18s",
                "slow": "easeInOut 0.45s"
            ]
        ),
        layout: [
            "home": LayoutNode(type: .stack, direction: "vertical", ratio: nil, children: [])
        ],
        components: [
            "button": ComponentStyle(background: "primary", text: "surface", hover: "hover", active: "primary", animation: "fast"),
            "card": ComponentStyle(background: "panel", text: "text", hover: "hover", active: "panel", animation: "slow"),
            "console": ComponentStyle(background: "panel", text: "text", hover: nil, active: nil, animation: nil)
        ]
    )
}
