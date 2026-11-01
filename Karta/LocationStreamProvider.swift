import CoreLocation
import RouteBuilderCore

/// A continuous stream of fixes, for recording.
///
/// `LocationProvider` answers "where am I" once and stops. This one stays up
/// for the length of a hike, including while the recording is paused and
/// while the app is in the user's pocket, which is where a trail app spends
/// most of its life.
///
/// Fixes are handed over raw. Judging them is `DistanceAccuracyTrackFilter`'s
/// job and deciding what to do with them is `TrackRecorder`'s; this file only
/// bridges CoreLocation into Swift concurrency.
@MainActor
final class LocationStreamProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: AsyncStream<LocationFix>.Continuation?

    override init() {
        super.init()
        manager.delegate = self
        // Best, not navigation: navigation accuracy assumes a road network
        // and a windscreen, and it costs battery for precision a hiking
        // track does not use.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness

        // CoreLocation's own auto-pause, off on purpose. It decides for
        // itself that you have stopped moving and silently stops delivering,
        // with no event saying so — which is a direct cause of the gap this
        // whole feature exists to avoid. Karta pauses itself, visibly, off a
        // rule it can explain.
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Starts delivering. The stream ends when `stop()` is called.
    ///
    /// Always authorisation, because recording has to survive the screen
    /// locking and the phone going into a pocket. iOS asks for When In Use
    /// first and offers the upgrade itself; a refusal is not fatal, it just
    /// means the recording stops at the lock screen.
    func start() -> AsyncStream<LocationFix> {
        manager.requestAlwaysAuthorization()

        let stream = AsyncStream<LocationFix> { continuation in
            self.continuation = continuation
        }

        // Set before starting updates, and only ever with the background mode
        // declared in the build settings — CoreLocation traps at runtime if
        // the capability is missing rather than returning an error.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        return stream
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        continuation?.finish()
        continuation = nil
    }

    // ---------- CLLocationManagerDelegate ----------

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Every location in the batch, not just the last. iOS delivers a
        // backlog after a gap in processing time, and those are real fixes
        // from the stretch that was missed — dropping all but the newest
        // would turn a recoverable batch into a gap.
        for location in locations {
            continuation?.yield(LocationFix(
                coordinate: Coordinate(longitude: location.coordinate.longitude,
                                       latitude: location.coordinate.latitude),
                // Handed over as CoreLocation reports it, negatives included.
                // The filter knows what a negative accuracy means; nothing
                // else should have to.
                horizontalAccuracyM: location.horizontalAccuracy,
                timestamp: location.timestamp,
                speedMPS: location.speed
            ))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Deliberately not ending the stream. A transient failure under
        // canopy is normal and recoverable; tearing down the recording
        // because of one is not. A real outage shows up as a gap, which is a
        // thing the track can represent.
    }
}
