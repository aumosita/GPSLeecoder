import SwiftUI
import MapKit
import CoreLocation

struct TrackOverlayView: View {
    let fileURL: URL

    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition) {
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.blue, lineWidth: 3)
            }
            if let first = coordinates.first {
                Annotation(String(localized: "annotation_start"), coordinate: first) {
                    Image(systemName: "flag.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                }
            }
            if coordinates.count > 1, let last = coordinates.last {
                Annotation(String(localized: "annotation_end"), coordinate: last) {
                    Image(systemName: "flag.checkered.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title2)
                }
            }
        }
        .navigationTitle(fileURL.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let parser = GPXParser()
            coordinates = parser.parse(fileURL: fileURL)
            if coordinates.count > 1 {
                let region = regionForCoordinates(coordinates)
                cameraPosition = .region(region)
            }
        }
    }

    private func regionForCoordinates(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        var minLat = coords[0].latitude
        var maxLat = coords[0].latitude
        var minLon = coords[0].longitude
        var maxLon = coords[0].longitude

        for c in coords {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.3 + 0.002,
            longitudeDelta: (maxLon - minLon) * 1.3 + 0.002
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
