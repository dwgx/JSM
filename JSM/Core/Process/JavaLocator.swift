import Foundation
import Darwin

public nonisolated enum JavaLocator {
    public static func findJavaExecutableFast() -> String? {
        if let home = javaHomeFromLaunchCtl()
            ?? jdkHomeFromLaunchCtl()
            ?? javaHomeFromShell()
            ?? jdkHomeFromShell()
            ?? javaHomeFromInteractiveShell()
            ?? jdkHomeFromInteractiveShell()
            ?? javaHomeFromSystem() {
            let expanded = expandTilde(home)
            let candidate = (expanded as NSString).appendingPathComponent("bin/java")
            if candidate == "/usr/bin/java", !hasSystemJavaQuick() { return nil }
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }

        for cmd in [
            "command -v java",
            "which java"
        ] {
            if let out = normalizePathOutput(runCommand("/bin/zsh", args: ["-lc", cmd])) {
                let expanded = expandTilde(out)
                if expanded == "/usr/bin/java", !hasSystemJavaQuick() { continue }
                return expanded
            }
        }

        if hasSystemJavaQuick() {
            let stub = "/usr/bin/java"
            if FileManager.default.isExecutableFile(atPath: stub) { return stub }
        }

        return nil
    }

    public static func findJavaExecutable() -> String? {
        for candidate in collectCandidates() {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Best-effort guess for the `java` binary using the user's shell environment.
    /// This may return a path that is not accessible yet under App Sandbox until the user grants permission.
    public static func guessJavaExecutableFromShell() -> String? {
        // Prefer JAVA_HOME/JDK_HOME because they point to the JDK root.
        if let home = javaHomeFromLaunchCtl()
            ?? jdkHomeFromLaunchCtl()
            ?? javaHomeFromShell()
            ?? jdkHomeFromShell()
            ?? javaHomeFromInteractiveShell()
            ?? jdkHomeFromInteractiveShell() {
            let expanded = expandTilde(home)
            let candidate = (expanded as NSString).appendingPathComponent("bin/java")
            if candidate == "/usr/bin/java", !hasSystemJava() { return nil }
            return candidate
        }

        // Fall back to shell PATH resolution (SDKMAN/ASDF often live here).
        for cmd in [
            "command -v java",
            "which java"
        ] {
            if let out = normalizePathOutput(runCommand("/bin/zsh", args: ["-lc", cmd])) {
                let expanded = expandTilde(out)
                if expanded == "/usr/bin/java", !hasSystemJava() { continue }
                return expanded
            }
            if let out = normalizePathOutput(runCommand("/bin/zsh", args: ["-ic", cmd])) {
                let expanded = expandTilde(out)
                if expanded == "/usr/bin/java", !hasSystemJava() { continue }
                return expanded
            }
        }

        // Final guess: SDKMAN default location.
        if let home = userHomeDirectory() {
            let sdkman = (home as NSString).appendingPathComponent(".sdkman/candidates/java/current/bin/java")
            if sdkman == "/usr/bin/java", !hasSystemJava() { return nil }
            return sdkman
        }
        return nil
    }

    public static func hasSystemJava() -> Bool {
        javaHomeFromSystem() != nil || !javaHomesFromSystem().isEmpty
    }

    public static func hasSystemJavaQuick() -> Bool {
        javaHomeFromSystem() != nil
    }

    public static func javaHomeFromSystem() -> String? {
        normalizePathOutput(runCommand("/usr/libexec/java_home", args: []))
    }

    private static func collectCandidates() -> [String] {
        var candidates: [String] = []
        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let expanded = expandTilde(path)
            if !candidates.contains(expanded) { candidates.append(expanded) }
        }
        func addJavaHome(_ home: String?) {
            guard let home, !home.isEmpty else { return }
            let expanded = expandTilde(home)
            let java = (expanded as NSString).appendingPathComponent("bin/java")
            add(java)
        }

        // 1) Environment variables (best signal)
        addJavaHome(ProcessInfo.processInfo.environment["JAVA_HOME"])
        addJavaHome(ProcessInfo.processInfo.environment["JDK_HOME"])
        addJavaHome(javaHomeFromLaunchCtl())
        addJavaHome(jdkHomeFromLaunchCtl())
        addJavaHome(javaHomeFromShell())
        addJavaHome(jdkHomeFromShell())
        addJavaHome(javaHomeFromInteractiveShell())
        addJavaHome(jdkHomeFromInteractiveShell())

        // 2) java_home (system registry)
        let systemHome = javaHomeFromSystem()
        let systemHomes = javaHomesFromSystem()
        let hasSystemJava = systemHome != nil || !systemHomes.isEmpty
        addJavaHome(systemHome)
        for home in systemHomes {
            addJavaHome(home)
        }

        // 3) SDKMAN
        add(sdkmanJavaExecutable())

        // 4) ASDF / jenv / jabba
        add(expandTilde("~/.asdf/shims/java"))
        add(expandTilde("~/.jenv/shims/java"))
        add(expandTilde("~/.jabba/jdk/current/bin/java"))
        for root in [
            "~/.asdf/installs/java",
            "~/.jenv/versions",
            "~/.jabba/jdk"
        ] {
            for java in scanJDKBins(at: expandTilde(root)) {
                add(java)
            }
        }

        // 5) Homebrew / MacPorts / standard installs
        add("/opt/homebrew/bin/java")
        add("/usr/local/bin/java")
        add("/opt/local/bin/java")

        for root in [
            "/Library/Java/JavaVirtualMachines",
            "/System/Library/Java/JavaVirtualMachines",
            "\(userHomeDirectory() ?? NSHomeDirectory())/Library/Java/JavaVirtualMachines"
        ] {
            for java in scanJDKBundles(at: root) {
                add(java)
            }
        }

        for root in [
            "/opt/homebrew/Cellar",
            "/usr/local/Cellar"
        ] {
            for java in scanHomebrewCellar(at: root) {
                add(java)
            }
        }

        for root in [
            "/opt/homebrew/opt",
            "/usr/local/opt"
        ] {
            for java in scanHomebrewOpt(at: root) {
                add(java)
            }
        }

        for root in [
            "/opt/local/libexec",
            "/Library/Java/JavaVirtualMachines"
        ] {
            for java in scanJDKBins(at: root) {
                add(java)
            }
        }

        // 6) PATH lookup (last, because GUI apps may not inherit shell PATH)
        if let which = runCommand("/usr/bin/which", args: ["java"]) {
            if which != "/usr/bin/java" || hasSystemJava {
                add(which)
            }
        }

        // 7) Final fallback (only when system Java is present)
        if hasSystemJava {
            add("/usr/bin/java")
        }

        return candidates
    }

    private static func sdkmanJavaExecutable() -> String? {
        guard let home = userHomeDirectory() else { return nil }
        let current = (home as NSString).appendingPathComponent(".sdkman/candidates/java/current/bin/java")
        if FileManager.default.isExecutableFile(atPath: current) {
            return current
        }
        let candidatesRoot = (home as NSString).appendingPathComponent(".sdkman/candidates/java")
        return scanJDKBins(at: candidatesRoot).first
    }

    private static func scanJDKBundles(at root: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: rootURL,
                                                                          includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [String] = []
        for jdk in contents {
            let java = jdk.appendingPathComponent("Contents/Home/bin/java").path
            if FileManager.default.isExecutableFile(atPath: java) {
                results.append(java)
            }
        }
        return results
    }

    private static func scanJDKBins(at root: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: rootURL,
                                                                          includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [String] = []
        for jdk in contents {
            let java = jdk.appendingPathComponent("bin/java").path
            if FileManager.default.isExecutableFile(atPath: java) {
                results.append(java)
            }
        }
        return results
    }

    private static func scanHomebrewOpt(at root: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: rootURL,
                                                                          includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [String] = []
        for formula in contents {
            if formula.lastPathComponent.hasPrefix("openjdk") {
                let java = formula.appendingPathComponent("bin/java").path
                if FileManager.default.isExecutableFile(atPath: java) {
                    results.append(java)
                }
            }
        }
        return results
    }

    private static func scanHomebrewCellar(at root: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: rootURL,
                                                                          includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [String] = []
        for formula in contents where formula.lastPathComponent.hasPrefix("openjdk") {
            guard let versions = try? FileManager.default.contentsOfDirectory(at: formula,
                                                                              includingPropertiesForKeys: nil,
                                                                              options: [.skipsHiddenFiles]) else {
                continue
            }
            for version in versions {
                let java = version
                    .appendingPathComponent("libexec/openjdk.jdk/Contents/Home/bin/java")
                    .path
                if FileManager.default.isExecutableFile(atPath: java) {
                    results.append(java)
                }
            }
        }
        return results
    }

    private static func javaHomesFromSystem() -> [String] {
        guard let output = runCommand("/usr/libexec/java_home", args: ["-V"]) else { return [] }
        let lines = output.split(separator: "\n").map { String($0) }
        var homes: [String] = []
        for line in lines {
            if let range = line.range(of: " /", options: .backwards) {
                let path = String(line[range.upperBound...])
                if path.hasPrefix("/") {
                    homes.append(path)
                }
            }
        }
        return homes
    }

    private static func javaHomeFromLaunchCtl() -> String? {
        normalizePathOutput(runCommand("/bin/launchctl", args: ["getenv", "JAVA_HOME"]))
    }

    private static func jdkHomeFromLaunchCtl() -> String? {
        normalizePathOutput(runCommand("/bin/launchctl", args: ["getenv", "JDK_HOME"]))
    }

    private static func javaHomeFromShell() -> String? {
        normalizePathOutput(runCommand("/bin/zsh", args: ["-lc", "printenv JAVA_HOME"]))
    }

    private static func jdkHomeFromShell() -> String? {
        normalizePathOutput(runCommand("/bin/zsh", args: ["-lc", "printenv JDK_HOME"]))
    }

    private static func javaHomeFromInteractiveShell() -> String? {
        normalizePathOutput(runCommand("/bin/zsh", args: ["-ic", "printenv JAVA_HOME"]))
    }

    private static func jdkHomeFromInteractiveShell() -> String? {
        normalizePathOutput(runCommand("/bin/zsh", args: ["-ic", "printenv JDK_HOME"]))
    }

    private static func normalizePathOutput(_ output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        let lines = output.split(separator: "\n").map { String($0) }
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                return trimmed
            }
        }
        return nil
    }

    public static func suggestedJavaHomeDirectories() -> [URL] {
        var results: [URL] = []
        func addDir(_ path: String?, allowMissing: Bool = false) {
            guard let path, !path.isEmpty else { return }
            let expanded = expandTilde(path)
            var isDir: ObjCBool = false
            if allowMissing || (FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue) {
                let url = URL(fileURLWithPath: expanded, isDirectory: true)
                if !results.contains(where: { $0.path == url.path }) {
                    results.append(url)
                }
            }
        }

        // Prefer SDKMAN if available
        if let home = userHomeDirectory() {
            addDir("\(home)/.sdkman/candidates/java", allowMissing: true)
            addDir("\(home)/.sdkman/candidates/java/current", allowMissing: true)
        }

        addDir(javaHomeFromSystem())
        javaHomesFromSystem().forEach { addDir($0) }
        addDir(javaHomeFromLaunchCtl())
        addDir(jdkHomeFromLaunchCtl())
        addDir(javaHomeFromShell())
        addDir(jdkHomeFromShell())
        addDir(javaHomeFromInteractiveShell())
        addDir(jdkHomeFromInteractiveShell())

        addDir("/Library/Java/JavaVirtualMachines")
        if let home = userHomeDirectory() {
            addDir("\(home)/Library/Java/JavaVirtualMachines")
        }
        addDir("/opt/homebrew/opt")
        addDir("/usr/local/opt")
        addDir("/opt/local/libexec")

        return results
    }

    public static func likelyJavaHomeDirectories() -> [URL] {
        var results: [URL] = []
        func add(_ path: String?) {
            guard let path, !path.isEmpty else { return }
            let expanded = expandTilde(path)
            let rawURL = URL(fileURLWithPath: expanded)
            let isJavaExecutable = rawURL.lastPathComponent == "java"
                && rawURL.deletingLastPathComponent().lastPathComponent == "bin"
            let isDirectoryHint = !isJavaExecutable
            let url = URL(fileURLWithPath: expanded, isDirectory: isDirectoryHint)
            if !results.contains(where: { $0.path == url.path }) {
                results.append(url)
            }
        }

        if let home = userHomeDirectory() {
            add("\(home)/.sdkman/candidates/java")
            add("\(home)/.sdkman/candidates/java/current")
            add("\(home)/.sdkman/candidates/java/current/bin/java")
            add("\(home)/.asdf/installs/java")
            add("\(home)/.jenv/versions")
            add("\(home)/.jabba/jdk")
            add("\(home)/Library/Java/JavaVirtualMachines")
        }

        add("/Library/Java/JavaVirtualMachines")
        add("/System/Library/Java/JavaVirtualMachines")
        add("/opt/homebrew/opt")
        add("/usr/local/opt")
        add("/opt/local/libexec")

        return results
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let suffix = path.dropFirst()
        if let home = userHomeDirectory() {
            return "\(home)\(suffix)"
        }
        return (path as NSString).expandingTildeInPath
    }

    private static func userHomeDirectory() -> String? {
        let uid = getuid()
        if let pw = getpwuid(uid) {
            let dir = String(cString: pw.pointee.pw_dir)
            if !dir.isEmpty { return dir }
        }
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return home
        }
        return nil
    }

    private static func runCommand(_ launchPath: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            return nil
        }
        return output
    }
}
