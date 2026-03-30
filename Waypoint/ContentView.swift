import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = NavigationViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // ── Distance display ──────────────────────────────────────
                VStack(spacing: 10) {
                    Text(formattedDistance)
                        .font(.system(size: 80, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.35)
                        .lineLimit(1)
                        .padding(.horizontal, 24)
                        .accessibilityLabel("Distance to destination: \(formattedDistance)")
                        .accessibilityAddTraits(.updatesFrequently)
                        .onChange(of: formattedDistance) { _ in
                            UIAccessibility.post(notification: .announcement,
                                                 argument: "Distance: \(formattedDistance)")
                        }

                    Text(vm.statusMessage)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .accessibilityLabel(vm.statusMessage)
                }
                .padding(.top, 72)

                Spacer()

                // ── Stereo pan visualiser (sighted companion only) ────────
                PanVisualiserView(panValue: vm.audio.isPanning)
                    .frame(height: 28)
                    .padding(.horizontal, 40)
                    .accessibilityHidden(true)
                    .padding(.bottom, 16)

                // ── GPS accuracy ──────────────────────────────────────────
                GPSAccuracyView(accuracy: vm.gpsAccuracy)
                    .accessibilityLabel(gpsAccessibilityLabel)
                    .padding(.bottom, 32)

                // ── Start / Stop button ───────────────────────────────────
                Button(action: toggleNavigation) {
                    Text(vm.isNavigating ? "Stop" : "Start")
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 80)
                        .background(vm.isNavigating ? Color.red : Color(red: 0.2, green: 0.9, blue: 0.4))
                        .cornerRadius(22)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 56)
                // Make this the first VoiceOver element on screen
                .accessibilityLabel(vm.isNavigating ? "Stop navigation" : "Start navigation")
                .accessibilityHint(vm.isNavigating
                    ? "Double tap to stop audio guidance"
                    : "Double tap to begin audio guidance to destination")
                .accessibilitySortPriority(1000)
                .accessibilityAddTraits(.isButton)
            }
        }
        .onAppear {
            vm.requestPermissions()
        }
    }

    // MARK: - Helpers

    private var formattedDistance: String {
        let d = vm.distanceMetres
        guard d > 0 else { return "---" }
        return d >= 1000
            ? String(format: "%.1f km", d / 1000)
            : String(format: "%.0f m", d)
    }

    private var gpsAccessibilityLabel: String {
        let a = vm.gpsAccuracy
        if a < 0   { return "GPS: no signal" }
        if a < 10  { return "GPS: excellent, plus or minus \(Int(a)) metres" }
        if a < 30  { return "GPS: good, plus or minus \(Int(a)) metres" }
        return "GPS: low accuracy, plus or minus \(Int(a)) metres"
    }

    private func toggleNavigation() {
        vm.isNavigating ? vm.stopNavigation() : vm.startNavigation()
    }
}

// MARK: - Pan Visualiser

struct PanVisualiserView: View {
    let panValue: Float  // -1 (left) … 0 (centre) … 1 (right)

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)

                // Dot
                Circle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 18, height: 18)
                    .offset(x: dotX(width: geo.size.width))
            }
        }
    }

    private func dotX(width: CGFloat) -> CGFloat {
        let centre = (width - 18) / 2
        let range  = (width - 18) / 2
        return centre + CGFloat(panValue) * range
    }
}

// MARK: - GPS Accuracy Indicator

struct GPSAccuracyView: View {
    let accuracy: Double

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 11, height: 11)
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color.white.opacity(0.5))
        }
    }

    private var dotColor: Color {
        if accuracy < 0  { return .gray }
        if accuracy < 10 { return .green }
        if accuracy < 30 { return Color(red: 1, green: 0.8, blue: 0) }
        return .red
    }

    private var label: String {
        accuracy < 0
            ? "No GPS"
            : String(format: "±%.0f m", accuracy)
    }
}

#Preview {
    ContentView()
}
