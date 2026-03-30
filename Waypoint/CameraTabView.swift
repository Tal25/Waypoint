import SwiftUI
import ARKit
import AVFoundation
import UIKit

// MARK: - CameraTabView

struct CameraTabView: View {

    let vm: NavigationViewModel

    @StateObject private var analyzer     = ARSceneAnalyzer()
    @StateObject private var cameraAudio  = CameraAudioFeedback()

    @State private var audioFeedbackEnabled = true
    @State private var showDebug            = false
    @State private var cameraPermission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    // Threshold crossing tracking for accessibility notifications
    @State private var prevThresholdBucket: Int = 0   // 0=clear, 1=near, 2=veryClose

    var body: some View {
        Group {
            switch cameraPermission {
            case .authorized:
                cameraContent
            case .denied, .restricted:
                permissionDeniedView
            default:
                permissionDeniedView   // .notDetermined — request happens in onAppear
            }
        }
        .onAppear {
            requestCameraPermissionIfNeeded()
        }
    }

    // MARK: - Main camera content

    private var cameraContent: some View {
        ZStack {
            // ── Layer 1: AR camera feed (full screen) ──────────────────
            ARViewContainer(session: analyzer.session, showDebug: showDebug)
                .ignoresSafeArea(.all)

            // ── Layer 2: HUD overlay ───────────────────────────────────
            VStack(spacing: 0) {
                topInfoPanel
                    .padding(.top, 52)
                    .padding(.horizontal, 12)

                Spacer()

                // Crosshair
                crosshair

                Spacer()

                proximitySection
                    .padding(.bottom, 8)

                controlStrip
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            analyzer.headingDegrees = vm.compassHeading
            analyzer.startSession()
            cameraAudio.start()
        }
        .onDisappear {
            analyzer.pauseSession()
            cameraAudio.stop()
        }
        .onChange(of: vm.compassHeading) { heading in
            analyzer.headingDegrees = heading
        }
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

    // MARK: - Top info panel

    private var topInfoPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            infoRow(label: "Tracking", value: analyzer.trackingState,
                    valueColor: trackingColor)
            infoRow(label: "Depth",    value: analyzer.depthMode,
                    valueColor: analyzer.depthMode == "LiDAR" ? .blue : .orange)
            infoRow(label: "Ahead",    value: String(format: "%.1f ft", analyzer.obstacleDistanceFt),
                    valueColor: obstacleColor, monospaced: true)
            infoRow(label: "Surface",  value: analyzer.surfaceClassification,
                    valueColor: .white)
            infoRow(label: "GPS",      value: gpsAccuracyText,
                    valueColor: gpsColor)
            if analyzer.thermalWarning {
                thermalWarningRow
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.60))
        .cornerRadius(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combinedAccessibilityLabel)
        .accessibilityValue(combinedAccessibilityLabel)
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
            .opacity(1)   // caller can add animation if desired
    }

    // MARK: - Crosshair

    private var crosshair: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.80))
                .frame(width: 40, height: 1)
            Rectangle()
                .fill(.white.opacity(0.80))
                .frame(width: 1, height: 40)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Proximity section

    private var proximitySection: some View {
        VStack(spacing: 6) {
            // Large distance number
            Text(String(format: "%.1f ft", analyzer.obstacleDistanceFt))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .accessibilityLabel("Obstacle distance")
                .accessibilityValue(String(format: "%.0f feet", analyzer.obstacleDistanceFt))

            // Proximity bar
            proximityBar
        }
    }

    private var proximityBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Rectangle()
                    .fill(.white.opacity(0.20))
                    .frame(height: 8)

                // Fill
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
            let utterance = AVSpeechUtterance(
                string: "Camera access required. Go to Settings to enable camera."
            )
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate  = 0.52
            AVSpeechSynthesizer().speak(utterance)
        }
    }

    // MARK: - Accessibility

    private var combinedAccessibilityLabel: String {
        let dist     = String(format: "%.1f", analyzer.obstacleDistanceFt)
        let gpsStr   = gpsAccuracyText
        return "Tracking \(analyzer.trackingState.lowercased()). "
            + "\(analyzer.depthMode) depth active. "
            + "Obstacle \(dist) feet ahead. "
            + "Surface \(analyzer.surfaceClassification). "
            + "GPS \(gpsStr)."
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
        case "Normal":        return .green
        case "Limited":       return .yellow
        default:              return .red
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
        let ft = Int((acc * 3.28084).rounded())
        return "±\(ft) ft"
    }

    private var gpsColor: Color {
        let acc = vm.gpsAccuracy
        guard acc >= 0 else { return .red }
        let ft = acc * 3.28084
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
