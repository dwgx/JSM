import SwiftUI
#if canImport(Yams)
import Yams
#endif

private enum ThemeFile: String, CaseIterable, Identifiable {
    case manifest = "theme.yaml"
    case tokens = "tokens.yaml"
    case layout = "layout.yaml"
    case components = "components.yaml"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .manifest: return "theme.yaml"
        case .tokens: return "tokens.yaml"
        case .layout: return "layout.yaml"
        case .components: return "components.yaml"
        }
    }
}

struct ThemePage: View {
    private static let versionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    @ObservedObject var themeBinder: ThemeBinder
    @StateObject private var library = ThemeLibrary()
    @State private var selectedThemeID: String?
    @State private var selectedFile: ThemeFile = .tokens
    @State private var yamlText: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var versions: [ThemeVersion] = []
    @State private var pendingResetVersion: ThemeVersion?
    @State private var showResetConfirm = false
    @State private var autoApply = true
    @State private var autoApplyTask: Task<Void, Never>?
    @State private var previewMessage: String?

    var body: some View {
        HStack(spacing: 16) {
            sidebar
            editor
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(themeBinder.color("surface").ignoresSafeArea())
        .onAppear {
            if selectedThemeID == nil {
                selectedThemeID = preferredThemeID()
            }
        }
        .onChange(of: library.themes.count) { _, _ in
            if selectedThemeID == nil {
                selectedThemeID = preferredThemeID()
            }
        }
        .alert("操作失败", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog("重置主题", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("重置", role: .destructive) {
                if let theme = selectedTheme, let version = pendingResetVersion {
                    do {
                        try library.restoreVersion(version, in: theme)
                        loadSelectedFile()
                        applyTheme()
                        refreshVersions()
                    } catch {
                        presentError("重置失败：\(error)")
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let version = pendingResetVersion {
                Text("确定要重置到“\(version.label)”吗？")
            } else {
                Text("确定要重置到所选版本吗？")
            }
        }
    }

    private var selectedTheme: ThemeInfo? {
        guard let selectedThemeID else { return nil }
        return library.themes.first { $0.id == selectedThemeID }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("主题库")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(themeBinder.color("text"))
                Spacer()
                Button("导入主题") { openImportTheme() }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                Button("导出主题") { exportSelectedTheme() }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
            }

            List(selection: $selectedThemeID) {
                ForEach(library.themes) { theme in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(theme.name)
                            .foregroundStyle(themeBinder.color("text"))
                        Text(theme.url.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                    }
                    .tag(theme.id)
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 240, maxWidth: 260)

            Button("新建主题") { createThemeCopy() }
                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
        }
        .frame(minWidth: 240)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let theme = selectedTheme {
                SectionCard(themeBinder: themeBinder, title: "当前主题") {
                    Text(theme.url.path)
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                }

                Picker("文件", selection: $selectedFile) {
                    ForEach(ThemeFile.allCases) { file in
                        Text(file.title).tag(file)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedFile) { _, _ in
                    loadSelectedFile()
                }

                SectionCard(themeBinder: themeBinder, title: "内置编辑器") {
                    HStack {
                        Toggle("实时预览", isOn: $autoApply)
                            .toggleStyle(.switch)
                            .foregroundStyle(themeBinder.color("text"))
                        Spacer()
                        if let previewMessage {
                            Text(previewMessage)
                                .font(.caption)
                                .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                        }
                    }
                    TextEditor(text: $yamlText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 260)
                    HStack {
                        Button("保存并应用") { saveAndReload() }
                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        Button("重载") { loadSelectedFile() }
                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                    }
                }

                SectionCard(themeBinder: themeBinder, title: "版本历史") {
                    if versions.isEmpty {
                        Text("暂无历史版本")
                            .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(versions) { version in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(version.label)
                                            .foregroundStyle(themeBinder.color("text"))
                                        Text(formatVersionDate(version.createdAt))
                                            .font(.caption2)
                                            .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                                    }
                                    Spacer()
                                    Button("重置") {
                                        pendingResetVersion = version
                                        showResetConfirm = true
                                    }
                                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                                }
                            }
                        }
                    }
                }
            } else {
                SectionCard(themeBinder: themeBinder, title: "提示") {
                    Text("请选择或导入一个主题")
                        .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: selectedThemeID) { _, _ in
            loadSelectedFile()
            applyTheme()
            refreshVersions()
        }
        .onChange(of: yamlText) { _, _ in
            scheduleAutoApply()
        }
        .onChange(of: autoApply) { _, _ in
            scheduleAutoApply()
        }
    }

    private func loadSelectedFile() {
        guard let theme = selectedTheme else { return }
        do {
            yamlText = try library.readFile(selectedFile.rawValue, in: theme)
            previewMessage = nil
        } catch {
            yamlText = ""
            presentError("读取失败：\(error)")
        }
    }

    private func preferredThemeID() -> String? {
        if let jsm = library.themes.first(where: { $0.name == "JSM Default" }) {
            return jsm.id
        }
        if let codex = library.themes.first(where: { $0.name == "Codex Mono" }) {
            return codex.id
        }
        return library.themes.first?.id
    }

    private func saveAndReload() {
        guard let theme = selectedTheme else { return }
        do {
            try library.writeFile(selectedFile.rawValue, content: yamlText, in: theme, recordVersion: true)
            applyTheme()
            refreshVersions()
            previewMessage = "已保存并应用"
        } catch {
            presentError("保存失败：\(error)")
        }
    }

    private func applyTheme(silent: Bool = false) {
        guard let theme = selectedTheme else { return }
        let engine = ThemeEngine()
        do {
            try engine.loadTheme(at: theme.url)
            if let pkg = engine.currentTheme {
                themeBinder.apply(pkg)
            }
        } catch {
            if !silent {
                presentError("主题加载失败：\(error)")
            }
        }
    }

    private func scheduleAutoApply() {
        autoApplyTask?.cancel()
        guard autoApply else {
            if previewMessage != "实时预览已关闭" {
                previewMessage = "实时预览已关闭"
            }
            return
        }
        let text = yamlText
        let file = selectedFile
        autoApplyTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                autoApplyPreview(text: text, file: file)
            }
        }
    }

    private func autoApplyPreview(text: String, file: ThemeFile) {
        guard let theme = selectedTheme else { return }
#if canImport(Yams)
        let decoder = YAMLDecoder()
        do {
            switch file {
            case .manifest:
                _ = try decoder.decode(ThemeManifest.self, from: text)
            case .tokens:
                _ = try decoder.decode(ThemeTokens.self, from: text)
            case .layout:
                _ = try decoder.decode([String: LayoutNode].self, from: text)
            case .components:
                _ = try decoder.decode([String: ComponentStyle].self, from: text)
            }
        } catch {
            previewMessage = "语法错误：\(error.localizedDescription)"
            return
        }
#else
        previewMessage = "缺少 Yams，无法预览"
        return
#endif

        do {
            try library.writeFile(file.rawValue, content: text, in: theme, recordVersion: false)
            applyTheme(silent: true)
            previewMessage = "已预览（未生成版本）"
        } catch {
            previewMessage = "预览失败：\(error.localizedDescription)"
        }
    }

    private func refreshVersions() {
        guard let theme = selectedTheme else {
            versions = []
            return
        }
        versions = library.listVersions(for: theme)
    }

    private func formatVersionDate(_ date: Date) -> String {
        Self.versionDateFormatter.string(from: date)
    }

    private func openImportTheme() {
        FileDialogs.openFolder(prompt: "选择主题文件夹") { url in
            guard let url else { return }
            do {
                try library.importTheme(from: url)
            } catch {
                presentError("导入失败：\(error)")
            }
        }
    }

    private func exportSelectedTheme() {
        guard let theme = selectedTheme else { return }
        FileDialogs.openFolder(prompt: "选择导出位置") { url in
            guard let url else { return }
            do {
                try library.exportTheme(theme, to: url)
            } catch {
                presentError("导出失败：\(error)")
            }
        }
    }

    private func createThemeCopy() {
        do {
            let newTheme = try library.createThemeCopy(from: selectedTheme)
            selectedThemeID = newTheme.id
        } catch {
            presentError("新建失败：\(error)")
        }
    }

    private func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    ThemePage(themeBinder: ThemeBinder())
}
