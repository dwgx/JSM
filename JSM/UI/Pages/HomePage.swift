import SwiftUI
import UniformTypeIdentifiers

struct HomePage: View {
    @ObservedObject var themeBinder: ThemeBinder
    @EnvironmentObject private var appStore: AppStore
    @State private var showNewServer = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("JSM 控制台")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(themeBinder.color("text"))
                    Text("Java 服务管理与主题引擎")
                        .font(.subheadline)
                        .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.7)))
                }

                let running = appStore.runtimes.values.filter { $0.state == .running }.count
                let total = appStore.servers.count
                let snapshots = appStore.runtimes.values.compactMap(\.metricsSnapshot)
                let cpuAvg = snapshots.isEmpty ? 0 : snapshots.reduce(0) { $0 + $1.cpuPercent } / Double(snapshots.count)
                let totalMemoryBytes = snapshots.reduce(UInt64(0)) { partial, value in
                    partial + value.memoryBytes
                }
                let totalThreads = snapshots.reduce(0) { partial, value in
                    partial + value.threadCount
                }
                let totalFD = snapshots.reduce(0) { partial, value in
                    partial + value.fileDescriptorCount
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    StatCard(themeBinder: themeBinder, title: "运行中", value: "\(running)", subtitle: running == 0 ? "暂无活动" : "正在运行")
                    StatCard(themeBinder: themeBinder, title: "总服务", value: "\(total)", subtitle: total == 0 ? "尚未导入" : "已导入")
                    StatCard(themeBinder: themeBinder, title: "CPU", value: String(format: "%.0f%%", cpuAvg), subtitle: "实时采样")
                    StatCard(themeBinder: themeBinder, title: "RAM", value: formatBytes(totalMemoryBytes), subtitle: "总内存占用")
                    StatCard(themeBinder: themeBinder, title: "线程", value: "\(totalThreads)", subtitle: "FD: \(totalFD)")
                }

                HStack(alignment: .top, spacing: 16) {
                    SectionCard(themeBinder: themeBinder, title: "快捷操作") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("导入服务器") { openImportFlow() }
                                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                            Button("新建服务器") { showNewServer = true }
                                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                            Button("关闭全部运行中") {
                                Task { @MainActor in
                                    for server in appStore.servers {
                                        let state = appStore.runtime(for: server.id)?.state ?? .stopped
                                        if state == .running || state == .starting {
                                            await appStore.stopServer(id: server.id)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                        }
                    }
                    SectionCard(themeBinder: themeBinder, title: "上次启动") {
                        let recent = appStore.lastStartedServerIDs.compactMap { appStore.server(for: $0) }
                        if recent.isEmpty {
                            Text("暂无记录")
                                .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                        } else {
                            HStack {
                                Button("启动全部") {
                                    Task { @MainActor in
                                        for server in recent {
                                            appStore.selectedServerID = server.id
                                            await appStore.startServer(id: server.id)
                                        }
                                    }
                                }
                                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                                Button("关闭全部") {
                                    Task { @MainActor in
                                        for server in recent {
                                            await appStore.stopServer(id: server.id)
                                        }
                                    }
                                }
                                .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                                Spacer()
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(recent) { server in
                                    let state = appStore.runtime(for: server.id)?.state ?? .stopped
                                    let canStart = state == .stopped || state == .crashed
                                    let canStop = state == .running || state == .starting
                                    let canRestart = state == .running
                                    let canForce = appStore.forceStopAvailableServerIDs.contains(server.id)
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(server.name)
                                                .foregroundStyle(themeBinder.color("text"))
                                            Text(localizedState(state))
                                                .font(.caption2)
                                                .foregroundStyle(themeBinder.color("textMuted", fallback: themeBinder.color("text").opacity(0.6)))
                                        }
                                        Spacer()
                                        Button("启动") {
                                            appStore.selectedServerID = server.id
                                            Task { await appStore.startServer(id: server.id) }
                                        }
                                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                                        .disabled(!canStart)
                                        Button("停止") {
                                            appStore.selectedServerID = server.id
                                            Task { await appStore.stopServer(id: server.id) }
                                        }
                                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                                        .disabled(!canStop)
                                        Button("重启") {
                                            appStore.selectedServerID = server.id
                                            Task { await appStore.restartServer(id: server.id) }
                                        }
                                        .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                                        .disabled(!canRestart)
                                        if canForce {
                                            Button("强制") {
                                                appStore.selectedServerID = server.id
                                                Task { await appStore.forceStopServer(id: server.id) }
                                            }
                                            .buttonStyle(ThemedButtonStyle(themeBinder: themeBinder))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                ConsoleView(themeBinder: themeBinder, serverID: appStore.selectedServerID)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(themeBinder.color("surface").ignoresSafeArea())
        .sheet(isPresented: $showNewServer) {
            NewServerSheet(themeBinder: themeBinder, isPresented: $showNewServer)
                .environmentObject(appStore)
        }
        .alert("操作失败", isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var yamlTypes: [UTType] {
        var types: [UTType] = []
        if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        types.append(.data)
        return types
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

    private func presentError(_ message: String) {
        alertMessage = message
        showAlert = true
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024.0 / 1024.0
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.0f MB", mb)
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
            return "已崩溃"
        }
    }
}

#Preview {
    HomePage(themeBinder: ThemeBinder())
        .environmentObject(AppStore())
}
