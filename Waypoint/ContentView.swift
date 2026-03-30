import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = NavigationViewModel()
    @State private var welcomeSpoken = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.04, blue: 0.10),
                         Color(red: 0.07, green: 0.09, blue: 0.18)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Subtle glow behind compass
            Circle()
                .fill(
                    RadialGradient(colors: [Color.cyan.opacity(0.12), .clear],
                                   center: .center, startRadius: 0, endRadius: 180)
                )
                .frame(width: 360, height: 360)
                .offset(y: 40)

            VStack(spacing: 0) {

                // ── Status card ─────────────────────────────────────────
                statusCard
                    .padding(.top, 60)
                    .padding(.horizontal, 24)

                Spacer()

                // ── Compass ─────────────────────────────────────────────
                CompassView(
                    heading: vm.compassHeading,
                    relativeBearing: vm.relativeBearing,
                    isNavigating: vm.isNavigating
                )

                // ── Distance ────────────────────────────────────────────
                distanceDisplay
                    .padding(.top, 28)

                Spacer()

                // ── Pan visualiser (sighted companion) ──────────────────
                PanVisualiserView(panValue: vm.audio.isPanning)
                    .frame(height: 24)
                    .padding(.horizontal, 48)
                    .accessibilityHidden(true)
                    .padding(.bottom, 12)

                // ── GPS pill ────────────────────────────────────────────
                GPSPill(accuracy: vm.gpsAccuracy)
                    .accessibilityLabel(gpsLabel)
                    .padding(.bottom, 28)

                // ── Bottom action ───────────────────────────────────────
                if vm.isNavigating {
                    stopButton
                } else {
                    tapToStartArea
                }
            }
            .padding(.bottom, 48)
        }
        // Tap anywhere to start (when not navigating)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !vm.isNavigating else { return }
            if vm.isGPSReady {
                vm.startNavigation()
            } else {
                vm.audio.speak("Waiting for GPS signal.")
            }
        }
        .onAppear {
            vm.requestPermissions()
            if !welcomeSpoken {
                welcomeSpoken = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    vm.audio.speak("Press anywhere on the screen to start navigation.")
                }
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 2) {
                Text("Destination")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(1.2)
                    .textCase(.uppercase)
                Text(vm.statusMessage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(vm.statusMessage)")
    }

    // MARK: - Distance display

    private var distanceDisplay: some View {
        VStack(spacing: 6) {
            Text(formattedDistance)
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.25), value: formattedDistance)
                .accessibilityLabel("Distance: \(formattedDistance)")
                .accessibilityAddTraits(.updatesFrequently)
                .onChange(of: formattedDistance) { _, new in
                    UIAccessibility.post(notification: .announcement,
                                         argument: "Distance: \(new)")
                }

            if vm.distanceMetres > 0 {
                Text("to destination")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Stop button

    private var stopButton: some View {
        Button(action: vm.stopNavigation) {
            HStack(spacing: 10) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 20))
                Text("Stop Navigation")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 64)
            .background(Color.red.opacity(0.75))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
            )
        }
        .padding(.horizontal, 32)
        .accessibilityLabel("Stop navigation")
        .accessibilityHint("Double tap to stop audio guidance")
        .accessibilitySortPriority(1000)
    }

    // MARK: - Tap to start

    private var tapToStartArea: some View {
        VStack(spacing: 10) {
            if !vm.isGPSReady {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.white.opacity(0.5))
                        .scaleEffect(0.85)
                    Text("Acquiring GPS signal…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            } else {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.25))
                Text("Tap anywhere to start")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }

    // MARK: - Helpers

    private var formattedDistance: String {
        let feet = vm.distanceMetres * 3.28084
        guard feet > 0 else { return "---" }
        if feet >= 1000 {
            let miles = feet / 5280
            return String(format: "%.1f mi", miles)
        }
        return String(format: "%.0f ft", feet)
    }

    private var gpsLabel: String {
        let a = vm.gpsAccuracy
        if a < 0  { return "GPS: no signal" }
        if a < 10 { return "GPS: excellent, ±\(Int(a)) metres" }
        if a < 20 { return "GPS: good, ±\(Int(a)) metres" }
        return "GPS: low accuracy, ±\(Int(a)) metres"
    }
}

// MARK: - Compass

struct CompassView: View {
    let heading: Double
    let relativeBearing: Double
    let isNavigating: Bool

    private let cardinals: [(String, Double)] = [("N", 0), ("E", 90), ("S", 180), ("W", 270)]

    var body: some View {
        ZStack {
            // Glass ring
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1.5))

            // Tick marks (rotate with heading so N stays north)
            ForEach(0..<72, id: \.self) { i in
                let isMajor = i % 18 == 0
                Rectangle()
                    .fill(.white.opacity(isMajor ? 0.55 : 0.18))
                    .frame(width: isMajor ? 2 : 1, height: isMajor ? 10 : 5)
                    .offset(y: -76)
                    .rotationEffect(.degrees(Double(i) * 5 - heading))
            }

            // Cardinal labels
            ForEach(cardinals, id: \.0) { label, angle in
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(label == "N" ? Color.red : Color.white.opacity(0.65))
                    .offset(y: -58)
                    .rotationEffect(.degrees(angle - heading))
            }

            // Inner dark circle
            Circle()
                .fill(Color(white: 0.06).opacity(0.8))
                .frame(width: 110, height: 110)

            // Needle
            if isNavigating {
                // Cyan arrow toward destination
                NavigationNeedle()
                    .rotationEffect(.degrees(relativeBearing))
                    .shadow(color: .cyan.opacity(0.7), radius: 10)
            } else {
                // Red/white north needle
                NorthNeedle()
                    .rotationEffect(.degrees(-heading))
            }

            // Centre dot
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
                .shadow(color: .white.opacity(0.6), radius: 5)
        }
        .frame(width: 180, height: 180)
        .accessibilityHidden(true)
    }
}

// MARK: - Needles

struct NavigationNeedle: View {
    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color.cyan)
                .frame(width: 14, height: 22)
            Rectangle()
                .fill(Color.cyan.opacity(0.5))
                .frame(width: 2.5, height: 16)
            Triangle()
                .fill(Color.white.opacity(0.18))
                .rotationEffect(.degrees(180))
                .frame(width: 12, height: 16)
        }
    }
}

struct NorthNeedle: View {
    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Color.red)
                .frame(width: 12, height: 20)
            Rectangle()
                .fill(Color.red.opacity(0.4))
                .frame(width: 2, height: 14)
            Triangle()
                .fill(Color.white.opacity(0.2))
                .rotationEffect(.degrees(180))
                .frame(width: 12, height: 14)
        }
    }
}

// MARK: - Triangle shape

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Pan Visualiser

struct PanVisualiserView: View {
    let panValue: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(0.08))
                    .frame(height: 6)
                    .padding(.vertical, 9)

                Circle()
                    .fill(.white.opacity(0.6))
                    .frame(width: 16, height: 16)
                    .offset(x: dotX(width: geo.size.width))
                    .animation(.easeOut(duration: 0.1), value: panValue)
            }
        }
    }

    private func dotX(width: CGFloat) -> CGFloat {
        let centre = (width - 16) / 2
        return centre + CGFloat(panValue) * ((width - 16) / 2)
    }
}

// MARK: - GPS Pill

struct GPSPill: View {
    let accuracy: Double

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var dotColor: Color {
        if accuracy < 0  { return .gray }
        if accuracy < 10 { return .green }
        if accuracy < 20 { return Color(red: 1, green: 0.8, blue: 0) }
        return .red
    }

    private var label: String {
        accuracy < 0 ? "No GPS" : String(format: "±%.0f m", accuracy)
    }
}

#Preview {
    ContentView()
}
