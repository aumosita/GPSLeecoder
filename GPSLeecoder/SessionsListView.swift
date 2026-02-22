import SwiftUI

struct SessionsListView: View {
    @State private var files: [URL] = []
    @AppStorage("exportedFiles") private var exportedFilesData: Data = Data()

    private var exportedFileNames: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: exportedFilesData)) ?? []
    }

    private func markAsExported(_ url: URL) {
        var names = exportedFileNames
        names.insert(url.lastPathComponent)
        if let data = try? JSONEncoder().encode(names) {
            exportedFilesData = data
        }
    }

    private func isExported(_ url: URL) -> Bool {
        exportedFileNames.contains(url.lastPathComponent)
    }

    var body: some View {
        List(files, id: \._id) { url in
            HStack {
                VStack(alignment: .leading) {
                    HStack(spacing: 6) {
                        Text(url.lastPathComponent)
                            .font(.headline)
                        if isExported(url) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                                .accessibilityLabel(String(localized: "accessibility_exported"))
                        }
                    }
                    Text(formattedDate(from: url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded {
                    markAsExported(url)
                })
            }
        }
        .navigationTitle(String(localized: "nav_title_history"))
        .onAppear(perform: loadFiles)
        .refreshable { loadFiles() }
    }

    private func loadFiles() {
        let fm = FileManager.default
        do {
            let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let dir = docs.appendingPathComponent("Tracks", isDirectory: true)
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            let sorted = items.filter { $0.pathExtension.lowercased() == "gpx" }
                .sorted(by: { (a, b) in
                    (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast >
                    (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                })
            files = sorted
        } catch {
            files = []
        }
    }

    private func formattedDate(from url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let date = values?.contentModificationDate
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return date.map { df.string(from: $0) } ?? ""
    }
}

private extension URL {
    var _id: String { absoluteString }
}

#Preview {
    NavigationStack { SessionsListView() }
}
