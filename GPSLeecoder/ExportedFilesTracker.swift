import Foundation

/// Shared utility for tracking which GPX files have been exported/shared.
enum ExportedFilesTracker {
    private static let key = "exportedFiles"

    static var exportedFileNames: Set<String> {
        let data = UserDefaults.standard.data(forKey: key) ?? Data()
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
    }

    static func markAsExported(_ url: URL) {
        var names = exportedFileNames
        names.insert(url.lastPathComponent)
        if let encoded = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    static func isExported(_ url: URL) -> Bool {
        exportedFileNames.contains(url.lastPathComponent)
    }
}
