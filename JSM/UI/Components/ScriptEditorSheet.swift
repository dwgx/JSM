import SwiftUI
import AppKit
import Darwin

struct ScriptEditorSheet: View {
    @ObservedObject var themeBinder: ThemeBinder
    @Binding var isPresented: Bool
    let workspaceBookmark: Data
    let relativePath: String

    @State private var content: String = ""
    @State private var isLoading = true
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var makeExecutableOnSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启动脚本")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(themeBinder.color("text"))
                    Text(relativePath.isEmpty ? "(未选择脚本)" : relativePath)
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                        .textSelection(.enabled)
                }
                Spacer()
                Button("在 Finder 中显示") { revealInFinder() }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                    .disabled(relativePath.isEmpty)
                Button("重新加载") { loadFile() }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                    .disabled(relativePath.isEmpty || isLoading)
                Button("关闭") { isPresented = false }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
            }

            Toggle("保存时设为可执行（chmod +x）", isOn: $makeExecutableOnSave)
                .foregroundStyle(themeBinder.color("text"))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(themeBinder.color("panel"))
                if isLoading {
                    ProgressView("正在加载…")
                        .foregroundStyle(themeBinder.color("text"))
                        .padding(16)
                } else {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(themeBinder.color("text"))
                        .scrollContentBackground(.hidden)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Spacer()
                Button("保存") { saveFile() }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                    .disabled(relativePath.isEmpty || isLoading)
            }
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 560)
        .background(themeBinder.color("surface").ignoresSafeArea())
        .alert("操作失败", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .task {
            if !relativePath.isEmpty {
                loadFile()
            } else {
                isLoading = false
            }
        }
    }

    private func withWorkspaceAccess<T>(_ action: (URL) throws -> T) throws -> T {
        try SandboxAccess.withBookmark(workspaceBookmark) { url in
            try action(url)
        }
    }

    private func resolveScriptURL(workspaceURL: URL) throws -> URL {
        guard !relativePath.isEmpty else {
            throw SandboxAccessError.invalidSelection("未选择脚本路径。")
        }
        return try SandboxAccess.resolveRelativePath(base: workspaceURL, relative: relativePath)
    }

    private func loadFile() {
        guard !relativePath.isEmpty else { return }
        isLoading = true
        Task.detached(priority: .utility) {
            do {
                let text: String = try withWorkspaceAccess { workspaceURL in
                    let fileURL = try resolveScriptURL(workspaceURL: workspaceURL)
                    if FileManager.default.fileExists(atPath: fileURL.path) {
                        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                    }
                    return ""
                }
                await MainActor.run {
                    content = text
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    presentError("读取脚本失败：\(error.localizedDescription)")
                    isLoading = false
                }
            }
        }
    }

    private func saveFile() {
        guard !relativePath.isEmpty else { return }
        isLoading = true
        let textToWrite = content
        let shouldChmod = makeExecutableOnSave
        Task.detached(priority: .utility) {
            do {
                try withWorkspaceAccess { workspaceURL in
                    let fileURL = try resolveScriptURL(workspaceURL: workspaceURL)
                    try textToWrite.write(to: fileURL, atomically: true, encoding: .utf8)
                    if shouldChmod {
                        _ = chmod(fileURL.path, S_IRUSR | S_IWUSR | S_IXUSR | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
                    }
                }
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    presentError("保存脚本失败：\(error.localizedDescription)")
                    isLoading = false
                }
            }
        }
    }

    private func revealInFinder() {
        guard !relativePath.isEmpty else { return }
        do {
            let url: URL = try withWorkspaceAccess { workspaceURL in
                try resolveScriptURL(workspaceURL: workspaceURL)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            presentError("打开失败：\(error.localizedDescription)")
        }
    }

    private func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}
