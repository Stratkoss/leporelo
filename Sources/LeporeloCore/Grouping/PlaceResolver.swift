import Foundation
import CoreLocation

public struct Place: Sendable, Codable, Equatable {
    public var name: String
    public var timeZoneIdentifier: String?

    public init(name: String, timeZoneIdentifier: String?) {
        self.name = name
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// Coordinates rounded to 2 decimal places (~1 km); the dedup and cache key for place lookups.
public struct PlaceKey: Sendable, Hashable {
    let lat: Int
    let lon: Int

    public init(_ point: GeoPoint) {
        lat = Int((point.latitude * 100).rounded())
        lon = Int((point.longitude * 100).rounded())
    }
}

public protocol PlaceResolver: Sendable {
    func place(for point: GeoPoint) async -> Place?
}

public final class InMemoryPlaceResolver: PlaceResolver {
    private let places: [PlaceKey: Place]

    public init(_ entries: [(GeoPoint, Place)]) {
        var map: [PlaceKey: Place] = [:]
        for (point, place) in entries { map[PlaceKey(point)] = place }
        places = map
    }

    public func place(for point: GeoPoint) async -> Place? {
        places[PlaceKey(point)]
    }
}

/// Reverse geocoding through CLGeocoder. Requests run strictly one after another, at least 1 s apart,
/// and successful lookups are cached per `PlaceKey`. Not covered by tests (needs network).
public actor GeocoderPlaceResolver: PlaceResolver {
    private var cache: [PlaceKey: Place] = [:]
    private var lastRequest: ContinuousClock.Instant?
    private var tail: Task<Void, Never>?
    private let spacing: Duration = .seconds(1)

    public init() {}

    public func place(for point: GeoPoint) async -> Place? {
        let key = PlaceKey(point)
        if let hit = cache[key] { return hit }

        // Chain behind any in-flight request so actor re-entrancy cannot run two lookups at once.
        let previous = tail
        let work = Task<Place?, Never> { [self] in
            await previous?.value
            return await self.lookup(point, key: key)
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func lookup(_ point: GeoPoint, key: PlaceKey) async -> Place? {
        if let hit = cache[key] { return hit }
        if let last = lastRequest {
            let wait = spacing - (ContinuousClock.now - last)
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        lastRequest = .now
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        let marks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let mark = marks?.first,
              let name = mark.locality ?? mark.subAdministrativeArea ?? mark.country else { return nil }
        let place = Place(name: name, timeZoneIdentifier: mark.timeZone?.identifier)
        cache[key] = place
        return place
    }
}
