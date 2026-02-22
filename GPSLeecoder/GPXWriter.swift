import Foundation
import CoreLocation

/// A simple GPX streaming writer. Not thread-safe; call from a single context (e.g., an actor).
final class GPXWriter: @unchecked Sendable {
    private var fileHandle: FileHandle?
    private(set) var fileURL: URL?
    private let fileManager = FileManager.default

    /// The calendar-day component of the currently open file (used for daily rotation).
    private(set) var currentFileDate: DateComponents?

    init() {}

    // MARK: - Session mode

    /// Creates a new GPX file under the iCloud ubiquity container and writes the header and opening tags.
    /// - Parameter suggestedName: Optional suggested base name (without extension). If nil, a timestamped name is used.
    func startNewFile(suggestedName: String? = nil) throws {
        let tracksDir = try Self.tracksDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? suggestedName! : formatter.string(from: Date())
        let url = tracksDir.appendingPathComponent("\(base).gpx")
        try openFile(at: url, baseName: base, in: tracksDir)
        currentFileDate = nil
    }

    // MARK: - Daily mode

    /// Opens (or keeps open) a GPX file named after the given date, e.g. `2026-02-22.gpx`.
    func startNewFileForDate(_ date: Date) throws {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        // If the file for this date is already open, do nothing.
        if let current = currentFileDate, current == comps, fileHandle != nil { return }
        // Close any previously open file first.
        try close()
        let tracksDir = try Self.tracksDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let base = formatter.string(from: date)
        let url = tracksDir.appendingPathComponent("\(base).gpx")
        try openFile(at: url, baseName: base, in: tracksDir)
        currentFileDate = comps
    }

    // MARK: - Writing

    /// Appends a single track point to the open GPX file.
    func append(location: CLLocation) throws {
        guard let handle = fileHandle else { throw NSError(domain: "GPXWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "File not open"]) }
        let point = Self.gpxTrackPoint(for: location)
        try handle.write(contentsOf: Data(point.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
    }

    /// Flushes the file data to disk. Coordinator-friendly flush can be added later if needed.
    func flush() throws {
        try fileHandle?.synchronize()
    }

    /// Closes the GPX file by writing closing tags and closing the handle.
    func close() throws {
        guard let handle = fileHandle else { return }
        try handle.write(contentsOf: Data("  </trkseg>\n</trk>\n</gpx>\n".utf8))
        try handle.close()
        fileHandle = nil
        currentFileDate = nil
    }

    // MARK: - Private helpers

    private func openFile(at url: URL, baseName: String, in tracksDir: URL) throws {
        // If exists, add suffix
        var finalURL = url
        var suffix = 1
        while fileManager.fileExists(atPath: finalURL.path) {
            finalURL = tracksDir.appendingPathComponent("\(baseName)-\(suffix).gpx")
            suffix += 1
        }

        fileManager.createFile(atPath: finalURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: finalURL)
        self.fileHandle = handle
        self.fileURL = finalURL

        let header = Self.gpxHeader()
        try handle.write(contentsOf: Data(header.utf8))
        try handle.write(contentsOf: Data("\n<trk>\n  <name>Track</name>\n  <trkseg>\n".utf8))
    }

    static func tracksDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let tracksDir = docs.appendingPathComponent("Tracks", isDirectory: true)
        try FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        return tracksDir
    }
}

private extension GPXWriter {
    static func gpxHeader() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="GPSLogger" xmlns="http://www.topografix.com/GPX/1/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gpxTrackPoint(for location: CLLocation) -> String {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let ele = location.verticalAccuracy >= 0 ? location.altitude : 0
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = iso.string(from: location.timestamp)
        return """
          <trkpt lat="\(lat)" lon="\(lon)">
            <ele>\(ele)</ele>
            <time>\(time)</time>
          </trkpt>
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
