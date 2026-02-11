import SwiftUI

struct SettingsPage: View {
    @ObservedObject var themeBinder: ThemeBinder
    @EnvironmentObject private var appStore: AppStore
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showDiagnosticsSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("设置")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(themeBinder.color("text"))

                SectionCard(themeBinder: themeBinder, title: "性能采样") {
                    HStack {
                        Text("采样间隔 \(Int(appStore.metricsInterval)) 秒")
                            .foregroundStyle(themeBinder.color("text"))
                        Slider(value: Binding(get: {
                            appStore.metricsInterval
                        }, set: { newValue in
                            appStore.setMetricsInterval(newValue)
                        }), in: 1...10, step: 1)
                    }
                }

            SectionCard(themeBinder: themeBinder, title: "控制台渲染") {
                Picker("渲染器", selection: $appStore.consoleRenderer) {
                    Text("原生").tag(ConsoleRenderer.native)
                    Text("Web").tag(ConsoleRenderer.web)
                }
                .pickerStyle(.segmented)
            }

            SectionCard(themeBinder: themeBinder, title: "进程关闭") {
                Picker("关闭方式", selection: $appStore.processStopStrategy) {
                    Text("先停止后手动强制（推荐）").tag(ProcessStopStrategy.stopSignalThenManualForce)
                    Text("先停止后自动强制").tag(ProcessStopStrategy.stopSignalThenAutoForce)
                    Text("直接强制结束").tag(ProcessStopStrategy.immediateForceKill)
                }
                .pickerStyle(.menu)
                Text("发送停止信号后，超过 5 秒仍无响应时，可显示或自动执行“强制关闭”。")
                    .font(.caption)
                    .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
            }

            SectionCard(themeBinder: themeBinder, title: "主题外观") {
                Picker("外观", selection: $appStore.themeAppearance) {
                    Text("跟随系统").tag(ThemeAppearance.system)
                    Text("浅色").tag(ThemeAppearance.light)
                    Text("深色").tag(ThemeAppearance.dark)
                }
                .pickerStyle(.segmented)
            }

            SectionCard(themeBinder: themeBinder, title: "Java Runtime") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appStore.javaExecutable.isEmpty ? "未配置" : appStore.javaExecutable)
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.7)))
                        .textSelection(.enabled)

                        Group {
                            if appStore.javaExecutable.isEmpty {
                                Text("状态：未配置")
                            } else if appStore.hasJavaExecutableBookmark {
                                if appStore.javaBookmarkIsUsable {
                                    Text("状态：已授权（可用）")
                                } else if appStore.javaBookmarkBlocksExecution {
                                    Text("状态：已授权，但沙盒禁止执行（需更换 Java 安装位置或放行权限）")
                                } else {
                                    Text("状态：已授权，但当前路径不可用")
                                }
                            } else if appStore.hasUsableJavaConfiguration {
                                Text("状态：可用（无需授权）")
                            } else {
                                Text("状态：已检测到路径，但未授权（启动会提示）")
                            }
                    }
                    .font(.caption2)
                    .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))

                        HStack(spacing: 8) {
                            Button("自动分析并修复") { repairJava() }
                                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                            Button("选择 Java Home") { chooseJavaHome() }
                                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                            Button("自检") { showDiagnosticsSheet = true }
                                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        }
                    Text("JSM 需要 Java Home（包含 bin/java）。SDKMAN：建议选择 ~/.sdkman/candidates/java（再选具体版本），或直接选择 ~/.sdkman/candidates/java/current/bin/java。")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                }
            }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(themeBinder.color("surface").ignoresSafeArea())
        .sheet(isPresented: $showDiagnosticsSheet) {
            DiagnosticsReportSheet(themeBinder: themeBinder, isPresented: $showDiagnosticsSheet)
                .environmentObject(appStore)
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func repairJava() {
        Task { @MainActor in
            let detected = await appStore.autoDetectJava()
            if appStore.hasUsableJavaConfiguration {
                presentError("已配置 Java：\(appStore.javaExecutable)")
                return
            }
            guard appStore.javaAuthorizationRequest == nil else { return }
            let suggested = JavaLocator.likelyJavaHomeDirectories().first ?? JavaLocator.suggestedJavaHomeDirectories().first
            appStore.requestJavaAuthorization(reason: detected ? "检测到 Java，但需要授权 Java Home。" : "未检测到 Java，请选择 Java Home。", suggestedHome: suggested)
        }
    }

    private func chooseJavaHome() {
        let suggested = JavaLocator.likelyJavaHomeDirectories().first ?? JavaLocator.suggestedJavaHomeDirectories().first
        appStore.requestJavaAuthorization(reason: "请选择 Java Home（包含 bin/java），也可以直接选择 bin/java 可执行文件。", suggestedHome: suggested)
    }

    private func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }

}

#Preview {
    SettingsPage(themeBinder: ThemeBinder())
        .environmentObject(AppStore())
}
