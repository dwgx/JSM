import SwiftUI

struct ConsolePlaceholder: View {
    @ObservedObject var themeBinder: ThemeBinder
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
