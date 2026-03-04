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
        let base: String
        if let name = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            base = name
        } else {
            base = Self.sessionDateFormatter.string(from: Date())
        }
        let url = tracksDir.appendingPathComponent("\(base).gpx")
        try openNewFile(at: url, baseName: base, in: tracksDir)
        currentFileDate = nil
    }

    // MARK: - Daily mode

    /// Opens (or resumes) a GPX file named after the given date, e.g. `2026-02-22.gpx`.
    /// If the file already exists (from a previous session), it reopens and appends a new track segment.
    func startNewFileForDate(_ date: Date) throws {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        // If the file for this date is already open, do nothing.
        if let current = currentFileDate, current == comps, fileHandle != nil { return }
        // Close any previously open file first.
        try close()
        let tracksDir = try Self.tracksDirectory()
        let base = Self.dailyDateFormatter.string(from: date)
        let url = tracksDir.appendingPathComponent("\(base).gpx")

        if fileManager.fileExists(atPath: url.path) {
            // Reopen existing daily file — append a new track segment
            try reopenExistingFile(at: url)
        } else {
            // Create a brand-new file (no -1 suffix for daily mode)
            fileManager.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            self.fileHandle = handle
            self.fileURL = url
            try handle.write(contentsOf: Data(Self.gpxHeader().utf8))
            try handle.write(contentsOf: Data("\n<trk>\n  <name>Track</name>\n  <trkseg>\n".utf8))
        }
        currentFileDate = comps
    }

    // MARK: - Writing

    /// Appends a single track point to the open GPX file.
    func append(location: CLLocation, heading: Double? = nil) throws {
        guard let handle = fileHandle else { throw NSError(domain: "GPXWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "File not open"]) }
        let point = Self.gpxTrackPoint(for: location, heading: heading)
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

    /// Attempts to recover a file handle by reopening the file at the end.
    /// Used when the handle becomes invalid during recording.
    func recoverFileHandle(at url: URL) throws {
        // Close existing handle if any
        try? fileHandle?.close()
        fileHandle = nil

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "GPXWriter", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "File does not exist: \(url.lastPathComponent)"])
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        self.fileHandle = handle
        self.fileURL = url
        print("[GPXWriter] File handle recovered for \(url.lastPathComponent)")
    }

    // MARK: - Private helpers

    /// Opens a new file (session mode). Adds a numeric suffix if the file already exists.
    private func openNewFile(at url: URL, baseName: String, in tracksDir: URL) throws {
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

    /// Reopens an existing daily GPX file, strips closing tags, and starts a new track segment.
    private func reopenExistingFile(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        let closingTag = "  </trkseg>\n</trk>\n</gpx>\n"
        let closingTagBytes = closingTag.utf8.count

        // Seek to end and check if file ends with the closing tags
        let fileSize = try handle.seekToEnd()
        if fileSize >= closingTagBytes {
            try handle.seek(toOffset: fileSize - UInt64(closingTagBytes))
            let tailData = try handle.read(upToCount: closingTagBytes) ?? Data()
            if String(data: tailData, encoding: .utf8) == closingTag {
                // Truncate to remove closing tags
                try handle.truncate(atOffset: fileSize - UInt64(closingTagBytes))
                try handle.seekToEnd()
            } else {
                // Closing tags not found — just seek to end
                try handle.seekToEnd()
            }
        } else {
            try handle.seekToEnd()
        }

        // Start a new track segment
        try handle.write(contentsOf: Data("  </trkseg>\n  <trkseg>\n".utf8))

        self.fileHandle = handle
        self.fileURL = url
    }

    static func tracksDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let tracksDir = docs.appendingPathComponent("Tracks", isDirectory: true)
        try FileManager.default.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        return tracksDir
    }

    // MARK: - Static cached formatters

    private static let sessionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    private static let dailyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private extension GPXWriter {
    static func gpxHeader() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="June GPS Recorder for Photographers"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxleecoder="https://github.com/aumosita/GPSLeecoder"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
        """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gpxTrackPoint(for location: CLLocation, heading: Double? = nil) -> String {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let ele = location.verticalAccuracy >= 0 ? location.altitude : 0
        let time = isoFormatter.string(from: location.timestamp)

        var xml = "  <trkpt lat=\"\(lat)\" lon=\"\(lon)\">\n"
        xml += "    <ele>\(String(format: "%.1f", ele))</ele>\n"
        xml += "    <time>\(time)</time>\n"

        // Horizontal accuracy
        if location.horizontalAccuracy >= 0 {
            xml += "    <hdop>\(String(format: "%.1f", location.horizontalAccuracy))</hdop>\n"
        }
        // Vertical accuracy
        if location.verticalAccuracy >= 0 {
            xml += "    <vdop>\(String(format: "%.1f", location.verticalAccuracy))</vdop>\n"
        }

        // Extensions: speed, course, accuracies, heading, ellipsoidalAltitude, source
        var extLines: [String] = []
        if location.speed >= 0 {
            extLines.append("        <gpxleecoder:speed>\(String(format: "%.2f", location.speed))</gpxleecoder:speed>")
        }
        if location.course >= 0 {
            extLines.append("        <gpxleecoder:course>\(String(format: "%.1f", location.course))</gpxleecoder:course>")
        }
        if location.speedAccuracy >= 0 {
            extLines.append("        <gpxleecoder:speedAccuracy>\(String(format: "%.2f", location.speedAccuracy))</gpxleecoder:speedAccuracy>")
        }
        if location.courseAccuracy >= 0 {
            extLines.append("        <gpxleecoder:courseAccuracy>\(String(format: "%.1f", location.courseAccuracy))</gpxleecoder:courseAccuracy>")
        }
        // True heading from compass
        if let h = heading, h >= 0 {
            extLines.append("        <gpxleecoder:trueHeading>\(String(format: "%.1f", h))</gpxleecoder:trueHeading>")
        }
        // Ellipsoidal altitude (WGS84)
        extLines.append("        <gpxleecoder:ellipsoidalAltitude>\(String(format: "%.1f", location.ellipsoidalAltitude))</gpxleecoder:ellipsoidalAltitude>")
        // Location source info
        if let source = location.sourceInformation {
            let isSimulated = source.isSimulatedBySoftware
            let isProduced = source.isProducedByAccessory
            extLines.append("        <gpxleecoder:source simulated=\"\(isSimulated)\" accessory=\"\(isProduced)\"/>")
        }

        if !extLines.isEmpty {
            xml += "    <extensions>\n"
            xml += extLines.joined(separator: "\n") + "\n"
            xml += "    </extensions>\n"
        }

        xml += "  </trkpt>"
        return xml
    }
}
