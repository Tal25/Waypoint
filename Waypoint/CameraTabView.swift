import SwiftUI
import ARKit
import AVFoundation
import UIKit

// MARK: - CameraTabView

struct CameraTabView: View {

    let vm: NavigationViewModel

    @StateObject private var analyzer    = ARSceneAnalyzer()
    @StateObject private var cameraAudio = CameraAudioFeedback()

    @State private var audioFeedbackEnabled = true
    @State private var showDebug            = false
    @State private var cameraPermission: AVAuthorizationStatus =
        AVCaptureDevice.authorizationStatus(for: .video)
    @State private var prevThresholdBucket: Int = 0

    var body: some View {
        Group {
            switch cameraPermission {
            case .authorized:
                cameraContent
            case .denied, .restricted:
                permissionDeniedView
            default:
                permissionDeniedView
            }
        }
        .onAppear { requestCameraPermissionIfNeeded() }
    }

    // MARK: - Main camera content

    private var cameraContent: some View {
        ZStack {
            // ── Layer 1: AR camera feed ─────────────────────────────────
            ARViewContainer(session: analyzer.session, showDebug: showDebug)
                .ignoresSafeArea(.all)

            // ── Layer 2: HUD ────────────────────────────────────────────
            VStack(spacing: 0) {
                topInfoPanel
                    .padding(.top, 52)
                    .padding(.horizontal, 12)

                Spacer()

                crosshair

                Spacer()

                proximitySection
                    .padding(.bottom, 8)

                controlStrip
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            // ── Layer 3: Occupancy grid mini-map (bottom-left) ──────────
            VStack {
                Spacer()
                HStack {
                    occupancyGridView
                        .padding(.leading, 12)
                        .padding(.bottom, 100)   // above control strip
                    Spacer()
                }
            }
        }
        .onAppear {
            analyzer.headingDegrees      = vm.compassHeading
            analyzer.userFarFromDestination = vm.distanceMetres > 8.0
            updateDestinationBearing()
            analyzer.startSession()
            cameraAudio.start()
        }
        .onDisappear {
            analyzer.pauseSession()
            cameraAudio.stop()
        }
        // ── Heading + distance → analyzer inputs ────────────────────────
        .onChange(of: vm.compassHeading)  { heading in
            analyzer.headingDegrees = heading
            updateDestinationBearing()
        }
        .onChange(of: vm.relativeBearing) { _ in
            updateDestinationBearing()
        }
        .onChange(of: vm.distanceMetres)  { dist in
            analyzer.userFarFromDestination = dist > 8.0
        }
        // ── Pathfinding output → NavigationViewModel ────────────────────
        .onChange(of: analyzer.suggestedMicroWaypoint) { waypoint in
            if let wp = waypoint {
                vm.setMicroWaypoint(wp)
            } else {
                vm.clearMicroWaypoint()
            }
        }
        // ── Obstacle audio + accessibility ──────────────────────────────
        .onChange(of: analyzer.obstacleDistanceFt) { dist in
            cameraAudio.checkObstacle(distanceFt: dist, audioEnabled: audioFeedbackEnabled)
            postThresholdNotificationIfNeeded(dist)
        }
        .onChange(of: analyzer.surfaceClassification) { surface in
            cameraAudio.checkSurface(surface, audioEnabled: audioFeedbackEnabled)
        }
        .onChange(of: analyzer.thermalWarning) { isHot in
            if isHot { cameraAudio.announceThermalWarning() }
        }
    }

    private func updateDestinationBearing() {
        analyzer.destinationBearing =
            (vm.compassHeading + vm.relativeBearing).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Top info panel

    private var topInfoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow(label: "Tracking", value: analyzer.trackingState,
                    valueColor: trackingColor)
            infoRow(label: "Depth",    value: analyzer.depthMode,
                    valueColor: analyzer.depthMode == "LiDAR" ? .blue : .orange)
            infoRow(label: "Mode",     value: analyzer.pathfindingMode,
                    valueColor: analyzer.pathfindingMode == "Camera path" ? .green : .orange)
            infoRow(label: "Ahead",    value: String(format: "%.1f ft", analyzer.obstacleDistanceFt),
                    valueColor: obstacleColor, monospaced: true)
            infoRow(label: "Next",     value: nextWaypointText,
                    valueColor: .cyan, monospaced: true)
            infoRow(label: "Map",      value: "\(analyzer.freeCellCount) free",
                    valueColor: .white)
            infoRow(label: "Surface",  value: analyzer.surfaceClassification,
                    valueColor: .white)
            infoRow(label: "GPS",      value: gpsAccuracyText,
                    valueColor: gpsColor)
            if analyzer.thermalWarning { thermalWarningRow }
        }
        .padding(12)
        .background(Color.black.opacity(0.60))
        .cornerRadius(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combinedAccessibilityLabel)
        .accessibilityValue(combinedAccessibilityLabel)
    }

    private var nextWaypointText: String {
        let distFt = Double(analyzer.microWaypointDistanceM) * 3.28084
        guard distFt > 0.1 else { return "—" }
        return String(format: "%.1f ft", distFt)
    }

    private func infoRow(label: String, value: String,
                         valueColor: Color, monospaced: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .foregroundStyle(valueColor)
                .font(monospaced
                      ? .system(size: 13, weight: .regular, design: .monospaced)
                      : .system(size: 13, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13, weight: .regular, design: .monospaced))
    }

    private var thermalWarningRow: some View {
        Text("Device hot — reduced processing")
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Crosshair

    private var crosshair: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.80)).frame(width: 40, height: 1)
            Rectangle().fill(.white.opacity(0.80)).frame(width: 1, height: 40)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Proximity section

    private var proximitySection: some View {
        VStack(spacing: 6) {
            Text(String(format: "%.1f ft", analyzer.obstacleDistanceFt))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .accessibilityLabel("Obstacle distance")
                .accessibilityValue(String(format: "%.0f feet", analyzer.obstacleDistanceFt))
            proximityBar
        }
    }

    private var proximityBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.20)).frame(height: 8)
                Rectangle()
                    .fill(obstacleColor)
                    .frame(width: fillWidth(totalWidth: geo.size.width), height: 8)
                    .animation(.linear(duration: 0.15), value: analyzer.obstacleDistanceFt)
            }
            .cornerRadius(4)
        }
        .frame(height: 8)
        .accessibilityLabel("Obstacle proximity")
        .accessibilityValue(proximityAccessibilityValue)
    }

    private func fillWidth(totalWidth: CGFloat) -> CGFloat {
        let dist = analyzer.obstacleDistanceFt
        let fill = 1.0 - min(1.0, max(0.0, (dist - 1.5) / (10.0 - 1.5)))
        return totalWidth * CGFloat(fill)
    }

    // MARK: - Control strip

    private var controlStrip: some View {
        HStack(spacing: 24) {
            Toggle(isOn: $audioFeedbackEnabled) {
                Text("Audio")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            .tint(.cyan)
            .accessibilityLabel("Camera audio feedback")
            .accessibilityHint("Toggles warning clicks and door announcements in camera view")

            #if DEBUG
            Toggle(isOn: $showDebug) {
                Text("Debug")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            .tint(.orange)
            .accessibilityLabel("Show AR feature points")
            #endif
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.50))
        .cornerRadius(10)
    }

    // MARK: - Occupancy grid mini-map

    private var occupancyGridView: some View {
        let side    = OccupancyGrid.side
        let viewPt: CGFloat = 120
        let cellPt  = viewPt / CGFloat(side)
        let grid    = analyzer.latestGrid
        let wpRow   = analyzer.microWaypointGridRow
        let wpCol   = analyzer.microWaypointGridCol
        let isLiDAR = analyzer.depthMode == "LiDAR"
        let center  = OccupancyGrid.radius

        return Canvas { ctx, size in
            // Draw cells
            for row in 0..<side {
                for col in 0..<side {
                    let value = grid.cells[row * side + col]
                    let color: Color
                    switch value {
                    case OccupancyGrid.free:
                        color = isLiDAR ? .green : Color(red: 0.4, green: 0.8, blue: 0.4)
                    case OccupancyGrid.occupied:
                        color = .red
                    default:
                        color = Color(white: 0.15)
                    }
                    let rect = CGRect(x: CGFloat(col) * cellPt,
                                      y: CGFloat(row) * cellPt,
                                      width: cellPt, height: cellPt)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }

            // Micro-waypoint: yellow dot
            if wpRow >= 0, wpCol >= 0 {
                let wx = CGFloat(wpCol) * cellPt + cellPt / 2
                let wy = CGFloat(wpRow) * cellPt + cellPt / 2
                let cx = CGFloat(center) * cellPt + cellPt / 2
                let cy = CGFloat(center) * cellPt + cellPt / 2
                // Line from user to waypoint
                var line = Path()
                line.move(to: CGPoint(x: cx, y: cy))
                line.addLine(to: CGPoint(x: wx, y: wy))
                ctx.stroke(line, with: .color(.yellow.opacity(0.7)), lineWidth: 1)
                // Yellow dot
                ctx.fill(Path(ellipseIn: CGRect(x: wx - 3, y: wy - 3, width: 6, height: 6)),
                         with: .color(.yellow))
            }

            // User: blue dot at grid centre
            let ux = CGFloat(center) * cellPt + cellPt / 2
            let uy = CGFloat(center) * cellPt + cellPt / 2
            ctx.fill(Path(ellipseIn: CGRect(x: ux - 3, y: uy - 3, width: 6, height: 6)),
                     with: .color(.blue))
        }
        .frame(width: viewPt, height: viewPt)
        .background(Color.black.opacity(0.65))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    // MARK: - Permission denied

    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundStyle(.gray)
            Text("Camera access required")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Enable camera in Settings to use AR navigation")
                .font(.system(size: 14))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.white.opacity(0.15))
            .cornerRadius(12)
            .foregroundStyle(.white)
            .accessibilityLabel("Open Settings to enable camera")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            let utt = AVSpeechUtterance(
                string: "Camera access required. Go to Settings to enable camera.")
            utt.voice = AVSpeechSynthesisVoice(language: "en-US")
            utt.rate  = 0.52
            AVSpeechSynthesizer().speak(utt)
        }
    }

    // MARK: - Accessibility

    private var combinedAccessibilityLabel: String {
        let dist = String(format: "%.1f", analyzer.obstacleDistanceFt)
        return "Mode \(analyzer.pathfindingMode). "
             + "Tracking \(analyzer.trackingState.lowercased()). "
             + "\(analyzer.depthMode) depth active. "
             + "Obstacle \(dist) feet ahead. "
             + "Surface \(analyzer.surfaceClassification). "
             + "GPS \(gpsAccuracyText)."
    }

    private var proximityAccessibilityValue: String {
        let d = analyzer.obstacleDistanceFt
        if d > 10 { return "clear" }
        if d > 3  { return "near" }
        return "very close"
    }

    private func postThresholdNotificationIfNeeded(_ dist: Double) {
        let bucket: Int
        if dist > 10      { bucket = 0 }
        else if dist > 6  { bucket = 1 }
        else if dist > 3  { bucket = 2 }
        else              { bucket = 3 }
        if bucket != prevThresholdBucket {
            prevThresholdBucket = bucket
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    // MARK: - Helpers

    private var trackingColor: Color {
        switch analyzer.trackingState {
        case "Normal":  return .green
        case "Limited": return .yellow
        default:        return .red
        }
    }

    private var obstacleColor: Color {
        let d = analyzer.obstacleDistanceFt
        if d > 6 { return .green }
        if d > 3 { return .yellow }
        return .red
    }

    private var gpsAccuracyText: String {
        let acc = vm.gpsAccuracy
        guard acc >= 0 else { return "No signal" }
        return "±\(Int((acc * 3.28084).rounded())) ft"
    }

    private var gpsColor: Color {
        let ft = vm.gpsAccuracy * 3.28084
        guard vm.gpsAccuracy >= 0 else { return .red }
        if ft < 20 { return .green }
        if ft < 50 { return .yellow }
        return .red
    }

    // MARK: - Permission request

    private func requestCameraPermissionIfNeeded() {
        guard cameraPermission == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.cameraPermission = granted ? .authorized : .denied
            }
        }
    }
}
