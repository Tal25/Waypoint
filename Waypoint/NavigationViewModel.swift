import Foundation
import CoreLocation
import Combine

@MainActor
class NavigationViewModel: NSObject, ObservableObject {

    // MARK: - Published state
    @Published var distanceMetres:   Double = 0
    @Published var gpsAccuracy:      Double = -1
    @Published var isNavigating             = false
    @Published var hasLocationPermission    = false
    @Published var statusMessage            = "Search for a destination"
    @Published var isGPSReady               = false
    @Published var compassHeading:   Double = 0
    @Published var relativeBearing:  Double = 0
    @Published var destinationName:  String = ""
    @Published var destinationSet:   Bool   = false
    @Published var userCoordinate:   CLLocationCoordinate2D?

    // MARK: - Audio engine (shared with ContentView)
    let audio = AudioNavigationEngine()

    // MARK: - Destination
    private var destination = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    // MARK: - Private
    private let locationManager      = CLLocationManager()
    private var userLocation:        CLLocation?
    private var userHeading:         CLLocationDirection = 0
    private var waypoints:           [CLLocationCoordinate2D] = []
    private var currentWaypointIndex = 0
    private var microWaypoint:       CLLocationCoordinate2D?

    // MARK: - Init

    override init() {
        super.init()
        locationManager.delegate                        = self
        locationManager.desiredAccuracy                 = kCLLocationAccuracyBest
        locationManager.distanceFilter                  = 1
        locationManager.headingFilter                   = 3
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        audio.setup()
    }

    // MARK: - Permissions

    func requestPermissions() {
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Destination management

    func setDestination(_ coord: CLLocationCoordinate2D, name: String) {
        if isNavigating { stopNavigation() }
        destination          = coord
        destinationSet       = true
        destinationName      = name
        statusMessage        = name
        waypoints            = []
        currentWaypointIndex = 0
    }

    func clearDestination() {
        if isNavigating { stopNavigation() }
        destination          = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        destinationSet       = false
        destinationName      = ""
        statusMessage        = "Search for a destination"
        waypoints            = []
        currentWaypointIndex = 0
    }

    // MARK: - Navigation lifecycle

    func startNavigation() {
        guard hasLocationPermission else { return }
        guard isGPSReady, let loc = userLocation else { return }
        guard destinationSet else { return }

        isNavigating = true
        audio.startNavigation()

        Task {
            await fetchRoute(from: loc.coordinate, to: destination)
        }
    }

    func stopNavigation() {
        isNavigating         = false
        waypoints            = []
        currentWaypointIndex = 0
        microWaypoint        = nil
        audio.stopNavigation()
        statusMessage = destinationSet ? destinationName : "Search for a destination"
    }

    /// Temporarily steer toward a nearby AR-detected opening.
    /// Clears automatically when user comes within 1 m of the coordinate.
    func setMicroWaypoint(_ coord: CLLocationCoordinate2D) {
        microWaypoint = coord
    }

    /// Clear the active micro-waypoint immediately (safety stop or path unavailable).
    func clearMicroWaypoint() {
        microWaypoint = nil
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
            let points    = try parseOSRMGeometry(data)
            waypoints            = points
            currentWaypointIndex = 0
            statusMessage        = "Route loaded — \(points.count) waypoints"
        } catch {
            fallbackToDirect()
        }
    }

    private func fallbackToDirect() {
        waypoints            = [destination]
        currentWaypointIndex = 0
        audio.playError()
    }

    private func parseOSRMGeometry(_ data: Data) throws -> [CLLocationCoordinate2D] {
        guard
            let json     = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let routes   = json["routes"]                               as? [[String: Any]],
            let first    = routes.first,
            let geometry = first["geometry"]                            as? [String: Any],
            let coords   = geometry["coordinates"]                      as? [[Double]]
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
        guard destinationSet else { return }

        // Advance route waypoint when user is within 12 m
        let routeTarget    = routeCurrentTarget()
        let routeTargetLoc = CLLocation(latitude: routeTarget.latitude, longitude: routeTarget.longitude)
        if routeTargetLoc.distance(from: userLoc) < 12, currentWaypointIndex < waypoints.count - 1 {
            currentWaypointIndex += 1
        }

        // Clear micro-waypoint once user is within 1.0 m of it
        if let micro = microWaypoint {
            let microLoc = CLLocation(latitude: micro.latitude, longitude: micro.longitude)
            if microLoc.distance(from: userLoc) < 1.0 { microWaypoint = nil }
        }

        let totalDist  = totalRemainingDistance(from: userLoc.coordinate)
        distanceMetres = totalDist
        statusMessage  = formatDistance(totalDist) + " to destination"

        let bearing = bearingFrom(userLoc.coordinate, to: currentTarget())
        let rel     = (bearing - userHeading + 360).truncatingRemainder(dividingBy: 360)
        relativeBearing = rel

        // GPS accuracy error (>50 ft / ~15 m)
        if gpsAccuracy > 15 { audio.playError() }

        audio.update(distanceMetres: totalDist, relativeBearingDegrees: rel)

        if totalDist < 5 {
            isNavigating = false
            audio.playArrivalChime()
        }
    }

    private func routeCurrentTarget() -> CLLocationCoordinate2D {
        guard !waypoints.isEmpty else { return destination }
        return waypoints[min(currentWaypointIndex, waypoints.count - 1)]
    }

    private func currentTarget() -> CLLocationCoordinate2D {
        return microWaypoint ?? routeCurrentTarget()
    }

    private func totalRemainingDistance(from coord: CLLocationCoordinate2D) -> Double {
        guard destinationSet else { return 0 }
        guard !waypoints.isEmpty else { return haversine(from: coord, to: destination) }
        var total = haversine(from: coord, to: routeCurrentTarget())
        for i in currentWaypointIndex ..< waypoints.count - 1 {
            total += haversine(from: waypoints[i], to: waypoints[i + 1])
        }
        return total
    }

    // MARK: - Formatting

    private func formatDistance(_ metres: Double) -> String {
        // Always whole feet — internal calculations stay in metres
        let feet = Int((metres * 3.28084).rounded())
        return "\(feet) ft"
    }

    // MARK: - Geometry helpers

    func bearingFrom(_ from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude  * .pi / 180
        let lat2 = to.latitude    * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y    = sin(dLon) * cos(lat2)
        let x    = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    func haversine(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let R    = 6_371_000.0
        let dLat = (to.latitude  - from.latitude)  * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude   * .pi / 180
        let a    = sin(dLat/2)*sin(dLat/2) + cos(lat1)*cos(lat2)*sin(dLon/2)*sin(dLon/2)
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
            Task { @MainActor in self.audio.playError() }
        default:
            break
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.userLocation   = loc
            self.userCoordinate = loc.coordinate
            self.gpsAccuracy    = loc.horizontalAccuracy
            let ready = loc.horizontalAccuracy > 0 && loc.horizontalAccuracy <= 20
            if ready != self.isGPSReady {
                self.isGPSReady = ready
                if !ready && !self.isNavigating {
                    self.statusMessage = "Waiting for GPS signal…"
                } else if ready && !self.isNavigating && !self.destinationSet {
                    self.statusMessage = "Search for a destination"
                }
            }
            if self.isNavigating { self.updateNavigation(from: loc) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.userHeading    = heading
            self.compassHeading = heading
            if self.isNavigating, let loc = self.userLocation {
                self.updateNavigation(from: loc)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in self.audio.playError() }
    }
}
