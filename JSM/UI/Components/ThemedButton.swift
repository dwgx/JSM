import SwiftUI

struct ThemedButtonStyle: ButtonStyle {
    @ObservedObject var themeBinder: ThemeBinder

    func makeBody(configuration: Configuration) -> some View {
        let radius = CGFloat(themeBinder.theme?.tokens.radius["small"] ?? 6)
        let border = themeBinder.color("border", fallback: themeBinder.color("text").opacity(0.12))
        let shadow = themeBinder.color("shadow", fallback: Color.black.opacity(0.16))
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .allowsTightening(true)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(themeBinder.color("primary").opacity(configuration.isPressed ? 0.8 : 1.0))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .stroke(border, lineWidth: 1)
                    )
                    .shadow(color: shadow.opacity(0.7), radius: 2, x: 0, y: 1)
            )
            .foregroundStyle(themeBinder.color("surface"))
    }
}
