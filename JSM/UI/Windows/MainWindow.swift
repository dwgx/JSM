import SwiftUI

private enum MainSection: String, CaseIterable, Identifiable {
    case home
    case servers
    case theme
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "概览"
        case .servers: return "服务器"
        case .theme: return "主题"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .servers: return "server.rack"
        case .theme: return "paintbrush.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject private var appStore: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var themeBinder = ThemeBinder()
    @State private var selection: MainSection = .home
    @State private var lastJavaAuthRequestID: UUID?
    @State private var showErrorAlert = false
    @State private var errorAlertMessage = ""
    private let themeEngine = ThemeEngine()

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
            .background(themeBinder.color("surface"))
        } detail: {
            Group {
                switch selection {
                case .home:
                    HomePage(themeBinder: themeBinder)
                        .environmentObject(appStore)
                case .servers:
                    ServersPage(themeBinder: themeBinder)
                        .environmentObject(appStore)
                case .theme:
                    ThemePage(themeBinder: themeBinder)
                        .environmentObject(appStore)
                case .settings:
                    SettingsPage(themeBinder: themeBinder)
                        .environmentObject(appStore)
                }
            }
        }
        .navigationTitle("JSM")
        .frame(minWidth: 980, minHeight: 680)
        .background(themeBinder.color("surface").ignoresSafeArea())
        .preferredColorScheme(preferredColorScheme)
        .onChange(of: appStore.javaAuthorizationRequest?.id) { _, _ in
            presentJavaAuthorizationIfNeeded()
        }
        .onChange(of: appStore.themeAppearance) { _, newValue in
            themeBinder.setAppearance(newValue)
        }
        .onChange(of: colorScheme) { _, newValue in
            themeBinder.setSystemColorScheme(newValue)
        }
        .onChange(of: appStore.lastErrorMessage) { _, newValue in
            if let message = newValue {
                errorAlertMessage = message
                showErrorAlert = true
                appStore.lastErrorMessage = nil
            }
        }
        .task {
            await loadDefaultTheme()
        }
        .onAppear {
            bootstrapJavaIfNeeded()
            presentJavaAuthorizationIfNeeded()
            themeBinder.setAppearance(appStore.themeAppearance)
            themeBinder.setSystemColorScheme(colorScheme)
        }
        .alert("操作失败", isPresented: $showErrorAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorAlertMessage)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appStore.themeAppearance {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    private func bootstrapJavaIfNeeded() {
        guard !appStore.hasUsableJavaConfiguration else { return }
        guard !appStore.servers.isEmpty else { return }
        guard appStore.javaAuthorizationRequest == nil else { return }
        guard appStore.javaExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { @MainActor in
            let detected = await appStore.autoDetectJava(mode: .fast)
            if !detected && appStore.javaAuthorizationRequest == nil {
                let suggested = JavaLocator.likelyJavaHomeDirectories().first
                appStore.requestJavaAuthorization(reason: "请授权 Java Home（包含 bin/java），否则无法启动服务。", suggestedHome: suggested)
            }
        }
    }

    private func presentJavaAuthorizationIfNeeded() {
        guard let request = appStore.javaAuthorizationRequest else { return }
        if lastJavaAuthRequestID == request.id { return }
        lastJavaAuthRequestID = request.id

        let suggested = request.suggestedHome ?? JavaLocator.likelyJavaHomeDirectories().first
        FileDialogs.openJavaLocation(prompt: request.reason,
                                     initialDirectory: suggested,
                                     preselectURL: suggested,
                                     showsHiddenFiles: true) { url in
            // Clear the request first so any follow-up actions (like auto-retry start) won't be blocked.
            appStore.clearJavaAuthorizationRequest(id: request.id)
            guard let url else {
                appStore.cancelPendingStart()
                return
            }
            if !appStore.applyJavaHomeSelection(url) {
                if appStore.lastErrorMessage == nil {
                    appStore.lastErrorMessage = "未在所选位置找到 Java（bin/java）。请重新选择 Java Home（例如 *.jdk/Contents/Home、~/.sdkman/candidates/java/<版本>，或直接选择 ~/.sdkman/candidates/java/current/bin/java）。"
                }
            }
        }
    }

    @MainActor
    private func loadDefaultTheme() async {
        let library = ThemeLibrary()
        if let theme = library.themes.first(where: { $0.name == "JSM Default" }) ?? library.themes.first {
            do {
                try themeEngine.loadTheme(at: theme.url)
                if let pkg = themeEngine.currentTheme {
                    themeBinder.apply(pkg)
                }
            } catch {
                // Fallback theme will be used.
            }
        }
    }
}

#Preview {
    MainWindow()
        .environmentObject(AppStore())
}
