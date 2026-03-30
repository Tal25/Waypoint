import Foundation
import CoreLocation

// MARK: - OccupancyGrid
//
// Flat UInt8 array: 0 = unknown, 1 = free, 2 = occupied.
// 25 × 25 cells, 0.25 m each → ~6.25 m × 6.25 m centred on the camera.
//
// All mutations happen on ar.analysis queue — never read or write from the main thread.
// `latestGrid` on ARSceneAnalyzer is the safe published copy for main-thread reads.

struct OccupancyGrid {

    // MARK: - Cell constants
    static let unknown:  UInt8 = 0
    static let free:     UInt8 = 1
    static let occupied: UInt8 = 2

    // MARK: - Grid geometry
    static let cellSize: Float = 0.25
    static let radius:   Int   = 12              // 3 m each side
    static let side:     Int   = radius * 2 + 1  // 25 cells

    // MARK: - Storage
    private(set) var cells: [UInt8]
    private(set) var originX: Float = 0   // ARKit world X of grid centre (= camera X)
    private(set) var originZ: Float = 0   // ARKit world Z of grid centre (= camera Z)

    // MARK: - GPS reference (set once after first fix while session is live)
    var sessionOriginLat:  Double = 0   // 0 means "not yet captured"
    var sessionOriginLng:  Double = 0
    var sessionOriginARX:  Double = 0   // ARKit world X where GPS was captured
    var sessionOriginARZ:  Double = 0   // ARKit world Z where GPS was captured
    var sessionHeadingDeg: Double = 0   // compass heading at capture moment

    // MARK: - Device flag
    var isLiDAR: Bool = false

    // MARK: - Init
    init() {
        cells = [UInt8](repeating: OccupancyGrid.unknown,
                        count: OccupancyGrid.side * OccupancyGrid.side)
    }

    // MARK: - Reset (call at the start of every analysis frame)
    mutating func reset(cameraX: Float, cameraZ: Float) {
        originX = cameraX
        originZ = cameraZ
        for i in cells.indices { cells[i] = OccupancyGrid.unknown }
    }

    // MARK: - Coordinate helpers

    /// World XZ → (row, col). Returns nil when outside the grid.
    func worldToCell(x: Float, z: Float) -> (row: Int, col: Int)? {
        let col = Int(((x - originX) / OccupancyGrid.cellSize).rounded()) + OccupancyGrid.radius
        let row = Int(((z - originZ) / OccupancyGrid.cellSize).rounded()) + OccupancyGrid.radius
        let n   = OccupancyGrid.side
        guard col >= 0, col < n, row >= 0, row < n else { return nil }
        return (row, col)
    }

    /// Centre of cell (row, col) in ARKit world space.
    func cellCentre(row: Int, col: Int) -> (x: Float, z: Float) {
        (originX + Float(col - OccupancyGrid.radius) * OccupancyGrid.cellSize,
         originZ + Float(row - OccupancyGrid.radius) * OccupancyGrid.cellSize)
    }

    // MARK: - Mark

    /// Mark a world-space XZ position. Occupied cells are never downgraded to free.
    mutating func mark(x: Float, z: Float, as value: UInt8) {
        guard let (r, c) = worldToCell(x: x, z: z) else { return }
        let idx = r * OccupancyGrid.side + c
        if value == OccupancyGrid.free, cells[idx] == OccupancyGrid.occupied { return }
        cells[idx] = value
    }

    // MARK: - Stats
    var freeCount:     Int { cells.filter { $0 == OccupancyGrid.free     }.count }
    var occupiedCount: Int { cells.filter { $0 == OccupancyGrid.occupied }.count }

    // MARK: - Neighbourhood queries

    func freeNeighbourCount(row: Int, col: Int) -> Int {
        let n = OccupancyGrid.side
        var count = 0
        for dr in -1...1 { for dc in -1...1 {
            guard dr != 0 || dc != 0 else { continue }
            let r = row + dr, c = col + dc
            guard r >= 0, r < n, c >= 0, c < n else { continue }
            if cells[r * n + c] == OccupancyGrid.free { count += 1 }
        }}
        return count
    }

    private func hasOccupiedWithin(row: Int, col: Int, radiusM: Float) -> Bool {
        let rc = Int((radiusM / OccupancyGrid.cellSize).rounded(.up))
        let n  = OccupancyGrid.side
        for dr in -rc...rc { for dc in -rc...rc {
            let r = row + dr, c = col + dc
            guard r >= 0, r < n, c >= 0, c < n else { continue }
            if cells[r * n + c] == OccupancyGrid.occupied { return true }
        }}
        return false
    }

    // MARK: - Waypoint candidate

    struct Candidate {
        let row: Int
        let col: Int
        let worldX: Float
        let worldZ: Float
        let distanceM: Float
        let score: Float
    }

    /// Select the highest-scoring free cell toward `destinationBearingDeg` (absolute compass).
    /// Returns nil when no safe cell meets the safety constraints.
    func selectBestCell(destinationBearingDeg: Double) -> Candidate? {
        guard sessionOriginLat != 0 else { return nil }

        // Convert absolute destination bearing → grid-relative direction.
        // Grid -Z aligns with the compass heading captured at sessionHeadingDeg.
        let relBear = Float((destinationBearingDeg - sessionHeadingDeg) * .pi / 180)
        let destGX  =  sin(relBear)   // rightward component (along grid +X)
        let destGZ  = -cos(relBear)   // forward  component (along grid -Z)

        let n           = OccupancyGrid.side
        let nonLiDARBar: Float = 0.7  // dirScore + clearScore threshold on non-LiDAR
        var bestScore: Float = -Float.greatestFiniteMagnitude
        var best: Candidate? = nil

        for row in 0..<n {
            for col in 0..<n {
                guard cells[row * n + col] == OccupancyGrid.free else { continue }

                let (wx, wz) = cellCentre(row: row, col: col)
                let dx = wx - originX
                let dz = wz - originZ
                let dist = (dx * dx + dz * dz).squareRoot()
                guard dist >= 1.0, dist <= 2.0 else { continue }

                // Safety: no occupied cell within 0.8 m
                guard !hasOccupiedWithin(row: row, col: col, radiusM: 0.8) else { continue }

                // Direction score — must not send user backwards
                let dirX = dx / dist, dirZ = dz / dist
                let dirScore = dirX * destGX + dirZ * destGZ
                guard dirScore > -0.3 else { continue }

                let clearScore = Float(freeNeighbourCount(row: row, col: col)) / 8.0
                let distScore  = max(0, 1.0 - abs(dist - 1.5) / 1.5)

                // Non-LiDAR: require higher confidence before accepting
                if !isLiDAR, (dirScore + clearScore) < nonLiDARBar { continue }

                let combined = dirScore * 0.6 + clearScore * 0.3 + distScore * 0.1
                if combined > bestScore {
                    bestScore = combined
                    best = Candidate(row: row, col: col,
                                     worldX: wx, worldZ: wz,
                                     distanceM: dist, score: combined)
                }
            }
        }
        return best
    }

    // MARK: - GPS conversion (heading-compensated)

    /// Convert an ARKit world-space position to a GPS coordinate.
    /// Uses the session GPS origin and compass heading to rotate ARKit axes → geographic axes.
    func worldToGPS(wx: Float, wz: Float) -> CLLocationCoordinate2D {
        let dx = Double(wx) - sessionOriginARX
        let dz = Double(wz) - sessionOriginARZ
        let θ  = sessionHeadingDeg * .pi / 180
        // Rotate ARKit (X, Z) → geographic (east, north)
        // ARKit +X → bearing sessionHeadingDeg + 90 → east = cos(θ), north = -sin(θ)
        // ARKit -Z → bearing sessionHeadingDeg     → east = sin(θ),  north =  cos(θ)
        let east  =  dx * cos(θ) - dz * sin(θ)
        let north = -dx * sin(θ) - dz * cos(θ)
        return CLLocationCoordinate2D(
            latitude:  sessionOriginLat + north / 111_111.0,
            longitude: sessionOriginLng + east  / (111_111.0 * cos(sessionOriginLat * .pi / 180))
        )
    }
}
