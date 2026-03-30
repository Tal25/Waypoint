import Foundation

// MARK: - OccupancyGrid
//
// A 2D occupancy grid in ARKit world-space (XZ plane).
// Self-contained and testable in isolation — nothing in this file
// touches navigation, CoreLocation, or ARKit sessions.
//
// Layout
//   col axis = world X (positive = right)
//   row axis = world Z (positive = away from camera in standard AR)
//   centre cell = (radius, radius) = grid origin (camera position at last reset)
//
// Usage
//   1. Call reset(cameraX:cameraZ:) once per analysis frame.
//   2. Call mark(x:z:as:) for each sampled mesh vertex.
//   3. Call clearestForwardBearing(forwardX:forwardZ:) to query the result.

struct OccupancyGrid {

    // MARK: - Configuration

    /// Metres represented by one cell edge.
    static let cellSize: Float = 0.25
    /// Number of cells from centre to edge in each axis direction.
    static let radius: Int     = 20           // → 5 m each side
    /// Total cells per axis (always odd so there is a true centre cell).
    static let side: Int       = radius * 2 + 1   // 41

    // MARK: - Cell state

    enum Cell: UInt8 {
        case unknown  = 0   // no data — treated as passable but penalised
        case free     = 1   // observed clear space
        case occupied = 2   // observed obstacle
    }

    // MARK: - Storage

    private(set) var cells: [Cell]
    /// World X of the grid's centre cell.
    private(set) var originX: Float = 0
    /// World Z of the grid's centre cell.
    private(set) var originZ: Float = 0

    init() {
        cells = [Cell](repeating: .unknown, count: OccupancyGrid.side * OccupancyGrid.side)
    }

    // MARK: - Reset

    /// Move the grid origin to the camera position and clear all cells.
    mutating func reset(cameraX: Float, cameraZ: Float) {
        originX = cameraX
        originZ = cameraZ
        for i in cells.indices { cells[i] = .unknown }
    }

    // MARK: - Coordinate conversion

    /// Convert world XZ to (row, col). Returns nil when outside the grid.
    func worldToGrid(x: Float, z: Float) -> (row: Int, col: Int)? {
        let col = Int(((x - originX) / OccupancyGrid.cellSize).rounded()) + OccupancyGrid.radius
        let row = Int(((z - originZ) / OccupancyGrid.cellSize).rounded()) + OccupancyGrid.radius
        let n   = OccupancyGrid.side
        guard col >= 0, col < n, row >= 0, row < n else { return nil }
        return (row, col)
    }

    // MARK: - Subscript

    subscript(row: Int, col: Int) -> Cell {
        get { cells[row * OccupancyGrid.side + col] }
        set { cells[row * OccupancyGrid.side + col] = newValue }
    }

    // MARK: - Marking

    /// Mark a world-space XZ position. Occupied cells are never downgraded to free.
    mutating func mark(x: Float, z: Float, as cell: Cell) {
        guard let (r, c) = worldToGrid(x: x, z: z) else { return }
        if cell == .free, self[r, c] == .occupied { return }
        self[r, c] = cell
    }

    // MARK: - Query: clearest forward bearing

    /// Returns the bearing offset in degrees of the path with the highest
    /// free-cell score in the forward arc (±60°, 5° steps).
    ///
    /// - Parameters:
    ///   - forwardX: Normalised world-space X component of camera forward (-cam.columns.2.x).
    ///   - forwardZ: Normalised world-space Z component of camera forward (-cam.columns.2.z).
    ///   - scanDistanceM: How far ahead to score (default 3 m).
    /// - Returns: Degrees offset from forward (positive = right, negative = left),
    ///            or nil when the grid contains no data at all.
    func clearestForwardBearing(forwardX: Float,
                                forwardZ: Float,
                                scanDistanceM: Float = 3.0) -> Float? {
        guard cells.contains(where: { $0 != .unknown }) else { return nil }

        let scanSteps = max(1, Int(scanDistanceM / OccupancyGrid.cellSize))
        var bestAngle: Float = 0
        var bestScore = Int.min

        for deg in stride(from: -60, through: 60, by: 5) {
            let rad  = Float(deg) * .pi / 180
            // Rotate forward vector clockwise by deg (positive = rightward)
            let dirX = forwardX * cos(rad) - forwardZ * sin(rad)
            let dirZ = forwardX * sin(rad) + forwardZ * cos(rad)

            var score = 0
            for step in 1 ... scanSteps {
                let wx = originX + dirX * Float(step) * OccupancyGrid.cellSize
                let wz = originZ + dirZ * Float(step) * OccupancyGrid.cellSize
                guard let (r, c) = worldToGrid(x: wx, z: wz) else { continue }
                switch self[r, c] {
                case .free:     score += 2
                case .unknown:  score += 1
                case .occupied: score -= 4
                }
            }

            if score > bestScore {
                bestScore = score
                bestAngle = Float(deg)
            }
        }

        return bestAngle
    }

    // MARK: - Debug

    /// Number of cells marked occupied.
    var occupiedCount: Int { cells.filter { $0 == .occupied }.count }
    /// Number of cells marked free.
    var freeCount: Int { cells.filter { $0 == .free }.count }
}
