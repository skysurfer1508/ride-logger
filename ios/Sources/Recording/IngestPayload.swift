import Foundation

/// The body of POST /api/ingest: Overland's GeoJSON batch, which the server already understands (app/models.py, app/processing.py).
/// The wire format is locked to Tests/Fixtures/ingest_batch.json, which the server's own tests ingest too (tests/test_ingest_app_batch.py).
enum IngestPayload {
    static let mode = "motorcycle"

    /// The end-of-ride summary. It goes last in the batch: the server closes the ride when it reaches it.
    struct Marker: Equatable {
        var end: Date
        var durationS: Double
        var distanceM: Double
        var latitude: Double
        var longitude: Double
    }

    static func feature(for sample: LocationSample, deviceId: String, tripId: String) -> [String: Any] {
        var properties: [String: Any] = [
            "timestamp": WireTime.string(sample.timestamp),
            "speed": sample.speed,
            "horizontal_accuracy": sample.horizontalAccuracy,
            "vertical_accuracy": sample.verticalAccuracy,
            "device_id": deviceId,
            "trip_id": tripId,
        ]
        if sample.verticalAccuracy >= 0 { properties["altitude"] = sample.altitude }      // an invalid altitude would only add noise to the climb
        if sample.batteryLevel >= 0 { properties["battery_level"] = sample.batteryLevel }
        if sample.speedAccuracy >= 0 { properties["speed_accuracy"] = sample.speedAccuracy }          // kept in the server's raw_properties
        if sample.course >= 0 {                                                                          // the server's lean-angle estimate uses it
            properties["course"] = sample.course
            if sample.courseAccuracy >= 0 { properties["course_accuracy"] = sample.courseAccuracy }
        }
        return [
            "type": "Feature",
            "geometry": ["type": "Point", "coordinates": [sample.longitude, sample.latitude]],      // GeoJSON order: longitude first
            "properties": properties,
        ]
    }

    static func markerFeature(_ marker: Marker, deviceId: String, tripId: String) -> [String: Any] {
        let end = WireTime.string(marker.end)
        return [
            "type": "Feature",
            "geometry": ["type": "Point", "coordinates": [marker.longitude, marker.latitude]],
            "properties": [
                "type": "trip",
                "timestamp": end,
                "mode": mode,
                "start": tripId,             // the server matches this against the points' trip_id
                "end": end,
                "duration": marker.durationS,
                "distance": (marker.distanceM * 10).rounded() / 10,
                "stopped_automatically": false,
                "device_id": deviceId,
            ] as [String: Any],
        ]
    }

    /// Samples in order, then (when the ride is over) the marker.
    static func body(samples: [LocationSample], trip: TripRecord, marker: Marker?) throws -> Data {
        var locations = samples
            .filter { $0.latitude.isFinite && $0.longitude.isFinite && $0.speed.isFinite && $0.horizontalAccuracy.isFinite }
            .map { feature(for: $0, deviceId: trip.deviceId, tripId: trip.tripId) }
        if let marker {
            locations.append(markerFeature(marker, deviceId: trip.deviceId, tripId: trip.tripId))
        }
        return try JSONSerialization.data(withJSONObject: ["locations": locations], options: [.sortedKeys])
    }
}
