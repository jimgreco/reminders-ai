import CoreLocation
import MapKit

/// The town the phone is in ("East Hampton, NY"), for the planner and the
/// assistant: some tasks can only be done in one place. Only that name leaves
/// the device, never coordinates. Nil whenever location is off or slow to
/// arrive, and everything works without it.
@MainActor
final class PlaceFinder: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceFinder()

    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var cached: (name: String, at: Date, from: CLLocation)?

    /// How long a fix may take before the request goes without a place.
    private static let patience: Duration = .seconds(4)
    /// A name is reused for this long, and for longer while the phone has not moved.
    private static let freshFor: TimeInterval = 10 * 60

    override private init() {
        super.init()
        manager.delegate = self
        // A town is all that is needed, and a coarse fix comes fastest.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Asks for permission the first time. Returns nil if it is refused.
    func current() async -> String? {
        if let cached, Date().timeIntervalSince(cached.at) < Self.freshFor { return cached.name }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            await withCheckedContinuation { authorizationWaiters.append($0) }
        }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return nil }
        guard let location = await locate() else { return cached?.name }
        if let cached, location.distance(from: cached.from) < 2_000 {
            self.cached = (cached.name, Date(), cached.from)
            return cached.name
        }
        guard let name = await Self.name(of: location) else { return nil }
        cached = (name, Date(), location)
        return name
    }

    /// A new fix, or the last one the system has if none arrives in time.
    private func locate() async -> CLLocation? {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled, let self else { return }
            self.finish(self.manager.location)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 { manager.requestLocation() }
        }
    }

    private func finish(_ location: CLLocation?) {
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(returning: location) }
    }

    private static func name(of location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        return placeName(city: item.addressRepresentations?.cityWithContext, region: item.addressRepresentations?.regionName)
    }

    /// "East Hampton, NY", or the country alone where there is no town.
    nonisolated static func placeName(city: String?, region: String?) -> String? {
        let parts = [city, region].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.first
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let waiters = self.authorizationWaiters
            self.authorizationWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.finish(latest ?? self.manager.location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(self.manager.location) }
    }
}
