import AVFoundation
import Combine

class AudioNavigationEngine: NSObject, ObservableObject {

    // MARK: - Published
    @Published var isPanning: Float = 0  // -1 to 1, for the sighted-companion visualiser

    // MARK: - Audio Engine
    private let audioEngine = AVAudioEngine()
    private let environmentNode = AVAudioEnvironmentNode()
    private var sourceNode: AVAudioSourceNode?

    // MARK: - Tone state (written on main, read on audio thread — atomic-style via DispatchQueue)
    private var currentFrequency: Float = 392.0
    private var currentAmplitude: Float = 0.0
    private var phase: Float = 0.0
    private var sampleRate: Float = 44100.0

    // MARK: - Pulse state
    private var pulseTimer: Timer?
    private var pulseInterval: TimeInterval = 2.0
    private var isContinuous = false
    private var isRunning = false

    // MARK: - Speech
    private let speech = AVSpeechSynthesizer()

    // MARK: - Setup

    func setup() {
        configureAudioSession()
        buildAudioGraph()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback keeps audio going with screen off; mixWithOthers allows ambient sounds
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            speak("Audio session could not be configured.")
        }
    }

    private func buildAudioGraph() {
        // Determine sample rate from hardware
        let hwRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = hwRate > 0 ? Float(hwRate) : 44100

        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 2)!

        // HRTF environment node — true 3-D head-related transfer function
        environmentNode.renderingAlgorithm = .HRTF
        environmentNode.reverbParameters.enable = false
        environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environmentNode.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)

        // AVAudioSourceNode renders our sine wave on the real-time audio thread
        let sr = sampleRate
        sourceNode = AVAudioSourceNode(format: monoFormat) { [weak self] _, _, frameCount, audioBufferList in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let twoPi: Float = .pi * 2
            let phaseIncrement = twoPi * self.currentFrequency / sr

            for frame in 0 ..< Int(frameCount) {
                let sample = sinf(self.phase) * self.currentAmplitude
                self.phase += phaseIncrement
                if self.phase >= twoPi { self.phase -= twoPi }
                for buffer in ablPointer {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }

        guard let source = sourceNode else { return }

        audioEngine.attach(environmentNode)
        audioEngine.attach(source)
        // source -> HRTF environment -> main mixer -> output
        audioEngine.connect(source, to: environmentNode, format: monoFormat)
        audioEngine.connect(environmentNode, to: audioEngine.mainMixerNode, format: stereoFormat)

        do {
            try audioEngine.start()
        } catch {
            speak("Audio engine failed to start.")
        }
    }

    // MARK: - Navigation Control

    func startNavigation() {
        isRunning = true
        currentAmplitude = 0
        isContinuous = false
        startPulseCycle()
        speak("Navigation started. The tone will guide you to your destination.")
    }

    func stopNavigation() {
        isRunning = false
        stopPulseCycle()
        currentAmplitude = 0
        speak("Navigation stopped.")
    }

    // MARK: - Live Update

    /// Call on every location or heading change.
    /// - distanceMetres: total path distance remaining
    /// - relativeBearingDegrees: bearing to next waypoint minus user heading (0 = straight ahead)
    func update(distanceMetres: Double, relativeBearingDegrees: Double) {
        guard isRunning else { return }
        updateFrequency(distance: distanceMetres)
        updatePulseRate(distance: distanceMetres)
        update3DPosition(relativeBearing: relativeBearingDegrees)

        let radians = Float(relativeBearingDegrees) * .pi / 180
        DispatchQueue.main.async { self.isPanning = sinf(radians) }
    }

    private func updateFrequency(distance: Double) {
        // Linear interpolation: 392 Hz (G4) at 500 m+, 880 Hz (A5) at 0 m
        let clamped = max(0, min(distance, 500))
        let t = Float(1.0 - clamped / 500.0)
        currentFrequency = 392.0 + (880.0 - 392.0) * t
    }

    private func updatePulseRate(distance: Double) {
        if distance <= 5 {
            // Continuous tone within 5 m
            guard !isContinuous else { return }
            isContinuous = true
            pulseTimer?.invalidate()
            currentAmplitude = 0.4
        } else {
            isContinuous = false
            // Pulse interval: 2 s far, 0.3 s near (5 m boundary)
            let clamped = max(5.0, min(distance, 500.0))
            let t = (clamped - 5.0) / (500.0 - 5.0)
            pulseInterval = 0.3 + (2.0 - 0.3) * t
        }
    }

    // MARK: - Pulse Engine

    private func startPulseCycle() {
        pulseTimer?.invalidate()
        guard !isContinuous else { return }
        schedulePulse()
    }

    private func stopPulseCycle() {
        pulseTimer?.invalidate()
        currentAmplitude = 0
    }

    private func schedulePulse() {
        guard isRunning, !isContinuous else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: pulseInterval, repeats: false) { [weak self] _ in
            self?.firePulse()
        }
    }

    private func firePulse() {
        currentAmplitude = 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, !self.isContinuous, self.isRunning else { return }
            self.currentAmplitude = 0
            self.schedulePulse()
        }
    }

    // MARK: - 3-D Positioning

    private func update3DPosition(relativeBearing: Double) {
        // Bearing 0° → straight ahead (negative Z in AVAudioEnvironmentNode space)
        // Bearing 90° → right (positive X)
        let rad = relativeBearing * .pi / 180
        let x = Float(sin(rad))
        let z = Float(-cos(rad))           // forward = -Z
        sourceNode?.position = AVAudio3DPoint(x: x, y: 0, z: z)
    }

    // MARK: - Arrival Chime

    func playArrivalChime() {
        stopNavigation()
        // Ascending triad: A4 (440), C5 (523.25), E5 (659.25)
        playChimeNote(frequency: 440.00, after: 0.0)
        playChimeNote(frequency: 523.25, after: 0.35)
        playChimeNote(frequency: 659.25, after: 0.70)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            self.speak("You have arrived at your destination.")
        }
    }

    private func playChimeNote(frequency: Float, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.currentFrequency = frequency
            self.currentAmplitude = 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                self.currentAmplitude = 0
            }
        }
    }

    // MARK: - Speech

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0
        speech.stopSpeaking(at: .word)
        speech.speak(utterance)
    }
}
