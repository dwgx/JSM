import SwiftUI

struct StatCard: View {
    @ObservedObject var themeBinder: ThemeBinder
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        let radius = CGFloat(themeBinder.theme?.tokens.radius["medium"] ?? 10)
        let border = themeBinder.color("border", fallback: themeBinder.color("text").opacity(0.08))
        let shadow = themeBinder.color("shadow", fallback: Color.black.opacity(0.12))
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(themeBinder.color("text").opacity(0.6))
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(themeBinder.color("text"))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(themeBinder.color("text").opacity(0.5))
        }
        .padding(12)
        .frame(minWidth: 160, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(themeBinder.color("panel"))
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(border, lineWidth: 1)
                )
                .shadow(color: shadow.opacity(0.6), radius: 2, x: 0, y: 1)
        )
    }
}
