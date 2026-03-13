import Foundation
import CoreLocation

/// A simple GPX streaming writer. Not thread-safe; call from a single context (e.g., an actor).
final class GPXWriter: @unchecked Sendable {
    private var fileHandle: FileHandle?
    private(set) var fileURL: URL?
    private let fileManager = FileManager.default

    /// The calendar-day component of the currently open file (used for daily rotation).
    private(set) var currentFileDate: DateComponents?

    // MARK: - iCloud container (cached)

    private static var _cachedContainerURL: URL?

    /// iCloud container가 사용 가능한지 여부
    static var isICloudAvailable: Bool { _cachedContainerURL != nil }

    /// 앱 시작 시 호출 — async/await로 백그라운드에서 iCloud container를 초기화한다.
    static func resolveICloudContainer() async -> URL? {
        if let cached = _cachedContainerURL { return cached }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let fm = FileManager.default
                let token = fm.ubiquityIdentityToken
                DiagLog.log("[iCloud] ubiquityIdentityToken: \(token != nil ? "present" : "nil")")

                guard token != nil else {
                    DiagLog.log("[iCloud] 사용자가 iCloud에 로그인하지 않았거나 iCloud Drive가 비활성화됨")
                    continuation.resume(returning: nil)
                    return
                }

                let id = AppConfig.iCloudContainerIdentifier
                DiagLog.log("[iCloud] Requesting container: \(id)")

                if let url = fm.url(forUbiquityContainerIdentifier: id) {
                    DiagLog.log("[iCloud] Container URL: \(url.path)")
                    let tracksDir = url.appendingPathComponent("Documents/Tracks", isDirectory: true)
                    do {
                        try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
                        DiagLog.log("[iCloud] Tracks directory ready: \(tracksDir.path)")
                    } catch {
                        DiagLog.log("[iCloud] Failed to create Tracks directory: \(error)")
                    }
                    _cachedContainerURL = url
                    continuation.resume(returning: url)
                } else {
                    DiagLog.log("[iCloud] url(forUbiquityContainerIdentifier:) returned nil for \(id)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    init() {}

    // MARK: - Session mode

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

    func startNewFileForDate(_ date: Date) throws {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        if let current = currentFileDate, current == comps, fileHandle != nil { return }
        try close()
        let tracksDir = try Self.tracksDirectory()
        let base = Self.dailyDateFormatter.string(from: date)
        let url = tracksDir.appendingPathComponent("\(base).gpx")

        if fileManager.fileExists(atPath: url.path) {
            try reopenExistingFile(at: url)
        } else {
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

    func append(location: CLLocation, heading: Double? = nil) throws {
        guard let handle = fileHandle else {
            throw NSError(domain: "GPXWriter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "File not open"])
        }
        let point = Self.gpxTrackPoint(for: location, heading: heading)
        try handle.write(contentsOf: Data(point.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
    }

    func flush() throws {
        try fileHandle?.synchronize()
    }

    func close() throws {
        guard let handle = fileHandle else { return }
        try handle.write(contentsOf: Data("  </trkseg>\n</trk>\n</gpx>\n".utf8))
        try handle.close()
        fileHandle = nil
        currentFileDate = nil
    }

    // MARK: - Private helpers

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

    private func reopenExistingFile(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        let closingTag = "  </trkseg>\n</trk>\n</gpx>\n"
        let closingTagBytes = closingTag.utf8.count

        let fileSize = try handle.seekToEnd()
        if fileSize >= closingTagBytes {
            try handle.seek(toOffset: fileSize - UInt64(closingTagBytes))
            let tailData = try handle.read(upToCount: closingTagBytes) ?? Data()
            if String(data: tailData, encoding: .utf8) == closingTag {
                try handle.truncate(atOffset: fileSize - UInt64(closingTagBytes))
                try handle.seekToEnd()
            } else {
                try handle.seekToEnd()
            }
        } else {
            try handle.seekToEnd()
        }

        try handle.write(contentsOf: Data("  </trkseg>\n  <trkseg>\n".utf8))

        self.fileHandle = handle
        self.fileURL = url
    }

    /// 캐시된 iCloud container URL을 사용하고, 없으면 로컬 폴백.
    static func tracksDirectory() throws -> URL {
        let fm = FileManager.default

        if let containerURL = _cachedContainerURL {
            let tracksDir = containerURL.appendingPathComponent("Documents/Tracks", isDirectory: true)
            try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
            return tracksDir
        }

        // 캐시가 없으면 동기 호출 시도 (초기화 전에 로깅 시작한 경우)
        if let containerURL = fm.url(forUbiquityContainerIdentifier: AppConfig.iCloudContainerIdentifier) {
            _cachedContainerURL = containerURL
            let tracksDir = containerURL.appendingPathComponent("Documents/Tracks", isDirectory: true)
            try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
            DiagLog.log("[iCloud] Container found (sync fallback): \(tracksDir.path)")
            return tracksDir
        }

        // Fallback: iCloud unavailable
        DiagLog.log("[iCloud] Container unavailable — falling back to local storage")
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let tracksDir = docs.appendingPathComponent("Tracks", isDirectory: true)
        try fm.createDirectory(at: tracksDir, withIntermediateDirectories: true)
        return tracksDir
    }

    // MARK: - Existing file stats

    /// Parse point count and total distance from an existing GPX file.
    /// Returns (pointCount, totalDistanceMeters, lastCoordinate).
    static func statsFromFile(at url: URL) -> (points: Int, distance: Double, lastCoord: CLLocationCoordinate2D?) {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else {
            return (0, 0, nil)
        }

        // Extract all lat/lon pairs from <trkpt lat="..." lon="...">
        var coords: [(lat: Double, lon: Double)] = []
        let pattern = #"<trkpt\s+lat="([^"]+)"\s+lon="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (0, 0, nil)
        }
        let range = NSRange(content.startIndex..., in: content)
        for match in regex.matches(in: content, range: range) {
            if let latRange = Range(match.range(at: 1), in: content),
               let lonRange = Range(match.range(at: 2), in: content),
               let lat = Double(content[latRange]),
               let lon = Double(content[lonRange]) {
                coords.append((lat, lon))
            }
        }

        guard !coords.isEmpty else { return (0, 0, nil) }

        // Compute total distance
        var totalDist: Double = 0
        for i in 1..<coords.count {
            let prev = CLLocation(latitude: coords[i - 1].lat, longitude: coords[i - 1].lon)
            let curr = CLLocation(latitude: coords[i].lat, longitude: coords[i].lon)
            totalDist += curr.distance(from: prev)
        }

        let last = coords.last!
        return (coords.count, totalDist, CLLocationCoordinate2D(latitude: last.lat, longitude: last.lon))
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

// MARK: - GPX formatting

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

        if location.horizontalAccuracy >= 0 {
            xml += "    <hdop>\(String(format: "%.1f", location.horizontalAccuracy))</hdop>\n"
        }
        if location.verticalAccuracy >= 0 {
            xml += "    <vdop>\(String(format: "%.1f", location.verticalAccuracy))</vdop>\n"
        }

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
        if let h = heading, h >= 0 {
            extLines.append("        <gpxleecoder:trueHeading>\(String(format: "%.1f", h))</gpxleecoder:trueHeading>")
        }
        extLines.append("        <gpxleecoder:ellipsoidalAltitude>\(String(format: "%.1f", location.ellipsoidalAltitude))</gpxleecoder:ellipsoidalAltitude>")
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
