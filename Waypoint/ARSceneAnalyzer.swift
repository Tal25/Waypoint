import ARKit
import CoreLocation
import AVFoundation

// MARK: - ARSceneAnalyzer

class ARSceneAnalyzer: NSObject, ObservableObject {

    // MARK: - Published results
    @Published var trackingState: String          = "Not Available"
    @Published var depthMode: String              = "Estimated"
    @Published var obstacleDistanceFt: Double     = 30.0
    @Published var surfaceClassification: String  = "unknown"
    @Published var openingBearing: Double?        = nil
    @Published var suggestedMicroWaypoint: CLLocationCoordinate2D? = nil
    @Published var isSessionRunning: Bool         = false
    @Published var thermalWarning: Bool           = false
    @Published var latestGrid: OccupancyGrid      = OccupancyGrid()

    // Pathfinding state (for HUD display)
    @Published var pathfindingMode: String        = "GPS only"
    @Published var freeCellCount: Int             = 0
    @Published var microWaypointDistanceM: Float  = 0   // metres to current micro-waypoint
    @Published var microWaypointGridRow: Int      = -1  // -1 = none
    @Published var microWaypointGridCol: Int      = -1

    // MARK: - Public session (shared with ARViewContainer)
    let session = ARSession()

    // MARK: - Input from CameraTabView (set on main thread, read on analysis queue)
    var headingDegrees: Double       = 0   // device compass heading
    var destinationBearing: Double   = 0   // absolute compass bearing to GPS destination
    var userFarFromDestination: Bool = true // true when > 8 m from destination

    // MARK: - Private analysis state
    private var isLiDAR              = false
    private var occupancyGrid        = OccupancyGrid()
    private var lastFrame: ARFrame?  = nil

    // Pathfinding mode management
    private var pathfindingActive    = false
    private var lastModeSwitch: Date = .distantPast
    private var pathUnclearAnnounced = false
    private var stopAnnounced        = false

    private let analysisQueue = DispatchQueue(label: "ar.analysis", qos: .userInitiated)
    private var lastAnalysisTime: Date = .distantPast
    private var analysisInterval: TimeInterval = 0.5
    private var thermalState: ProcessInfo.ThermalState = .nominal

    // Location (for GPS origin capture only)
    private let locationManager   = CLLocationManager()
    private var currentCoordinate: CLLocationCoordinate2D?

    private let speech = AVSpeechSynthesizer()

    // MARK: - Init

    override init() {
        super.init()
        session.delegate = self
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else { return }

        let config = ARWorldTrackingConfiguration()
        config.planeDetection       = [.horizontal, .vertical]
        config.environmentTexturing = .none

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
            config.frameSemantics      = [.smoothedSceneDepth]
            isLiDAR = true
            DispatchQueue.main.async { self.depthMode = "LiDAR" }
        } else {
            isLiDAR = false
            DispatchQueue.main.async { self.depthMode = "Estimated" }
        }

        occupancyGrid        = OccupancyGrid()
        occupancyGrid.isLiDAR = isLiDAR
        pathfindingActive    = false
        lastModeSwitch       = .distantPast
        pathUnclearAnnounced = false
        stopAnnounced        = false

        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        locationManager.startUpdatingLocation()

        DispatchQueue.main.async {
            self.isSessionRunning = true
            self.trackingState    = "Limited"
            self.pathfindingMode  = "GPS only"
        }
    }

    func pauseSession() {
        session.pause()
        locationManager.stopUpdatingLocation()
        // Reset GPS origin so it is captured fresh on next session start
        occupancyGrid.sessionOriginLat = 0
        pathfindingActive = false
        DispatchQueue.main.async {
            self.isSessionRunning  = false
            self.trackingState     = "Not Available"
            self.pathfindingMode   = "GPS only"
            self.suggestedMicroWaypoint = nil
            self.microWaypointGridRow = -1
            self.microWaypointGridCol = -1
        }
    }

    /// Called by CameraTabView when the user reaches the current micro-waypoint.
    /// Immediately re-runs pathfinding on the cached last frame without waiting 500 ms.
    func requestNextWaypoint() {
        analysisQueue.async { [weak self] in
            guard let self = self, let frame = self.lastFrame else { return }
            self.runPathfindingAndPublish(frame: frame)
        }
    }

    // MARK: - Thermal management

    @objc private func thermalStateChanged() {
        let state = ProcessInfo.processInfo.thermalState
        thermalState = state
        switch state {
        case .nominal, .fair:
            analysisInterval = 0.5
            DispatchQueue.main.async { self.thermalWarning = false }
        case .serious:
            analysisInterval = 1.0
            DispatchQueue.main.async { self.thermalWarning = true }
        case .critical:
            analysisInterval = 999
            DispatchQueue.main.async { self.thermalWarning = true }
            speak("Pausing camera to cool down.")
        @unknown default:
            break
        }
    }

    // MARK: - Speech

    private func speak(_ text: String) {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: "en-US")
        utt.rate  = 0.52
        speech.speak(utt)
    }
}

// MARK: - ARSessionDelegate

extension ARSceneAnalyzer: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard thermalState != .critical else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnalysisTime) >= analysisInterval else { return }
        lastAnalysisTime = now

        let stateStr = trackingStateLabel(frame.camera.trackingState)
        DispatchQueue.main.async { self.trackingState = stateStr }

        analysisQueue.async { [weak self] in self?.analyzeFrame(frame) }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.trackingState = "Not Available" }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.trackingState = "Limited" }
    }

    private func trackingStateLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:       return "Normal"
        case .limited:      return "Limited"
        case .notAvailable: return "Not Available"
        @unknown default:   return "Not Available"
        }
    }
}

// MARK: - Frame analysis pipeline

extension ARSceneAnalyzer {

    private func analyzeFrame(_ frame: ARFrame) {
        lastFrame = frame

        // ── Obstacle distance ─────────────────────────────────────────────
        let distFt = isLiDAR ? lidarObstacleDistance(frame: frame)
                              : estimatedObstacleDistance(frame: frame)

        // Safety stop: obstacle < 0.5 m (1.64 ft)
        if distFt < 1.64 {
            if !stopAnnounced { speak("Stop."); stopAnnounced = true }
            DispatchQueue.main.async { [weak self] in
                self?.obstacleDistanceFt      = distFt
                self?.suggestedMicroWaypoint  = nil
                self?.microWaypointGridRow    = -1
                self?.microWaypointGridCol    = -1
                self?.microWaypointDistanceM  = 0
            }
            return
        }
        stopAnnounced = false

        // ── Surface + opening ─────────────────────────────────────────────
        let surface = classifySurface(frame: frame)
        let opening = detectOpening(frame: frame)

        // ── Occupancy grid ────────────────────────────────────────────────
        buildOccupancyGrid(frame: frame)

        // ── Pathfinding ───────────────────────────────────────────────────
        runPathfindingAndPublish(frame: frame)

        let gridCopy = occupancyGrid
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.obstacleDistanceFt      = distFt
            self.surfaceClassification   = surface
            self.openingBearing          = opening
            self.latestGrid              = gridCopy
            self.freeCellCount           = gridCopy.freeCount
        }
    }
}

// MARK: - Occupancy grid construction

extension ARSceneAnalyzer {

    private func buildOccupancyGrid(frame: ARFrame) {
        let cam   = frame.camera.transform
        let camX  = cam.columns.3.x
        let camY  = cam.columns.3.y
        let camZ  = cam.columns.3.z
        let fwdX  = -cam.columns.2.x
        let fwdZ  = -cam.columns.2.z

        // Capture GPS origin once (first fix while session is live)
        if occupancyGrid.sessionOriginLat == 0, let coord = currentCoordinate {
            occupancyGrid.sessionOriginLat  = coord.latitude
            occupancyGrid.sessionOriginLng  = coord.longitude
            occupancyGrid.sessionOriginARX  = Double(camX)
            occupancyGrid.sessionOriginARZ  = Double(camZ)
            occupancyGrid.sessionHeadingDeg = headingDegrees
            print("[ARSceneAnalyzer] GPS origin captured: \(coord.latitude), \(coord.longitude) hdg=\(Int(headingDegrees))°")
        }

        occupancyGrid.reset(cameraX: camX, cameraZ: camZ)

        let floorY = camY - 1.7   // floor ≈ camera Y − 1.5 m, 0.2 m margin
        let headY  = camY + 0.3   // max obstacle height

        // ── Mesh anchors (LiDAR) ──────────────────────────────────────────
        if isLiDAR {
            for anchor in frame.anchors {
                // ARPlaneAnchor: floor = free, other = occupied (in body zone)
                if let plane = anchor as? ARPlaneAnchor {
                    let ap   = plane.transform.columns.3
                    let dist = simd_length(SIMD3<Float>(ap.x - camX, 0, ap.z - camZ))
                    guard dist < 6 else { continue }

                    switch plane.classification {
                    case .floor:
                        markPlane(plane, as: OccupancyGrid.free, floorY: floorY, headY: headY)
                    case .wall, .ceiling, .seat, .table, .door, .window:
                        markPlane(plane, as: OccupancyGrid.occupied, floorY: floorY, headY: headY)
                    default:
                        break
                    }
                }

                // ARMeshAnchor: iterate sampled vertices
                guard let mesh = anchor as? ARMeshAnchor else { continue }
                let ap   = mesh.transform.columns.3
                let dx   = ap.x - camX, dz = ap.z - camZ
                guard dx * dx + dz * dz < 36 else { continue }  // within 6 m

                let geo    = mesh.geometry.vertices
                let count  = geo.count
                guard count > 0 else { continue }
                let stride = geo.stride
                let offset = geo.offset
                let buf    = geo.buffer.contents()
                let xform  = mesh.transform
                let step   = max(1, count / 300)

                var i = 0
                while i < count {
                    let ptr = buf.advanced(by: offset + i * stride)
                                 .assumingMemoryBound(to: Float.self)
                    let lx = ptr[0], ly = ptr[1], lz = ptr[2]
                    let wx = xform.columns.0.x*lx + xform.columns.1.x*ly + xform.columns.2.x*lz + xform.columns.3.x
                    let wy = xform.columns.0.y*lx + xform.columns.1.y*ly + xform.columns.2.y*lz + xform.columns.3.y
                    let wz = xform.columns.0.z*lx + xform.columns.1.z*ly + xform.columns.2.z*lz + xform.columns.3.z

                    if wy > floorY + 0.15, wy < headY {
                        occupancyGrid.mark(x: wx, z: wz, as: OccupancyGrid.occupied)
                    } else if wy <= floorY + 0.15 {
                        occupancyGrid.mark(x: wx, z: wz, as: OccupancyGrid.free)
                    }
                    i += step
                }
            }

            // Depth buffer → occupied cells (close obstacles not yet in mesh)
            if let depthMap = frame.smoothedSceneDepth?.depthMap {
                markDepthOccupancy(depthMap: depthMap, cam: frame.camera)
            }

        } else {
            // Non-LiDAR: plane anchors only
            for anchor in frame.anchors {
                guard let plane = anchor as? ARPlaneAnchor else { continue }
                let ap = plane.transform.columns.3
                let dist = simd_length(SIMD3<Float>(ap.x - camX, 0, ap.z - camZ))
                guard dist < 6 else { continue }
                switch plane.classification {
                case .floor:
                    markPlane(plane, as: OccupancyGrid.free, floorY: floorY, headY: headY)
                default:
                    markPlane(plane, as: OccupancyGrid.occupied, floorY: floorY, headY: headY)
                }
            }
        }

        _ = fwdX; _ = fwdZ  // suppress unused warnings — used in pathfinding
    }

    /// Mark a grid of sample points within an ARPlaneAnchor's extent.
    private func markPlane(_ plane: ARPlaneAnchor, as value: UInt8,
                           floorY: Float, headY: Float) {
        let ext  = plane.planeExtent
        let xf   = plane.transform
        let cx   = xf.columns.3.x, cz = xf.columns.3.z
        let hw   = ext.width  / 2
        let hh   = ext.height / 2
        // Sample a grid inside the plane extent (every 0.25 m)
        var u: Float = -hw
        while u <= hw {
            var v: Float = -hh
            while v <= hh {
                let wx = xf.columns.0.x * u + xf.columns.2.x * v + cx
                let wy = xf.columns.0.y * u + xf.columns.2.y * v + xf.columns.3.y
                let wz = xf.columns.0.z * u + xf.columns.2.z * v + cz
                // Only mark in body clearance zone
                if wy > floorY + 0.15, wy < headY {
                    occupancyGrid.mark(x: wx, z: wz, as: value)
                } else if value == OccupancyGrid.free, wy <= floorY + 0.15 {
                    occupancyGrid.mark(x: wx, z: wz, as: OccupancyGrid.free)
                }
                v += OccupancyGrid.cellSize
            }
            u += OccupancyGrid.cellSize
        }
    }

    /// Project close depth samples into the occupancy grid as obstacles.
    private func markDepthOccupancy(depthMap: CVPixelBuffer, cam: ARCamera) {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let w    = CVPixelBufferGetWidth(depthMap)
        let h    = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let buf  = base.assumingMemoryBound(to: Float32.self)

        let intr  = cam.intrinsics
        let xform = cam.transform
        let camX  = xform.columns.3.x
        let camY  = xform.columns.3.y
        let camZ  = xform.columns.3.z
        let floorY = camY - 1.7, headY = camY + 0.3
        let fx = intr[0][0], fy = intr[1][1]
        let cx = intr[2][0], cy = intr[2][1]

        var py = 0
        while py < h {
            var px = 0
            while px < w {
                let depth = buf[py * w + px]
                // Only interested in close obstacles (< 0.8 m)
                guard depth > 0, depth < 0.8, depth.isFinite else { px += 16; continue }
                // Camera-space 3D point
                let cpX = (Float(px) - cx) / fx * depth
                let cpY = -(Float(py) - cy) / fy * depth
                let cpZ = -depth
                // World space
                let wx = xform.columns.0.x*cpX + xform.columns.1.x*cpY + xform.columns.2.x*cpZ + camX
                let wy = xform.columns.0.y*cpX + xform.columns.1.y*cpY + xform.columns.2.y*cpZ + camY
                let wz = xform.columns.0.z*cpX + xform.columns.1.z*cpY + xform.columns.2.z*cpZ + camZ
                if wy > floorY + 0.15, wy < headY {
                    occupancyGrid.mark(x: wx, z: wz, as: OccupancyGrid.occupied)
                }
                px += 16
            }
            py += 16
        }
    }
}

// MARK: - Pathfinding

extension ARSceneAnalyzer {

    /// Select the best micro-waypoint and publish it. Called on analysisQueue.
    func runPathfindingAndPublish(frame: ARFrame) {
        let fc = occupancyGrid.freeCount

        // Determine if camera pathfinding should be active
        let trackingNormal: Bool
        if case .normal = frame.camera.trackingState { trackingNormal = true }
        else { trackingNormal = false }

        let shouldBeActive = trackingNormal
                          && fc >= 10
                          && userFarFromDestination
                          && occupancyGrid.sessionOriginLat != 0

        // Mode switch with 5-second hysteresis to prevent oscillation
        if shouldBeActive != pathfindingActive {
            let now = Date()
            if now.timeIntervalSince(lastModeSwitch) >= 5.0 {
                pathfindingActive = shouldBeActive
                lastModeSwitch    = now
                let msg = shouldBeActive ? "Camera guidance active."
                                         : "GPS guidance active."
                speak(msg)
                let mode = shouldBeActive ? "Camera path" : "GPS only"
                DispatchQueue.main.async { self.pathfindingMode = mode }
            }
        }

        guard pathfindingActive else {
            DispatchQueue.main.async {
                self.suggestedMicroWaypoint = nil
                self.microWaypointGridRow   = -1
                self.microWaypointGridCol   = -1
                self.microWaypointDistanceM = 0
            }
            return
        }

        // All cells unknown or occupied — fallback to GPS
        guard fc > 0 else {
            if !pathUnclearAnnounced {
                pathUnclearAnnounced = true
                speak("Area unmapped, using GPS.")
            }
            DispatchQueue.main.async {
                self.suggestedMicroWaypoint = nil
                self.microWaypointGridRow   = -1
                self.microWaypointGridCol   = -1
                self.microWaypointDistanceM = 0
            }
            return
        }

        guard let candidate = occupancyGrid.selectBestCell(destinationBearingDeg: destinationBearing) else {
            if !pathUnclearAnnounced {
                pathUnclearAnnounced = true
                speak("Path unclear, using GPS.")
            }
            DispatchQueue.main.async {
                self.suggestedMicroWaypoint = nil
                self.microWaypointGridRow   = -1
                self.microWaypointGridCol   = -1
                self.microWaypointDistanceM = 0
            }
            return
        }

        pathUnclearAnnounced = false
        let gps = occupancyGrid.worldToGPS(wx: candidate.worldX, wz: candidate.worldZ)

        print(String(format: "[Pathfinding] cell(%d,%d) score=%.2f dist=%.1fm destBear=%.0f°",
                     candidate.row, candidate.col, candidate.score,
                     candidate.distanceM, destinationBearing))

        let distM = candidate.distanceM
        DispatchQueue.main.async { [weak self] in
            self?.suggestedMicroWaypoint = gps
            self?.microWaypointGridRow   = candidate.row
            self?.microWaypointGridCol   = candidate.col
            self?.microWaypointDistanceM = distM
        }
    }
}

// MARK: - Obstacle distance (LiDAR + estimated)

extension ARSceneAnalyzer {

    private func lidarObstacleDistance(frame: ARFrame) -> Double {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap else { return 30.0 }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return 30.0 }
        let buf = base.assumingMemoryBound(to: Float32.self)

        let tanHalf = tan(15.0 * Double.pi / 180.0)
        let coneW   = Int(Double(width)  * tanHalf)
        let coneH   = Int(Double(height) * tanHalf)
        let cx = width / 2, cy = height / 2
        let x0 = max(0, cx - coneW), x1 = min(width,  cx + coneW)
        let y0 = max(0, cy - coneH), y1 = min(height, cy + coneH)

        var samples = [Float32]()
        samples.reserveCapacity(500)
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let v = buf[y * width + x]
                if v > 0, v.isFinite { samples.append(v) }
                x += 4
            }
            y += 4
        }
        guard !samples.isEmpty else { return 30.0 }
        samples.sort()
        let idx = max(0, Int(Float(samples.count) * 0.10))
        return max(0, min(30.0, Double(samples[idx]) * 3.28084))
    }

    private func estimatedObstacleDistance(frame: ARFrame) -> Double {
        let cam    = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let fwd    = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)
        var nearest: Float = 30.0 / 3.28084
        for anchor in frame.anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let ap      = SIMD3<Float>(plane.transform.columns.3.x,
                                       plane.transform.columns.3.y,
                                       plane.transform.columns.3.z)
            let toPlane = ap - camPos
            let dist    = simd_length(toPlane)
            guard dist < nearest, simd_dot(simd_normalize(toPlane), fwd) > 0.3 else { continue }
            nearest = dist
        }
        return max(0, min(30.0, Double(nearest) * 0.6 * 3.28084))
    }
}

// MARK: - Surface classification

extension ARSceneAnalyzer {

    private func classifySurface(frame: ARFrame) -> String {
        let cam    = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let fwd    = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)

        let priority: [String: Int] = [
            "door": 6, "window": 5, "wall": 4, "ceiling": 3, "floor": 2, "open": 1
        ]
        var best = "unknown", bestScore = 0

        for anchor in frame.anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let ap   = SIMD3<Float>(plane.transform.columns.3.x,
                                    plane.transform.columns.3.y,
                                    plane.transform.columns.3.z)
            let diff = ap - camPos
            let dist = simd_length(diff)
            guard dist < 10.0, dist > 0 else { continue }
            let dot   = simd_dot(simd_normalize(diff), fwd)
            let angle = acos(min(1, max(-1, dot))) * 180 / Float.pi
            guard angle < 45 else { continue }

            let label = planeLabel(plane.classification)
            let score = priority[label] ?? 0
            if score > bestScore { bestScore = score; best = label }
        }

        if isLiDAR {
            for anchor in frame.anchors {
                guard let mesh = anchor as? ARMeshAnchor else { continue }
                let ap   = SIMD3<Float>(mesh.transform.columns.3.x,
                                        mesh.transform.columns.3.y,
                                        mesh.transform.columns.3.z)
                guard simd_distance(camPos, ap) < 5.0 else { continue }
                let label = sampledMeshLabel(mesh, cameraPos: camPos, forward: fwd)
                let score = priority[label] ?? 0
                if score > bestScore { bestScore = score; best = label }
            }
        }
        return best
    }

    private func planeLabel(_ c: ARPlaneAnchor.Classification) -> String {
        switch c {
        case .wall:    return "wall"
        case .floor:   return "floor"
        case .ceiling: return "ceiling"
        case .door:    return "door"
        case .window:  return "window"
        case .seat:    return "seat"
        case .table:   return "table"
        default:       return "open"
        }
    }

    private func sampledMeshLabel(_ anchor: ARMeshAnchor,
                                   cameraPos: SIMD3<Float>,
                                   forward: SIMD3<Float>) -> String {
        let mesh      = anchor.geometry
        let faceCount = mesh.faces.count
        guard faceCount > 0 else { return "unknown" }
        guard let classifications = mesh.classification else { return "unknown" }
        let classPtr = classifications.buffer.contents().assumingMemoryBound(to: UInt8.self)

        let priority: [ARMeshClassification: Int] = [
            .door: 6, .window: 5, .wall: 4, .ceiling: 3, .floor: 2
        ]
        var best: ARMeshClassification = .none, bestP = 0
        let step = max(1, faceCount / 200)
        var i = 0
        while i < faceCount {
            let raw = Int(classPtr[i])
            if let cls = ARMeshClassification(rawValue: raw) {
                let p = priority[cls] ?? 0
                if p > bestP { bestP = p; best = cls }
            }
            i += step
        }
        switch best {
        case .wall:    return "wall"
        case .floor:   return "floor"
        case .ceiling: return "ceiling"
        case .door:    return "door"
        case .window:  return "window"
        case .seat:    return "seat"
        case .table:   return "table"
        case .none:    return "open"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Opening detection

extension ARSceneAnalyzer {

    private func detectOpening(frame: ARFrame) -> Double? {
        guard isLiDAR else { return nil }
        let cam    = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let fwd    = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)

        for anchor in frame.anchors {
            if let plane = anchor as? ARPlaneAnchor, plane.classification == .door {
                let ap   = SIMD3<Float>(plane.transform.columns.3.x,
                                        plane.transform.columns.3.y,
                                        plane.transform.columns.3.z)
                let diff = ap - camPos
                let dist = simd_length(diff)
                guard dist < 5.0, dist > 0 else { continue }
                let angle = acos(min(1, max(-1, simd_dot(simd_normalize(diff), fwd)))) * 180 / Float.pi
                guard angle < 45 else { continue }
                return compassBearing(to: ap, from: camPos)
            }
            if let mesh = anchor as? ARMeshAnchor {
                let ap   = SIMD3<Float>(mesh.transform.columns.3.x,
                                        mesh.transform.columns.3.y,
                                        mesh.transform.columns.3.z)
                guard simd_distance(camPos, ap) < 5.0 else { continue }
                if sampledMeshLabel(mesh, cameraPos: camPos, forward: fwd) == "door" {
                    return compassBearing(to: ap, from: camPos)
                }
            }
        }
        return nil
    }

    private func compassBearing(to target: SIMD3<Float>, from origin: SIMD3<Float>) -> Double {
        let dx = Double(target.x - origin.x)
        let dz = Double(target.z - origin.z)
        let arBearing = atan2(dx, -dz) * 180 / .pi
        return (arBearing + headingDegrees + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - CLLocationManagerDelegate

extension ARSceneAnalyzer: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentCoordinate = locations.last?.coordinate
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse ||
           manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }
}
