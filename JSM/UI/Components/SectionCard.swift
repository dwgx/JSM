import SwiftUI

struct SectionCard<Content: View>: View {
    @ObservedObject var themeBinder: ThemeBinder
    let title: String
    let content: Content

    init(themeBinder: ThemeBinder, title: String, @ViewBuilder content: () -> Content) {
        self.themeBinder = themeBinder
        self.title = title
        self.content = content()
    }

    var body: some View {
        let radius = CGFloat(themeBinder.theme?.tokens.radius["medium"] ?? 10)
        let border = themeBinder.color("border", fallback: themeBinder.color("text").opacity(0.08))
        let shadow = themeBinder.color("shadow", fallback: Color.black.opacity(0.14))
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(themeBinder.color("text"))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(themeBinder.color("panel"))
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(border, lineWidth: 1)
                )
                .shadow(color: shadow.opacity(0.65), radius: 3, x: 0, y: 1)
        )
    }
}
