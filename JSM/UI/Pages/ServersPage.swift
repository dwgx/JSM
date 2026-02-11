import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ServersPage: View {
    @ObservedObject var themeBinder: ThemeBinder
    @EnvironmentObject private var appStore: AppStore

    @State private var yamlText: String = ""
    @State private var isEditing = false
    @State private var showExporter = false
    @State private var showNewServer = false
    @State private var showEditServer = false
    @State private var showDeleteConfirm = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        HStack(spacing: 16) {
            sidebar
            detail
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(themeBinder.color("surface").ignoresSafeArea())
        .fileExporter(isPresented: $showExporter, document: BundleDocument(), contentType: .zip) { result in
            if case .success(let url) = result, let id = appStore.selectedServerID {
                try? appStore.exportServer(id: id, to: url)
            }
        }
        .sheet(isPresented: $showNewServer) {
            NewServerSheet(themeBinder: themeBinder, isPresented: $showNewServer)
                .environmentObject(appStore)
        }
        .sheet(isPresented: $showEditServer) {
            if let id = appStore.selectedServerID, let server = appStore.server(for: id) {
                EditServerSheet(themeBinder: themeBinder, isPresented: $showEditServer, server: server)
                    .environmentObject(appStore)
            }
        }
        .onChange(of: showEditServer) { _, newValue in
            if !newValue, let id = appStore.selectedServerID {
                yamlText = appStore.yaml(for: id)
            }
        }
        .onAppear {
            if yamlText.isEmpty, let id = appStore.selectedServerID {
                yamlText = appStore.yaml(for: id)
            }
        }
        .onChange(of: appStore.selectedServerID) { _, newValue in
            if let id = newValue {
                yamlText = appStore.yaml(for: id)
            }
        }
        .confirmationDialog("删除服务器", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = appStore.selectedServerID {
                    appStore.removeServer(id: id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除该服务器配置吗？此操作不可撤销。")
        }
        .alert("操作失败", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("服务器")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(themeBinder.color("text"))
                Spacer()
                Menu {
                    Button("导入 YAML…") { openImportFlow() }
                    Button("导入 Bundle…") { openBundleImportFlow() }
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
            }

            List(selection: $appStore.selectedServerID) {
                ForEach(appStore.servers) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.name)
                            .foregroundStyle(themeBinder.color("text"))
                        Text(server.entry.kind.rawValue)
                            .font(.caption)
                            .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                    }
                    .tag(server.id)
                }
                .onDelete { indices in
                    indices.map { appStore.servers[$0].id }.forEach { appStore.removeServer(id: $0) }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 240, maxWidth: 260)

            Button("新建服务器") { showNewServer = true }
                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
        }
        .frame(minWidth: 240, maxWidth: 260)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let id = appStore.selectedServerID, let server = appStore.server(for: id) {
                let runtime = appStore.runtime(for: id)
                let state = runtime?.state ?? .stopped
                let canStart = state == .stopped || state == .crashed
                let canStop = state == .running || state == .starting
                let canRestart = state == .running
                let canForceStop = appStore.forceStopAvailableServerIDs.contains(id)
                HStack {
                    VStack(alignment: .leading) {
                        Text(server.name)
                            .font(.headline)
                            .foregroundStyle(themeBinder.color("text"))
                        Text("ID: \(server.id.uuidString)")
                            .font(.caption)
                            .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("启动") {
                            Task { await appStore.startServer(id: id) }
                        }
                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        .disabled(!canStart)
                        Button("停止") {
                            Task { await appStore.stopServer(id: id) }
                        }
                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        .disabled(!canStop)
                        Button("重启") {
                            Task { await appStore.restartServer(id: id) }
                        }
                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        .disabled(!canRestart)
                        if canForceStop {
                            Button("强制关闭") {
                                Task { await appStore.forceStopServer(id: id) }
                            }
                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        }

                        Menu {
                            Button("打开文件夹") { openWorkspaceFolder(for: server) }
                            Button("编辑") { showEditServer = true }
                            Divider()
                            Button("删除", role: .destructive) { showDeleteConfirm = true }
                        } label: {
                            Label("更多", systemImage: "ellipsis.circle")
                        }
                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                    }
                }

                SectionCard(themeBinder: themeBinder, title: "运行状态") {
                    Text("状态: \(localizedState(state))")
                        .foregroundStyle(themeBinder.color("text"))
                    if let snapshot = runtime?.metricsSnapshot {
                        Text(String(format: "CPU: %.1f%%  内存: %.2f MB  线程: %d", snapshot.cpuPercent, Double(snapshot.memoryBytes) / 1024.0 / 1024.0, snapshot.threadCount))
                            .font(.caption)
                            .foregroundStyle(themeBinder.color("text").opacity(0.7))
                    }
                }

                SectionCard(themeBinder: themeBinder, title: "YAML 配置") {
                    TextEditor(text: $yamlText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 240)
                        .onTapGesture { isEditing = true }
                    HStack {
                        Button("保存") {
                            do {
                                try appStore.updateFromYAML(yamlText, id: id)
                                isEditing = false
                            } catch {
                                presentError("保存失败：\(error)")
                            }
                        }
                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        Button("导出 Bundle") { showExporter = true }
                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                    }
                }
            } else {
                SectionCard(themeBinder: themeBinder, title: "提示") {
                    Text("请选择或导入一个服务器配置")
                        .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func localizedState(_ state: RuntimeState) -> String {
        switch state {
        case .stopped:
            return "已停止"
        case .starting:
            return "启动中"
        case .stopping:
            return "关闭中"
        case .running:
            return "运行中"
        case .crashed:
            return "异常退出"
        }
    }

    private var yamlTypes: [UTType] {
        var types: [UTType] = []
        if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        types.append(.data)
        return types
    }

    private var zipTypes: [UTType] {
        [.zip, .data]
    }

    private func openImportFlow() {
        FileDialogs.openFile(allowedTypes: yamlTypes, prompt: "选择服务器配置") { url in
            guard let url else { return }
            FileDialogs.openFolder(prompt: "选择工作目录") { workspaceURL in
                guard let workspaceURL else { return }
                do {
                    try appStore.importServer(from: url, workspaceURL: workspaceURL)
                } catch {
                    presentError("导入失败：\(error)")
                }
            }
        }
    }

    private func openBundleImportFlow() {
        FileDialogs.openFile(allowedTypes: zipTypes, prompt: "选择 Bundle") { url in
            guard let url else { return }
            FileDialogs.openFolder(prompt: "选择工作目录") { workspaceURL in
                guard let workspaceURL else { return }
                do {
                    try appStore.importBundle(from: url, workspaceURL: workspaceURL)
                } catch {
                    presentError("导入 Bundle 失败：\(error)")
                }
            }
        }
    }

    private func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func openWorkspaceFolder(for server: ServerDefinition) {
        do {
            try SandboxAccess.withBookmark(server.workspaceBookmark) { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            presentError("打开工作目录失败：\(error)")
        }
    }
}

private struct BundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    init() {}
    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

private enum ServerFormError: LocalizedError {
    case invalidEnvLine(String)
    case invalidStopSignal(String)

    var errorDescription: String? {
        switch self {
        case .invalidEnvLine(let line):
            return "环境变量格式错误：\(line)（应为 KEY=VALUE）"
        case .invalidStopSignal(let message):
            return message
        }
    }
}

private func formatLines(_ lines: [String]) -> String {
    lines.joined(separator: "\n")
}

private func parseLines(_ text: String) -> [String] {
    text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func formatEnv(_ env: [String: String]) -> String {
    env.keys.sorted().map { key in
        "\(key)=\(env[key] ?? "")"
    }.joined(separator: "\n")
}

private func parseEnv(_ text: String) throws -> [String: String] {
    var env: [String: String] = [:]
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        guard let idx = line.firstIndex(of: "=") else {
            throw ServerFormError.invalidEnvLine(line)
        }
        let key = line[..<idx].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: idx)...]
        guard !key.isEmpty else {
            throw ServerFormError.invalidEnvLine(line)
        }
        env[String(key)] = String(value)
    }
    return env
}

private func parseStopSignal(useCustom: Bool, text: String) throws -> Int32? {
    guard useCustom else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw ServerFormError.invalidStopSignal("请输入停止信号编号。")
    }
    guard let value = Int32(trimmed), value > 0 else {
        throw ServerFormError.invalidStopSignal("停止信号编号无效：\(trimmed)")
    }
    return value
}

struct NewServerSheet: View {
    @ObservedObject var themeBinder: ThemeBinder
    @EnvironmentObject private var appStore: AppStore
    @Binding var isPresented: Bool

    @State private var name: String = ""
    @State private var entryKind: ServerEntryKind = .jar
    @State private var entryPath: String = ""
    @State private var mainClass: String = ""
    @State private var workspaceURL: URL?
    @State private var showWorkspacePicker = false
    @State private var restartOnCrash: Bool = false
    @State private var maxRestarts: Int = 3
    @State private var javaOptionsText: String = ""
    @State private var programArgsText: String = ""
    @State private var envText: String = ""
    @State private var useCustomStopSignal: Bool = false
    @State private var stopSignalText: String = ""
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("新建服务器")
                    .font(.headline)
                    .foregroundStyle(themeBinder.color("text"))

                TextField("名称", text: $name)
                    .textFieldStyle(.roundedBorder)

                Picker("入口类型", selection: $entryKind) {
                    Text("Jar").tag(ServerEntryKind.jar)
                    Text("MainClass").tag(ServerEntryKind.mainClass)
                    Text("Script").tag(ServerEntryKind.script)
                }
                .pickerStyle(.segmented)

                if entryKind == .mainClass {
                    TextField("MainClass", text: $mainClass)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 8) {
                        TextField(entryKind == .jar ? "Jar 路径（相对工作目录）" : "脚本路径（相对工作目录）", text: $entryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseEntryFile() }
                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                    }
                }

                HStack {
                    Text(workspaceURL?.path ?? "未选择工作目录")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                    Spacer()
                    Button("选择工作目录") { showWorkspacePicker = true }
                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("生命周期")
                        .font(.subheadline)
                        .foregroundStyle(themeBinder.color("text"))

                    Toggle("崩溃自动重启", isOn: $restartOnCrash)
                        .foregroundStyle(themeBinder.color("text"))

                    Stepper("最大重启次数：\(maxRestarts)", value: $maxRestarts, in: 1...20)
                        .foregroundStyle(themeBinder.color("text"))
                        .disabled(!restartOnCrash)

                    Toggle("自定义停止信号", isOn: $useCustomStopSignal)
                        .foregroundStyle(themeBinder.color("text"))

                    if useCustomStopSignal {
                        HStack(spacing: 8) {
                            TextField("信号编号（例如 15）", text: $stopSignalText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                            Menu("常用信号") {
                                Button("SIGTERM (15)") { stopSignalText = "15" }
                                Button("SIGINT (2)") { stopSignalText = "2" }
                                Button("SIGKILL (9)") { stopSignalText = "9" }
                                Button("SIGHUP (1)") { stopSignalText = "1" }
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("启动参数")
                        .font(.subheadline)
                        .foregroundStyle(themeBinder.color("text"))

                    Text("Java Options（每行一条）")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                    TextEditor(text: $javaOptionsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 72)

                    Text("Program Args（每行一条）")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                    TextEditor(text: $programArgsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 72)

                    Text("环境变量（KEY=VALUE，每行一条）")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                    TextEditor(text: $envText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 72)
                }

                HStack {
                    Spacer()
                    Button("取消") { isPresented = false }
                    Button("创建") {
                        guard let workspaceURL else { return }
                        let entry: ServerEntry
                        switch entryKind {
                        case .jar:
                            entry = ServerEntry(kind: .jar, path: entryPath)
                        case .mainClass:
                            entry = ServerEntry(kind: .mainClass, mainClass: mainClass)
                        case .script:
                            entry = ServerEntry(kind: .script, path: entryPath)
                        }
                        do {
                            let javaOptions = parseLines(javaOptionsText)
                            let programArgs = parseLines(programArgsText)
                            let env = try parseEnv(envText)
                            let stopSignal = try parseStopSignal(useCustom: useCustomStopSignal, text: stopSignalText)
                            try appStore.createServer(name: name.isEmpty ? "Untitled" : name,
                                                      workspaceURL: workspaceURL,
                                                      entry: entry,
                                                      javaOptions: javaOptions,
                                                      programArgs: programArgs,
                                                      env: env,
                                                      lifecycle: LifecyclePolicy(restartOnCrash: restartOnCrash,
                                                                                 maxRestarts: maxRestarts,
                                                                                 stopSignal: stopSignal))
                            isPresented = false
                        } catch {
                            presentError("创建服务器失败：\(error.localizedDescription)")
                        }
                    }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 720)
        .background(themeBinder.color("surface"))
        .fileImporter(isPresented: $showWorkspacePicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                workspaceURL = url
            }
        }
        .alert("操作失败", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var jarTypes: [UTType] {
        var types: [UTType] = []
        if let jar = UTType(filenameExtension: "jar") { types.append(jar) }
        types.append(.data)
        return types
    }

    private var scriptTypes: [UTType] {
        var types: [UTType] = []
        if let sh = UTType(filenameExtension: "sh") { types.append(sh) }
        if let command = UTType(filenameExtension: "command") { types.append(command) }
        types.append(contentsOf: [.unixExecutable, .plainText, .text, .data])
        var seen: Set<String> = []
        return types.filter { seen.insert($0.identifier).inserted }
    }

    private func chooseEntryFile() {
        guard entryKind != .mainClass else { return }
        guard let workspaceURL else {
            presentError("请先选择工作目录。")
            return
        }
        let types = (entryKind == .jar) ? jarTypes : scriptTypes
        let prompt = entryKind == .jar ? "选择 Jar 文件" : "选择启动脚本"
        FileDialogs.openFile(allowedTypes: types, prompt: prompt, initialDirectory: workspaceURL) { url in
            guard let url else { return }
            guard let relative = relativePathIfInsideWorkspace(workspaceURL: workspaceURL, fileURL: url) else {
                presentError("入口文件必须位于工作目录内（沙盒限制）。")
                return
            }
            entryPath = relative
        }
    }

    private func relativePathIfInsideWorkspace(workspaceURL: URL, fileURL: URL) -> String? {
        let workspaceCandidates = [
            workspaceURL.standardizedFileURL,
            workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        ]
        let fileCandidates = [
            fileURL.standardizedFileURL,
            fileURL.resolvingSymlinksInPath().standardizedFileURL
        ]

        for base in workspaceCandidates {
            let basePrefix = base.path.hasSuffix("/") ? base.path : "\(base.path)/"
            for file in fileCandidates {
                if file.path.hasPrefix(basePrefix) {
                    return String(file.path.dropFirst(basePrefix.count))
                }
            }
        }
        return nil
    }

    private func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

struct EditServerSheet: View {
    @ObservedObject var themeBinder: ThemeBinder
    @EnvironmentObject private var appStore: AppStore
    @Binding var isPresented: Bool
    let server: ServerDefinition

    @State private var name: String
    @State private var entryKind: ServerEntryKind
    @State private var entryPath: String
    @State private var mainClass: String
    @State private var workspaceURL: URL?
    @State private var showWorkspacePicker = false
    @State private var restartOnCrash: Bool
    @State private var maxRestarts: Int
    @State private var javaOptionsText: String
    @State private var programArgsText: String
    @State private var envText: String
    @State private var useCustomStopSignal: Bool
    @State private var stopSignalText: String
    @State private var showScriptEditor = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    init(themeBinder: ThemeBinder, isPresented: Binding<Bool>, server: ServerDefinition) {
        self.themeBinder = themeBinder
        self._isPresented = isPresented
        self.server = server
        _name = State(initialValue: server.name)
        _entryKind = State(initialValue: server.entry.kind)
        _entryPath = State(initialValue: server.entry.path ?? "")
        _mainClass = State(initialValue: server.entry.mainClass ?? "")
        _workspaceURL = State(initialValue: (try? Bookmark(data: server.workspaceBookmark).resolve()))
        _restartOnCrash = State(initialValue: server.lifecycle.restartOnCrash)
        _maxRestarts = State(initialValue: server.lifecycle.maxRestarts)
        _javaOptionsText = State(initialValue: formatLines(server.javaOptions))
        _programArgsText = State(initialValue: formatLines(server.programArgs))
        _envText = State(initialValue: formatEnv(server.env))
        _useCustomStopSignal = State(initialValue: server.lifecycle.stopSignal != nil)
        _stopSignalText = State(initialValue: server.lifecycle.stopSignal.map(String.init) ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("编辑服务器")
                    .font(.headline)
                    .foregroundStyle(themeBinder.color("text"))

                TextField("名称", text: $name)
                    .textFieldStyle(.roundedBorder)

                Picker("入口类型", selection: $entryKind) {
                    Text("Jar").tag(ServerEntryKind.jar)
                    Text("MainClass").tag(ServerEntryKind.mainClass)
                    Text("Script").tag(ServerEntryKind.script)
                }
                .pickerStyle(.segmented)

                if entryKind == .mainClass {
                    TextField("MainClass", text: $mainClass)
                        .textFieldStyle(.roundedBorder)
                } else {
                    HStack(spacing: 8) {
                        TextField(entryKind == .jar ? "Jar 路径（相对工作目录）" : "脚本路径（相对工作目录）", text: $entryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { chooseEntryFile() }
                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        if entryKind == .script {
                            Button("编辑脚本") {
                                if entryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    presentError("请先选择脚本路径。")
                                } else {
                                    showScriptEditor = true
                                }
                            }
                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        }
                    }
                }

                HStack {
                    Text(workspaceURL?.path ?? "未选择工作目录")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                    Spacer()
                    Button("选择工作目录") { showWorkspacePicker = true }
                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("生命周期")
                        .font(.subheadline)
                        .foregroundStyle(themeBinder.color("text"))

                    Toggle("崩溃自动重启", isOn: $restartOnCrash)
                        .foregroundStyle(themeBinder.color("text"))

                    Stepper("最大重启次数：\(maxRestarts)", value: $maxRestarts, in: 1...20)
                        .foregroundStyle(themeBinder.color("text"))
                        .disabled(!restartOnCrash)

                    Toggle("自定义停止信号", isOn: $useCustomStopSignal)
                        .foregroundStyle(themeBinder.color("text"))

                    if useCustomStopSignal {
                        HStack(spacing: 8) {
                            TextField("信号编号（例如 15）", text: $stopSignalText)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                            Menu("常用信号") {
                                Button("SIGTERM (15)") { stopSignalText = "15" }
                                Button("SIGINT (2)") { stopSignalText = "2" }
                                Button("SIGKILL (9)") { stopSignalText = "9" }
                                Button("SIGHUP (1)") { stopSignalText = "1" }
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("启动参数")
                        .font(.subheadline)
                        .foregroundStyle(themeBinder.color("text"))

                    Text("Java Options（每行一条）")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                    TextEditor(text: $javaOptionsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 72)

                    Text("Program Args（每行一条）")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                    TextEditor(text: $programArgsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 72)

                    Text("环境变量（KEY=VALUE，每行一条）")
                        .font(.caption)
                        .foregroundStyle(themeBinder.color("text").opacity(0.6))
                    TextEditor(text: $envText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 72)
                }

                HStack {
                    Spacer()
                    Button("取消") { isPresented = false }
                    Button("保存") {
                        let entry: ServerEntry
                        switch entryKind {
                        case .jar:
                            entry = ServerEntry(kind: .jar, path: entryPath)
                        case .mainClass:
                            entry = ServerEntry(kind: .mainClass, mainClass: mainClass)
                        case .script:
                            entry = ServerEntry(kind: .script, path: entryPath)
                        }
                        do {
                            let javaOptions = parseLines(javaOptionsText)
                            let programArgs = parseLines(programArgsText)
                            let env = try parseEnv(envText)
                            let stopSignal = try parseStopSignal(useCustom: useCustomStopSignal, text: stopSignalText)
                            var updated = server
                            updated.name = name.isEmpty ? server.name : name
                            updated.entry = entry
                            updated.javaOptions = javaOptions
                            updated.programArgs = programArgs
                            updated.env = env
                            updated.lifecycle = LifecyclePolicy(restartOnCrash: restartOnCrash,
                                                               maxRestarts: maxRestarts,
                                                               stopSignal: stopSignal)
                            if let workspaceURL {
                                if let bookmark = try? Bookmark.create(for: workspaceURL) {
                                    updated.workspaceBookmark = bookmark.data
                                }
                            }
                            appStore.updateServer(updated)
                            isPresented = false
                        } catch {
                            presentError("保存失败：\(error.localizedDescription)")
                        }
                    }
                    .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 720)
        .background(themeBinder.color("surface"))
        .fileImporter(isPresented: $showWorkspacePicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                workspaceURL = url
            }
        }
        .sheet(isPresented: $showScriptEditor) {
            ScriptEditorSheet(themeBinder: themeBinder, isPresented: $showScriptEditor, workspaceBookmark: server.workspaceBookmark, relativePath: entryPath)
        }
        .alert("操作失败", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var jarTypes: [UTType] {
        var types: [UTType] = []
        if let jar = UTType(filenameExtension: "jar") { types.append(jar) }
        types.append(.data)
        return types
    }

    private var scriptTypes: [UTType] {
        var types: [UTType] = []
        if let sh = UTType(filenameExtension: "sh") { types.append(sh) }
        if let command = UTType(filenameExtension: "command") { types.append(command) }
        types.append(contentsOf: [.unixExecutable, .plainText, .text, .data])
        var seen: Set<String> = []
        return types.filter { seen.insert($0.identifier).inserted }
    }

    private func chooseEntryFile() {
        guard entryKind != .mainClass else { return }
        guard let workspaceURL else {
            presentError("未找到工作目录。请先选择工作目录并保存。")
            return
        }
        let types = (entryKind == .jar) ? jarTypes : scriptTypes
        let prompt = entryKind == .jar ? "选择 Jar 文件" : "选择启动脚本"
        FileDialogs.openFile(allowedTypes: types, prompt: prompt, initialDirectory: workspaceURL) { url in
            guard let url else { return }
            guard let relative = relativePathIfInsideWorkspace(workspaceURL: workspaceURL, fileURL: url) else {
                presentError("入口文件必须位于工作目录内（沙盒限制）。")
                return
            }
            entryPath = relative
        }
    }

    private func relativePathIfInsideWorkspace(workspaceURL: URL, fileURL: URL) -> String? {
        let workspaceCandidates = [
            workspaceURL.standardizedFileURL,
            workspaceURL.resolvingSymlinksInPath().standardizedFileURL
        ]
        let fileCandidates = [
            fileURL.standardizedFileURL,
            fileURL.resolvingSymlinksInPath().standardizedFileURL
        ]

        for base in workspaceCandidates {
            let basePrefix = base.path.hasSuffix("/") ? base.path : "\(base.path)/"
            for file in fileCandidates {
                if file.path.hasPrefix(basePrefix) {
                    return String(file.path.dropFirst(basePrefix.count))
                }
            }
        }
        return nil
    }

    private func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    ServersPage(themeBinder: ThemeBinder())
        .environmentObject(AppStore())
}
