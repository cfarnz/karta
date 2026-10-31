import CoreLocation
import RouteBuilderCore

/// One-shot "where am I", with a deadline.
///
/// Stands in for the web app's `navigator.geolocation.getCurrentPosition`,
/// including its 8 second timeout and its habit of resolving to nil rather
/// than throwing — Discover treats a missing fix as "search from the map
/// centre instead", which is a usable answer, not an error.
///
/// Main-actor throughout, which is what CoreLocation wants anyway: the
/// manager is created here and delivers its callbacks on the same queue, so
/// no lock is needed to guard the continuation.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// Resumed exactly once, by whichever of the delegate callbacks or the
    /// timeout gets there first.
    private var continuation: CheckedContinuation<Coordinate?, Never>?
    /// Cancelled as soon as a real answer lands, so a finished lookup does
    /// not leave a sleeping task behind.
    private var deadline: Task<Void, Never>?

    static let timeout = Duration.seconds(8)

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Nil when permission is refused, no fix arrives, or the deadline passes.
    func currentLocation() async -> Coordinate? {
        #if DEBUG
        // simctl's `privacy grant location` does not take on the iOS 27
        // simulator, so the permission alert blocks every headless run of
        // Discover. This reports "no fix", which is a path the app already
        // handles: the search falls back to the map centre.
        if ProcessInfo.processInfo.arguments.contains("-skipLocation") { return nil }
        #endif

        // Asking before the user has decided shows the system prompt; asking
        // after a denial is a no-op, so there is no need to branch on status
        // first. A denial lands in didFailWithError or simply never fixes,
        // and the timeout covers both.
        manager.requestWhenInUseAuthorization()

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            // A plain deadline rather than a task group racing the fix: the
            // group version is what the region-based isolation checker
            // refuses to reason about, and this does the same job with one
            // resume path for both outcomes.
            deadline = Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard !Task.isCancelled else { return }
                self?.resume(with: nil)
            }
            manager.requestLocation()
        }
    }

    private func resume(with coordinate: Coordinate?) {
        deadline?.cancel()
        deadline = nil
        // Whichever of the fix, the failure or the deadline arrives first
        // wins; nilling here is what makes the rest no-ops rather than a
        // double resume, which traps.
        let pending = continuation
        continuation = nil
        pending?.resume(returning: coordinate)
    }

    // ---------- CLLocationManagerDelegate ----------

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return resume(with: nil) }
        resume(with: Coordinate(longitude: location.coordinate.longitude,
                                latitude: location.coordinate.latitude))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resume(with: nil)
    }
}
