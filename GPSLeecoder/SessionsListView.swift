import SwiftUI
import UIKit

struct SessionsListView: View {
    @State private var files: [URL] = []
    @State private var fileToShare: URL?
    @State private var fileToDelete: URL?
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

    private func deleteFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        files.removeAll { $0 == url }
    }

    var body: some View {
        List(files, id: \._id) { url in
            NavigationLink(destination: TrackOverlayView(fileURL: url)) {
                VStack(alignment: .leading) {
                    HStack(spacing: 6) {
                        Text(url.deletingPathExtension().lastPathComponent)
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
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    fileToDelete = url
                } label: {
                    Label(String(localized: "swipe_delete"), systemImage: "trash")
                }
                Button {
                    markAsExported(url)
                    fileToShare = url
                } label: {
                    Label(String(localized: "swipe_share"), systemImage: "square.and.arrow.up")
                }
                .tint(.blue)
            }
        }
        .navigationTitle(String(localized: "nav_title_history"))
        .onAppear(perform: loadFiles)
        .refreshable { loadFiles() }
        .sheet(isPresented: Binding(
            get: { fileToShare != nil },
            set: { if !$0 { fileToShare = nil } }
        )) {
            if let url = fileToShare {
                ShareSheetView(activityItems: [url])
            }
        }
        .alert(String(localized: "delete_confirm_title"), isPresented: Binding(
            get: { fileToDelete != nil },
            set: { if !$0 { fileToDelete = nil } }
        )) {
            Button(String(localized: "delete_confirm_cancel"), role: .cancel) {
                fileToDelete = nil
            }
            Button(String(localized: "delete_confirm_delete"), role: .destructive) {
                if let url = fileToDelete {
                    deleteFile(url)
                    fileToDelete = nil
                }
            }
        } message: {
            if let url = fileToDelete {
                Text("delete_confirm_message \(url.deletingPathExtension().lastPathComponent)")
            }
        }
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

// MARK: - UIActivityViewController wrapper
struct ShareSheetView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension URL {
    var _id: String { absoluteString }
}

#Preview {
    NavigationStack { SessionsListView() }
}
