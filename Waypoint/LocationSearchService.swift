import MapKit
import Combine
import CoreLocation

// MARK: - LocationSearchService
// Wraps MKLocalSearchCompleter to provide typeahead destination search.

@MainActor
class LocationSearchService: NSObject, ObservableObject {

    @Published var query:       String = ""
    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var isSearching: Bool = false

    private let completer  = MKLocalSearchCompleter()
    private var cancellable: AnyCancellable?

    override init() {
        super.init()
        completer.delegate   = self
        completer.resultTypes = [.address, .pointOfInterest]

        // Debounce keystrokes so we don't fire a request on every character
        cancellable = $query
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] q in
                guard let self else { return }
                if q.isEmpty {
                    self.completions = []
                    self.isSearching = false
                } else {
                    self.isSearching = true
                    self.completer.queryFragment = q
                }
            }
    }

    /// Bias completions toward the user's current location.
    func setRegion(near coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters:  50_000,
            longitudinalMeters: 50_000
        )
    }

    /// Resolve a completion to a GPS coordinate and display name.
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> (CLLocationCoordinate2D, String) {
        let request  = MKLocalSearch.Request(completion: completion)
        let search   = MKLocalSearch(request: request)
        let response = try await search.start()
        guard let item = response.mapItems.first else {
            throw URLError(.cannotFindHost)
        }
        let name = item.name ?? completion.title
        return (item.placemark.coordinate, name)
    }
}

// MARK: - MKLocalSearchCompleterDelegate

extension LocationSearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.completions = completer.results
            self.isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.completions = []
            self.isSearching = false
        }
    }
}
