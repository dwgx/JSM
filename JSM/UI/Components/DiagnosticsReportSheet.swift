import SwiftUI
import AppKit

struct DiagnosticsReportSheet: View {
    @ObservedObject var themeBinder: ThemeBinder
    @EnvironmentObject private var appStore: AppStore
    @Binding var isPresented: Bool

    @State private var reportText: String = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("自检报告")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(themeBinder.color("text"))
                Spacer()
                Button(isRunning ? "自检中…" : "重新自检") {
                    Task { await runDiagnostics() }
                }
                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                .disabled(isRunning)

                Button("复制") {
                    copyToPasteboard(reportText)
                }
                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                .disabled(reportText.isEmpty)

                Button("关闭") { isPresented = false }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(themeBinder.color("panel"))

                if isRunning {
                    ProgressView("正在自检…")
                        .foregroundStyle(themeBinder.color("text"))
                        .padding(16)
                } else if reportText.isEmpty {
                    Text("暂无报告")
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                        .padding(16)
                } else {
                    ScrollView {
                        Text(reportText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(themeBinder.color("text"))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 520)
        .background(themeBinder.color("surface").ignoresSafeArea())
        .task {
            if reportText.isEmpty {
                await runDiagnostics()
            }
        }
    }

    private func runDiagnostics() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        reportText = await appStore.diagnosticsReport()
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

