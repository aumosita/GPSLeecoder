import Foundation
import CoreLocation

/// Parses a GPX file and extracts track point coordinates.
final class GPXParser: NSObject, XMLParserDelegate {
    private var coordinates: [CLLocationCoordinate2D] = []
    private var currentElement: String = ""
    private var currentLat: Double?
    private var currentLon: Double?

    /// Parses a GPX file at the given URL and returns an array of coordinates.
    func parse(fileURL: URL) -> [CLLocationCoordinate2D] {
        coordinates = []
        guard let parser = XMLParser(contentsOf: fileURL) else { return [] }
        parser.delegate = self
        parser.parse()
        return coordinates
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentElement = elementName
        if elementName == "trkpt" {
            if let latStr = attributes["lat"], let lonStr = attributes["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                currentLat = lat
                currentLon = lon
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "trkpt", let lat = currentLat, let lon = currentLon {
            coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            currentLat = nil
            currentLon = nil
        }
    }
}
