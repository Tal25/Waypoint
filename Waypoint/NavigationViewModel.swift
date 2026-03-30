import Foundation
import CoreLocation
import Combine

@MainActor
class NavigationViewModel: NSObject, ObservableObject {

    // MARK: - Published state
    @Published var distanceMetres: Double = 0
    @Published var gpsAccuracy: Double = -1
    @Published var isNavigating = false
    @Published var hasLocationPermission = false
    @Published var statusMessage = "Tap Start to begin navigation"
    @Published var isGPSReady = false  // true when accuracy ≤ 20 m

    // MARK: - Audio engine (shared with ContentView)
    let audio = AudioNavigationEngine()

    // MARK: - Destination (hardcoded test point — Berkeley, CA)
    private let destination = CLLocationCoordinate2D(
        latitude:  37.876027202348325,
        longitude: -122.25849044991348
    )

    // MARK: - Private
    private let locationManager = CLLocationManager()
    private var userLocation: CLLocation?
    private var userHeading: CLLocationDirection = 0
    private var waypoints: [CLLocationCoordinate2D] = []
    private var currentWaypointIndex = 0
    private var announcedMilestones: Set<Int> = []

    private let distanceMilestones: [Double] = [500, 300, 200, 100, 50, 20]

    // MARK: - Init

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 2          // update every 2 m
        locationManager.headingFilter = 3            // update every 3 degrees
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        audio.setup()
    }

    // MARK: - Permissions

    func requestPermissions() {
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Navigation lifecycle

    func startNavigation() {
        guard hasLocationPermission else {
            audio.speak("Location permission is required. Please enable it in Settings.")
            return
        }
        guard isGPSReady, let loc = userLocation else {
            audio.speak("Waiting for GPS signal.")
            return
        }

        isNavigating = true
        announcedMilestones = []
        audio.startNavigation()

        Task {
            await fetchRoute(from: loc.coordinate, to: destination)
        }
    }

    func stopNavigation() {
        isNavigating = false
        waypoints = []
        currentWaypointIndex = 0
        audio.stopNavigation()
        statusMessage = "Navigation stopped"
    }

    // MARK: - OSRM route fetch

    func fetchRoute(from origin: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D) async {
        // OSRM public API — foot profile, full GeoJSON geometry, no key required
        let urlString = "https://router.project-osrm.org/route/v1/foot/"
            + "\(origin.longitude),\(origin.latitude);"
            + "\(dest.longitude),\(dest.latitude)"
            + "?overview=full&geometries=geojson"

        guard let url = URL(string: urlString) else {
            fallbackToDirect()
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let points = try parseOSRMGeometry(data)
            waypoints = points
            currentWaypointIndex = 0
            statusMessage = "Route loaded — \(points.count) waypoints"
        } catch {
            fallbackToDirect()
        }
    }

    private func fallbackToDirect() {
        waypoints = [destination]
        currentWaypointIndex = 0
        audio.speak("Could not load route. Navigating direct to destination.")
    }

    private func parseOSRMGeometry(_ data: Data) throws -> [CLLocationCoordinate2D] {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let routes = json["routes"] as? [[String: Any]],
            let first = routes.first,
            let geometry = first["geometry"] as? [String: Any],
            let coords = geometry["coordinates"] as? [[Double]]
        else {
            throw URLError(.cannotParseResponse)
        }
        // GeoJSON order is [longitude, latitude]
        return coords.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
        }
    }

    // MARK: - Navigation update (called on every location/heading change)

    private func updateNavigation(from userLoc: CLLocation) {
        let target = currentTarget()
        let targetLoc = CLLocation(latitude: target.latitude, longitude: target.longitude)

        // Advance waypoint when within 12 m
        if targetLoc.distance(from: userLoc) < 12, currentWaypointIndex < waypoints.count - 1 {
            currentWaypointIndex += 1
        }

        let totalDist = totalRemainingDistance(from: userLoc.coordinate)
        distanceMetres = totalDist
        statusMessage = formattedDistance(totalDist) + " to destination"

        let bearing = bearingFrom(userLoc.coordinate, to: currentTarget())
        let relativeBearing = (bearing - userHeading + 360).truncatingRemainder(dividingBy: 360)

        audio.update(distanceMetres: totalDist, relativeBearingDegrees: relativeBearing)

        if totalDist < 5 {
            isNavigating = false
            audio.playArrivalChime()
            return
        }

        checkMilestones(distance: totalDist)
    }

    private func currentTarget() -> CLLocationCoordinate2D {
        guard !waypoints.isEmpty else { return destination }
        return waypoints[min(currentWaypointIndex, waypoints.count - 1)]
    }

    private func totalRemainingDistance(from coord: CLLocationCoordinate2D) -> Double {
        guard !waypoints.isEmpty else { return haversine(from: coord, to: destination) }
        var total = haversine(from: coord, to: currentTarget())
        for i in currentWaypointIndex ..< waypoints.count - 1 {
            total += haversine(from: waypoints[i], to: waypoints[i + 1])
        }
        return total
    }

    private func checkMilestones(distance: Double) {
        for milestone in distanceMilestones {
            let key = Int(milestone)
            if distance <= milestone, !announcedMilestones.contains(key) {
                announcedMilestones.insert(key)
                let text = milestone >= 1000
                    ? "\(Int(milestone / 1000)) kilometre remaining"
                    : "\(Int(milestone)) metres remaining"
                audio.speak(text)
            }
        }
    }

    // MARK: - Formatting

    private func formattedDistance(_ metres: Double) -> String {
        metres >= 1000
            ? String(format: "%.1f km", metres / 1000)
            : String(format: "%.0f m", metres)
    }

    // MARK: - Geometry helpers

    func bearingFrom(_ from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude  * .pi / 180
        let lat2 = to.latitude    * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    func haversine(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let dLat = (to.latitude  - from.latitude)  * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude   * .pi / 180
        let a = sin(dLat/2)*sin(dLat/2) + cos(lat1)*cos(lat2)*sin(dLon/2)*sin(dLon/2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - CLLocationManagerDelegate

extension NavigationViewModel: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.hasLocationPermission = (status == .authorizedAlways || status == .authorizedWhenInUse)
        }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        case .denied, .restricted:
            Task { @MainActor in
                self.audio.speak("Location access denied. Please enable it in Settings to use navigation.")
            }
        default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.userLocation = loc
            self.gpsAccuracy = loc.horizontalAccuracy
            let ready = loc.horizontalAccuracy > 0 && loc.horizontalAccuracy <= 20
            if ready != self.isGPSReady {
                self.isGPSReady = ready
                if !ready {
                    self.statusMessage = "Waiting for GPS signal…"
                } else if !self.isNavigating {
                    self.statusMessage = "Tap Start to begin navigation"
                }
            }
            if self.isNavigating { self.updateNavigation(from: loc) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.userHeading = heading
            if self.isNavigating, let loc = self.userLocation {
                self.updateNavigation(from: loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.audio.speak("Location error. Check GPS signal.")
        }
    }
}
