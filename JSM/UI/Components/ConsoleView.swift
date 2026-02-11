import SwiftUI

struct ConsoleView: View {
    @ObservedObject var themeBinder: ThemeBinder
    @EnvironmentObject private var appStore: AppStore
    let serverID: UUID?
    @State private var commandText: String = ""
    @FocusState private var inputFocused: Bool
    private let consoleHeight: CGFloat = 260

    var body: some View {
        SectionCard(themeBinder: themeBinder, title: "控制台") {
            let lines = serverID.flatMap { appStore.logs(for: $0) } ?? []
            let canSend = serverID != nil
            Group {
                if appStore.consoleRenderer == .web {
                    if lines.isEmpty {
                        ConsolePlaceholder(themeBinder: themeBinder, text: "暂无输出")
                            .frame(height: consoleHeight)
                    } else {
                        WebConsoleView(themeBinder: themeBinder, lines: lines)
                            .frame(height: consoleHeight)
                            .background(themeBinder.color("panel"))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else if lines.isEmpty {
                    ConsolePlaceholder(themeBinder: themeBinder, text: "暂无输出")
                        .frame(height: consoleHeight)
                } else {
                    let nativeText = lines.joined(separator: "\n")
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(nativeText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(themeBinder.color("text"))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                            Color.clear
                                .frame(height: 1)
                                .id("console-bottom")
                        }
                        .frame(height: consoleHeight)
                        .background(themeBinder.color("panel"))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: lines.count) { _, newValue in
                            guard newValue > 0 else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("console-bottom", anchor: .bottom)
                            }
                        }
                        .onAppear {
                            guard !lines.isEmpty else { return }
                            proxy.scrollTo("console-bottom", anchor: .bottom)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("") {
                    inputFocused = true
                }
                .keyboardShortcut(.return, modifiers: [])
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0.0)
                .disabled(inputFocused)

                TextField("输入命令（回车发送）", text: $commandText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!canSend)
                    .focused($inputFocused)
                    .onSubmit { sendCommand() }
                    .onExitCommand { inputFocused = false }
                Button("发送") { sendCommand() }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                    .disabled(!canSend || commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 8)
        }
    }

    private func sendCommand() {
        guard let id = serverID else { return }
        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commandText = ""
        Task { await appStore.sendInput(trimmed + "\n", id: id) }
    }
}
