import AVFoundation
import Combine

// MARK: - AudioNavigationEngine

class AudioNavigationEngine: NSObject, ObservableObject {

    // MARK: - Published
    // Relative bearing as -1…+1 (left–right) for the pan visualiser in ContentView.
    @Published var isPanning: Float = 0

    // MARK: - Audio graph
    private let audioEngine  = AVAudioEngine()
    private let pianoPlayer  = AVAudioPlayerNode()
    private let effectPlayer = AVAudioPlayerNode()
    private let spatialMixer = AVAudioEnvironmentNode()

    // MARK: - Preloaded buffers
    private var pianoBuffer:    AVAudioPCMBuffer?
    private var farBuffer:      AVAudioPCMBuffer?
    private var closerBuffer:   AVAudioPCMBuffer?
    private var obstacleBuffer: AVAudioPCMBuffer?
    private var errorBuffer:    AVAudioPCMBuffer?
    private var successBuffer:  AVAudioPCMBuffer?

    // MARK: - State
    private var isRunning            = false
    private var pianoTargetVol: Float = 0.6
    private var triggeredThresholds: Set<String> = []
    private var lastObstacleTime:    Date = .distantPast
    private var lastErrorTime:       Date = .distantPast
    private var obstacleDuckActive   = false
    private var fadeTimer: Timer?

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Setup
    // ─────────────────────────────────────────────────────────────────────────

    func setup() {
        loadBuffers()
        configureAudioSession()
        buildAudioGraph()
    }

    private func loadBuffers() {
        pianoBuffer    = loadBuffer("ambient_piano_loop")
        farBuffer      = loadBuffer("nav_far")
        closerBuffer   = loadBuffer("nav_closer")
        obstacleBuffer = loadBuffer("nav_obstacle")
        errorBuffer    = loadBuffer("nav_error")
        successBuffer  = loadBuffer("nav_success")
    }

    private func loadBuffer(_ name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            print("[AudioNavigationEngine] ⚠️ Missing: \(name).mp3")
            return nil
        }
        do {
            let file  = try AVAudioFile(forReading: url)
            let count = AVAudioFrameCount(file.length)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: count) else { return nil }
            try file.read(into: buf)
            return buf
        } catch {
            print("[AudioNavigationEngine] ⚠️ Load \(name).mp3: \(error)")
            return nil
        }
    }

    private func configureAudioSession() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default,
                              options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch {
            print("[AudioNavigationEngine] ⚠️ Audio session: \(error)")
        }
    }

    private func buildAudioGraph() {
        audioEngine.attach(pianoPlayer)
        audioEngine.attach(effectPlayer)
        audioEngine.attach(spatialMixer)

        // Piano → spatialMixer (HRTF 3D) → mainMixer → output
        audioEngine.connect(pianoPlayer,  to: spatialMixer,              format: nil)
        audioEngine.connect(spatialMixer, to: audioEngine.mainMixerNode, format: nil)
        // Effects → mainMixer direct (non-spatial, equal in both ears)
        audioEngine.connect(effectPlayer, to: audioEngine.mainMixerNode, format: nil)

        // 3D rendering — must be set after connecting to spatialMixer
        pianoPlayer.renderingAlgorithm = .HRTF
        pianoPlayer.reverbBlend = 0.2
        pianoPlayer.position = AVAudio3DPoint(x: 0, y: 0, z: -1) // straight ahead

        // Environment node
        spatialMixer.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        spatialMixer.distanceAttenuationParameters.maximumDistance = 100
        spatialMixer.distanceAttenuationParameters.referenceDistance = 1
        spatialMixer.distanceAttenuationParameters.rolloffFactor = 1.0

        do {
            try audioEngine.start()
        } catch {
            print("[AudioNavigationEngine] ⚠️ Engine start: \(error)")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Navigation Control
    // ─────────────────────────────────────────────────────────────────────────

    func startNavigation() {
        isRunning            = true
        triggeredThresholds  = []
        obstacleDuckActive   = false
        pianoTargetVol       = 0.6
        startPianoLoop()
    }

    func stopNavigation() {
        isRunning = false
        fadePiano(to: 0, duration: 0.8) {
            self.pianoPlayer.stop()
            self.effectPlayer.stop()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Live Update
    //
    // Called by NavigationViewModel on every location and heading change.
    // relativeBearingDegrees is 0–360 (0 = straight ahead).
    // ─────────────────────────────────────────────────────────────────────────

    func update(distanceMetres: Double, relativeBearingDegrees: Double) {
        guard isRunning else { return }

        // Normalise to −180…+180
        var rel = relativeBearingDegrees
        if rel > 180 { rel -= 360 }

        // Update pan visualiser (left-right indicator in UI)
        let panVal = Float(max(-1.0, min(1.0, rel / 90.0)))
        DispatchQueue.main.async { self.isPanning = panVal }

        // 3D piano position in listener space.
        // Listener faces −Z (AVAudioEnvironmentNode default forward).
        // x = sin(angle) → left/right, z = −cos(angle) → forward/behind.
        let angle = rel * .pi / 180.0
        let scale = Float(max(1.0, distanceMetres / 10.0))
        pianoPlayer.position = AVAudio3DPoint(
            x: Float(sin(angle)) * scale,
            y: 0,
            z: Float(-cos(angle)) * scale
        )

        updateDistanceBracket(distanceMetres)
    }

    private func updateDistanceBracket(_ d: Double) {
        let vol:   Float
        let key:   String?
        let sound: AVAudioPCMBuffer?

        switch d {
        case ..<3:
            vol = 1.0;  key = "3";   sound = closerBuffer
        case 3..<10:
            vol = 1.0;  key = "10";  sound = closerBuffer
        case 10..<20:
            vol = 0.85; key = "20";  sound = closerBuffer
        case 20..<50:
            vol = 0.75; key = "50";  sound = closerBuffer
        case 50..<100:
            vol = 0.75; key = nil;   sound = nil
        default:  // ≥100 m
            vol = 0.6;  key = "far"; sound = farBuffer
        }

        if !obstacleDuckActive {
            pianoTargetVol = vol
            pianoPlayer.volume = vol
        } else {
            pianoTargetVol = vol   // remembered; restored after duck ends
        }

        if let k = key, !triggeredThresholds.contains(k), let buf = sound {
            triggeredThresholds.insert(k)
            playEffect(buf)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Arrival
    // ─────────────────────────────────────────────────────────────────────────

    func playArrivalChime() {
        isRunning = false
        fadePiano(to: 0, duration: 1.5) { [weak self] in
            guard let self = self else { return }
            self.pianoPlayer.stop()
            self.effectPlayer.stop()
            if let buf = self.successBuffer {
                self.effectPlayer.scheduleBuffer(buf, at: nil, options: [])
                self.effectPlayer.play()
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Obstacle
    // ─────────────────────────────────────────────────────────────────────────

    /// Play obstacle warning with piano ducking. Max once every 3 seconds.
    func playObstacleWarning() {
        let now = Date()
        guard now.timeIntervalSince(lastObstacleTime) >= 3.0 else { return }
        lastObstacleTime = now

        obstacleDuckActive  = true
        pianoPlayer.volume  = max(0, pianoTargetVol - 0.3)

        playEffect(obstacleBuffer, interrupt: true) { [weak self] in
            guard let self = self else { return }
            self.obstacleDuckActive = false
            self.pianoPlayer.volume = self.pianoTargetVol
        }
    }

    /// Restore piano immediately when obstacle clears.
    func clearObstacle() {
        guard obstacleDuckActive else { return }
        obstacleDuckActive = false
        pianoPlayer.volume = pianoTargetVol
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Error
    // ─────────────────────────────────────────────────────────────────────────

    /// Play error sound. Max once every 10 seconds for the same ongoing condition.
    func playError() {
        let now = Date()
        guard now.timeIntervalSince(lastErrorTime) >= 10.0 else { return }
        lastErrorTime = now
        playEffect(errorBuffer)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Private Audio Helpers
    // ─────────────────────────────────────────────────────────────────────────

    private func startPianoLoop() {
        guard let buf = pianoBuffer else { return }
        pianoPlayer.stop()
        pianoPlayer.volume = pianoTargetVol
        pianoPlayer.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        pianoPlayer.play()
    }

    private func playEffect(_ buffer: AVAudioPCMBuffer?, interrupt: Bool = false,
                             completion: (() -> Void)? = nil) {
        guard let buf = buffer else { completion?(); return }
        if interrupt { effectPlayer.stop() }
        effectPlayer.scheduleBuffer(buf, at: nil, options: []) {
            if let cb = completion { DispatchQueue.main.async { cb() } }
        }
        effectPlayer.play()
    }

    private func fadePiano(to targetVol: Float, duration: TimeInterval,
                            completion: @escaping () -> Void) {
        fadeTimer?.invalidate()
        let steps        = 20
        let stepInterval = duration / Double(steps)
        let startVol     = pianoPlayer.volume
        let delta        = (targetVol - startVol) / Float(steps)
        var step         = 0

        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            step += 1
            self.pianoPlayer.volume = startVol + delta * Float(step)
            if step >= steps {
                t.invalidate()
                self.pianoPlayer.volume = targetVol
                DispatchQueue.main.async { completion() }
            }
        }
    }
}
