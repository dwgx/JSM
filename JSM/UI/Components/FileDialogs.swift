import AppKit
import UniformTypeIdentifiers

enum FileDialogs {
    static func openFile(allowedTypes: [UTType],
                         prompt: String? = nil,
                         initialDirectory: URL? = nil,
                         showsHiddenFiles: Bool = false,
                         completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedTypes
        panel.showsHiddenFiles = showsHiddenFiles
        if let prompt { panel.prompt = prompt }
        if let initialDirectory { panel.directoryURL = initialDirectory }
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    static func openFolder(prompt: String? = nil,
                           initialDirectory: URL? = nil,
                           preselectURL: URL? = nil,
                           showsHiddenFiles: Bool = false,
                           completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = showsHiddenFiles
        panel.allowedContentTypes = [.folder]
        if let prompt { panel.prompt = prompt }
        if let preselectURL {
            panel.directoryURL = preselectURL.deletingLastPathComponent()
            panel.nameFieldStringValue = preselectURL.lastPathComponent
        } else if let initialDirectory {
            panel.directoryURL = initialDirectory
        }
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    static func openJavaLocation(prompt: String? = nil,
                                 initialDirectory: URL? = nil,
                                 preselectURL: URL? = nil,
                                 showsHiddenFiles: Bool = false,
                                 completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = showsHiddenFiles
        panel.allowedContentTypes = [.folder, .unixExecutable, .data]
        if let prompt {
            panel.message = prompt
            panel.prompt = "选择"
        }
        if let preselectURL {
            panel.directoryURL = preselectURL.deletingLastPathComponent()
            panel.nameFieldStringValue = preselectURL.lastPathComponent
        } else if let initialDirectory {
            panel.directoryURL = initialDirectory
        }
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }
}
