import ARKit
import CoreLocation
import Vision
import AVFoundation
import Combine

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

    // MARK: - Public session (shared with ARViewContainer)
    let session = ARSession()

    // MARK: - State settable from CameraTabView
    var headingDegrees: Double = 0   // updated from NavigationViewModel.compassHeading

    // MARK: - Private
    private var isLiDAR = false
    private var savedConfig: ARWorldTrackingConfiguration?
    private var occupancyGrid = OccupancyGrid()
    private let analysisQueue = DispatchQueue(label: "ar.analysis", qos: .userInitiated)
    private var lastAnalysisTime: Date = .distantPast
    private var analysisInterval: TimeInterval = 0.5   // 2 fps nominal
    private var thermalState: ProcessInfo.ThermalState = .nominal

    // Own CLLocationManager for micro-waypoint generation only
    private let locationManager = CLLocationManager()
    private var currentCoordinate: CLLocationCoordinate2D?

    private let speech = AVSpeechSynthesizer()

    // MARK: - Init

    override init() {
        super.init()
        session.delegate = self

        // Minimal location access — we only need the last known coordinate
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
        guard ARWorldTrackingConfiguration.isSupported else {
            print("[ARSceneAnalyzer] ARWorldTrackingConfiguration not supported on this device.")
            return
        }

        let config = ARWorldTrackingConfiguration()
        config.planeDetection       = [.horizontal, .vertical]
        config.environmentTexturing = .none

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
            config.frameSemantics      = [.smoothedSceneDepth]
            isLiDAR = true
            DispatchQueue.main.async { self.depthMode = "LiDAR" }
            print("[ARSceneAnalyzer] LiDAR + mesh reconstruction enabled.")
        } else {
            isLiDAR = false
            DispatchQueue.main.async { self.depthMode = "Estimated" }
            print("[ARSceneAnalyzer] No LiDAR — running with plane detection only.")
        }

        savedConfig = config
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        locationManager.startUpdatingLocation()

        DispatchQueue.main.async {
            self.isSessionRunning = true
            self.trackingState    = "Limited"
        }
        print("[ARSceneAnalyzer] Session started.")
    }

    func pauseSession() {
        session.pause()
        locationManager.stopUpdatingLocation()
        DispatchQueue.main.async {
            self.isSessionRunning = false
            self.trackingState    = "Not Available"
        }
        print("[ARSceneAnalyzer] Session paused.")
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
            print("[ARSceneAnalyzer] Thermal: serious — reduced to 1 fps.")
        case .critical:
            analysisInterval = 999   // effectively paused
            DispatchQueue.main.async { self.thermalWarning = true }
            speak("Pausing camera to cool down.")
            print("[ARSceneAnalyzer] Thermal: critical — analysis paused.")
        @unknown default:
            break
        }
    }

    // MARK: - Speech

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate  = 0.52
        speech.speak(utterance)
    }
}

// MARK: - ARSessionDelegate

extension ARSceneAnalyzer: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Thermal critical → drop all frames
        guard thermalState != .critical else { return }

        // Rate limiting: cap at analysisInterval
        let now = Date()
        guard now.timeIntervalSince(lastAnalysisTime) >= analysisInterval else { return }
        lastAnalysisTime = now

        // Publish tracking state
        let stateString = trackingStateLabel(frame.camera.trackingState)
        DispatchQueue.main.async { self.trackingState = stateString }

        // All heavy work on the background analysis queue
        analysisQueue.async { [weak self] in
            self?.analyzeFrame(frame)
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async { self.trackingState = "Not Available" }
        print("[ARSceneAnalyzer] Session error: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.trackingState = "Limited" }
    }

    private func trackingStateLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:         return "Normal"
        case .limited:        return "Limited"
        case .notAvailable:   return "Not Available"
        @unknown default:     return "Not Available"
        }
    }
}

// MARK: - Frame analysis pipeline

extension ARSceneAnalyzer {

    private func analyzeFrame(_ frame: ARFrame) {
        // ── Step 1: Obstacle distance ──────────────────────────────────────
        let distanceFt: Double
        if isLiDAR {
            distanceFt = lidarObstacleDistance(frame: frame)
        } else {
            distanceFt = estimatedObstacleDistance(frame: frame)
        }

        // ── Step 2: Surface classification ────────────────────────────────
        let surface = classifySurface(frame: frame)

        // ── Step 3: Opening detection ──────────────────────────────────────
        let opening = detectOpening(frame: frame)

        // ── Step 4: Micro-waypoint ─────────────────────────────────────────
        let waypoint = generateMicroWaypoint(openingBearing: opening)

        // ── Step 5: Occupancy grid (isolated — not yet wired to navigation) ─
        updateOccupancyGrid(frame)

        DispatchQueue.main.async { [weak self] in
            self?.obstacleDistanceFt       = distanceFt
            self?.surfaceClassification    = surface
            self?.openingBearing           = opening
            self?.suggestedMicroWaypoint   = waypoint
        }
    }

    // MARK: LiDAR depth sampling

    private func lidarObstacleDistance(frame: ARFrame) -> Double {
        guard let depthMap = frame.smoothedSceneDepth?.depthMap else { return 30.0 }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return 30.0 }
        let buf = base.assumingMemoryBound(to: Float32.self)

        // 30-degree half-angle cone centred on image
        let tanHalf  = tan(15.0 * Double.pi / 180.0)
        let coneW    = Int(Double(width)  * tanHalf)
        let coneH    = Int(Double(height) * tanHalf)
        let cx = width  / 2
        let cy = height / 2

        let x0 = max(0, cx - coneW);  let x1 = min(width,  cx + coneW)
        let y0 = max(0, cy - coneH);  let y1 = min(height, cy + coneH)

        var samples = [Float32]()
        samples.reserveCapacity(500)

        // Sample every 4th pixel to stay fast
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
        let nearestM = Double(samples[idx])
        return max(0, min(30.0, nearestM * 3.28084))
    }

    // MARK: Vision estimated depth (non-LiDAR)

    private func estimatedObstacleDistance(frame: ARFrame) -> Double {
        // Use plane anchor distance as a proxy — find the nearest horizontal/vertical
        // plane in the forward arc and return its distance in feet.
        let cam   = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let fwd    = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)

        var nearest: Float = 30.0 / 3.28084   // 30 ft in metres
        for anchor in frame.anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let ap = SIMD3<Float>(plane.transform.columns.3.x,
                                  plane.transform.columns.3.y,
                                  plane.transform.columns.3.z)
            let toPlane = ap - camPos
            let dist    = simd_length(toPlane)
            // Only planes roughly ahead (dot product > 0)
            guard dist < nearest, simd_dot(simd_normalize(toPlane), fwd) > 0.3 else { continue }
            nearest = dist
        }
        // Scale by 0.6 to reflect lower confidence (as per spec)
        let confidenceScaled = Double(nearest) * 0.6
        return max(0, min(30.0, confidenceScaled * 3.28084))
    }

    // MARK: Surface classification

    private func classifySurface(frame: ARFrame) -> String {
        let cam    = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let fwd    = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)

        // Priority: door > window > wall > ceiling > floor > other > unknown
        let priority: [String: Int] = [
            "door": 6, "window": 5, "wall": 4,
            "ceiling": 3, "floor": 2, "open": 1
        ]

        var best      = "unknown"
        var bestScore = 0

        // ARPlaneAnchor.classification is efficient — one value per detected plane
        for anchor in frame.anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            let ap   = SIMD3<Float>(plane.transform.columns.3.x,
                                    plane.transform.columns.3.y,
                                    plane.transform.columns.3.z)
            let diff = ap - camPos
            let dist = simd_length(diff)
            guard dist < 10.0 else { continue }   // within 10 m
            guard dist > 0 else { continue }

            // Within 45 degrees of forward
            let dot   = simd_dot(simd_normalize(diff), fwd)
            let angle = acos(min(1, max(-1, dot))) * 180 / Float.pi
            guard angle < 45 else { continue }

            let label = planeClassificationLabel(plane.classification)
            let score = priority[label] ?? 0
            if score > bestScore {
                bestScore = score
                best      = label
            }
        }

        // LiDAR: supplement with mesh face classifications for nearby anchors
        if isLiDAR {
            for anchor in frame.anchors {
                guard let mesh = anchor as? ARMeshAnchor else { continue }
                let ap   = SIMD3<Float>(mesh.transform.columns.3.x,
                                        mesh.transform.columns.3.y,
                                        mesh.transform.columns.3.z)
                let dist = simd_distance(camPos, ap)
                guard dist < 5.0 else { continue }

                let label = sampledMeshClassification(mesh, cameraPos: camPos, forward: fwd)
                let score = priority[label] ?? 0
                if score > bestScore {
                    bestScore = score
                    best      = label
                }
            }
        }

        return best
    }

    private func planeClassificationLabel(_ c: ARPlaneAnchor.Classification) -> String {
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

    /// Sample a fraction of mesh faces — never iterate all faces (could be millions)
    private func sampledMeshClassification(_ anchor: ARMeshAnchor,
                                           cameraPos: SIMD3<Float>,
                                           forward: SIMD3<Float>) -> String {
        let mesh      = anchor.geometry
        let faceCount = mesh.faces.count
        guard faceCount > 0 else { return "unknown" }

        guard let classifications = mesh.classification else { return "unknown" }
        let classPtr = classifications.buffer.contents()
            .assumingMemoryBound(to: UInt8.self)

        let priority: [ARMeshClassification: Int] = [
            .door: 6, .window: 5, .wall: 4,
            .ceiling: 3, .floor: 2
        ]

        var best:  ARMeshClassification = .none
        var bestP  = 0

        // Sample every 200th face for performance
        let step = max(1, faceCount / 200)
        var i    = 0
        while i < faceCount {
            let raw   = Int(classPtr[i])
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

    // MARK: Opening detection

    private func detectOpening(frame: ARFrame) -> Double? {
        guard isLiDAR else { return nil }

        let cam    = frame.camera.transform
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let fwd    = SIMD3<Float>(-cam.columns.2.x, -cam.columns.2.y, -cam.columns.2.z)

        // Look for door planes / mesh faces within 5 m, within 45 degrees of forward
        for anchor in frame.anchors {
            // Check ARPlaneAnchor door classification first
            if let plane = anchor as? ARPlaneAnchor,
               plane.classification == .door {
                let ap   = SIMD3<Float>(plane.transform.columns.3.x,
                                        plane.transform.columns.3.y,
                                        plane.transform.columns.3.z)
                let diff = ap - camPos
                let dist = simd_length(diff)
                guard dist < 5.0, dist > 0 else { continue }
                let dot   = simd_dot(simd_normalize(diff), fwd)
                let angle = acos(min(1, max(-1, dot))) * 180 / Float.pi
                guard angle < 45 else { continue }

                // Convert 3D position to compass bearing
                return compassBearing(to: ap, from: camPos)
            }

            // Also check mesh anchors for door faces
            if let mesh = anchor as? ARMeshAnchor {
                let ap   = SIMD3<Float>(mesh.transform.columns.3.x,
                                        mesh.transform.columns.3.y,
                                        mesh.transform.columns.3.z)
                let dist = simd_distance(camPos, ap)
                guard dist < 5.0 else { continue }

                let classification = sampledMeshClassification(mesh, cameraPos: camPos, forward: fwd)
                if classification == "door" {
                    return compassBearing(to: ap, from: camPos)
                }
            }
        }
        return nil
    }

    /// Convert an ARKit world-space position to an approximate compass bearing.
    private func compassBearing(to target: SIMD3<Float>, from origin: SIMD3<Float>) -> Double {
        let dx = Double(target.x - origin.x)
        let dz = Double(target.z - origin.z)
        // ARKit: +X right, -Z forward. Convert to compass bearing.
        let arBearing = atan2(dx, -dz) * 180 / .pi
        // Add current compass heading to convert AR-space to world compass bearing
        return (arBearing + headingDegrees + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: Micro-waypoint generation

    private func generateMicroWaypoint(openingBearing: Double?) -> CLLocationCoordinate2D? {
        guard let coord = currentCoordinate else { return nil }

        let bearing  = openingBearing ?? headingDegrees
        let distance = openingBearing != nil ? 2.0 : 1.0  // metres
        let bearRad  = bearing * .pi / 180

        let latOffset = (distance / 111_111.0) * cos(bearRad)
        let lngOffset = (distance / (111_111.0 * cos(coord.latitude * .pi / 180))) * sin(bearRad)

        return CLLocationCoordinate2D(
            latitude:  coord.latitude  + latOffset,
            longitude: coord.longitude + lngOffset
        )
    }
}

// MARK: - Occupancy grid population

extension ARSceneAnalyzer {

    /// Rebuild the occupancy grid from the current frame's mesh anchors.
    /// Grid is centred on the camera. Called on analysisQueue; publishes result to main.
    /// NOT yet wired to navigation — inspect `latestGrid` to verify correctness.
    private func updateOccupancyGrid(_ frame: ARFrame) {
        let cam   = frame.camera.transform
        let camX  = cam.columns.3.x
        let camY  = cam.columns.3.y
        let camZ  = cam.columns.3.z
        let fwdX  = -cam.columns.2.x
        let fwdZ  = -cam.columns.2.z

        occupancyGrid.reset(cameraX: camX, cameraZ: camZ)

        // Non-LiDAR: no mesh data — publish empty grid and return
        guard isLiDAR else {
            let g = occupancyGrid
            DispatchQueue.main.async { self.latestGrid = g }
            return
        }

        // Obstacle height band relative to camera
        // Camera is typically ~1.5 m above floor, so:
        //   floor  ≈ camY − 1.7   (give 0.2 m margin below camera − 1.5)
        //   head   ≈ camY + 0.3
        let floorY = camY - 1.7
        let headY  = camY + 0.3

        for anchor in frame.anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }

            // Skip anchors more than 6 m away (cheap pre-filter)
            let ax = mesh.transform.columns.3.x
            let az = mesh.transform.columns.3.z
            let dx = ax - camX;  let dz = az - camZ
            guard dx * dx + dz * dz < 36 else { continue }

            let geo      = mesh.geometry.vertices
            let count    = geo.count
            guard count > 0 else { continue }

            let stride   = geo.stride
            let offset   = geo.offset
            let buf      = geo.buffer.contents()
            let xform    = mesh.transform

            // Sample at most ~300 vertices per anchor for performance
            let step = max(1, count / 300)
            var i    = 0
            while i < count {
                let ptr = buf.advanced(by: offset + i * stride)
                             .assumingMemoryBound(to: Float.self)
                let lx = ptr[0];  let ly = ptr[1];  let lz = ptr[2]

                // Local → world (manual SIMD4 multiply, avoids importing simd)
                let wx = xform.columns.0.x * lx + xform.columns.1.x * ly
                       + xform.columns.2.x * lz + xform.columns.3.x
                let wy = xform.columns.0.y * lx + xform.columns.1.y * ly
                       + xform.columns.2.y * lz + xform.columns.3.y
                let wz = xform.columns.0.z * lx + xform.columns.1.z * ly
                       + xform.columns.2.z * lz + xform.columns.3.z

                if wy > floorY + 0.15 && wy < headY {
                    occupancyGrid.mark(x: wx, z: wz, as: .occupied)
                } else if wy <= floorY + 0.15 {
                    occupancyGrid.mark(x: wx, z: wz, as: .free)
                }

                i += step
            }
        }

        // Log clearest path for isolation testing (remove once wired to navigation)
        if let angle = occupancyGrid.clearestForwardBearing(forwardX: fwdX, forwardZ: fwdZ) {
            let dir = angle > 1 ? "right" : angle < -1 ? "left" : "straight"
            print("[OccupancyGrid] clearest: \(Int(angle))° (\(dir)) | "
                  + "occupied=\(occupancyGrid.occupiedCount) free=\(occupancyGrid.freeCount)")
        }

        let g = occupancyGrid
        DispatchQueue.main.async { self.latestGrid = g }
    }
}

// MARK: - CLLocationManagerDelegate (coordinate only)

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
