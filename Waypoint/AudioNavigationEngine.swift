import AVFoundation
import Combine

// MARK: - AudioNavigationEngine

class AudioNavigationEngine: NSObject, ObservableObject {

    // MARK: - Published (read by ContentView for the pan visualiser)
    @Published var isPanning: Float = 0

    // MARK: - Audio engine
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // ─────────────────────────────────────────────────────────────────────────
    // Render-thread state
    //
    // These variables are written from the main/pulse queue and read from the
    // real-time audio render callback. On ARM64 (all modern iPhones), 32-bit
    // and 64-bit aligned reads/writes are naturally atomic, which is the
    // accepted pattern for lock-free audio programming on iOS.
    // ─────────────────────────────────────────────────────────────────────────

    // Oscillator
    private var phase: Float = 0
    private var currentFrequency: Float = 330
    private var targetFrequency:  Float = 330

    // Stereo pan  (−1 = hard left, 0 = centre, +1 = hard right)
    private var currentPan: Float = 0
    private var targetPan:  Float = 0

    // Gain / envelope
    private var currentGain: Float = 0.001

    // Envelope state machine  (Int32 for ARM64 atomicity)
    //   0 = silence  1 = attack  2 = decay  3 = continuous
    private var envelopeState: Int32 = 0

    // Per-frame counters (read+written exclusively on audio thread)
    private var attackFrame: Int32 = 0
    private var decaySamplesLeft: Int32 = 0

    // Blip trigger: pulse queue writes 1, render block clears to 0
    private var blipTrigger: Int32 = 0

    // Precomputed envelope constants (set once in buildAudioGraph)
    private var sampleRate: Float = 44100
    private var attackSamples: Int32 = 1764    // 40 ms @ 44100
    private var decaySamples:  Int32 = 7938    // 180 ms @ 44100
    private var decayMult:     Float = 1.0     // per-sample exponential factor
    private var freqAlpha:     Float = 0.0     // per-frame smoothing, 0.1 s ramp
    private var panAlpha:      Float = 0.0     // per-frame smoothing, 0.08 s ramp

    // MARK: - Pulse queue
    private let pulseQueue = DispatchQueue(label: "audio.pulse", qos: .userInteractive)
    private var pulseInterval: TimeInterval = 2.0
    private var isRunning    = false
    private var isContinuous = false

    // MARK: - Speech
    private let speech = AVSpeechSynthesizer()

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Setup
    // ─────────────────────────────────────────────────────────────────────────

    func setup() {
        configureAudioSession()
        buildAudioGraph()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default,
                                    options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP])
            try session.setActive(true)
        } catch {
            speak("Audio session could not be configured.")
        }
    }

    private func buildAudioGraph() {
        let hwRate = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = hwRate > 0 ? Float(hwRate) : 44100

        // Envelope timing
        attackSamples  = Int32(sampleRate * 0.040)  // 40 ms linear attack
        decaySamples   = Int32(sampleRate * 0.180)  // 180 ms exponential decay
        // Factor: 0.28 → 0.001 over decaySamples frames
        decayMult = powf(0.001 / 0.28, 1.0 / Float(decaySamples))

        // Per-frame smoothing alphas (exponential approach)
        freqAlpha = 1.0 - expf(-1.0 / (0.10 * sampleRate))  // 0.1 s frequency ramp
        panAlpha  = 1.0 - expf(-1.0 / (0.08 * sampleRate))  // 0.08 s pan ramp

        // Capture immutables for the render closure
        let sr          = sampleRate
        let fa          = freqAlpha
        let pa          = panAlpha
        let aSamples    = attackSamples
        let dm          = decayMult

        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 2)!

        sourceNode = AVAudioSourceNode(format: stereoFormat) { [weak self] _, _, frameCount, audioBufferList in
            guard let self = self else { return noErr }

            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let leftBuf  = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightBuf = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            let twoPi: Float = .pi * 2

            // Pick up any blip trigger queued by the pulse queue
            if self.blipTrigger == 1 {
                self.blipTrigger   = 0
                self.attackFrame   = 0
                self.envelopeState = 1   // attack
            }

            for i in 0 ..< Int(frameCount) {

                // ── Smooth frequency (0.1 s ramp) ──────────────────────────
                self.currentFrequency += (self.targetFrequency - self.currentFrequency) * fa

                // ── Smooth pan (0.08 s ramp) ────────────────────────────────
                self.currentPan += (self.targetPan - self.currentPan) * pa

                // ── Envelope state machine ──────────────────────────────────
                switch self.envelopeState {

                case 0: // silence
                    self.currentGain = 0.001

                case 1: // attack — linear ramp 0.001 → 0.28 over attackSamples
                    self.attackFrame += 1
                    let t = Float(self.attackFrame) / Float(aSamples)
                    self.currentGain = 0.001 + (0.28 - 0.001) * min(t, 1.0)
                    if self.attackFrame >= aSamples {
                        self.currentGain       = 0.28
                        self.decaySamplesLeft  = self.decaySamples
                        self.envelopeState     = 2   // → decay
                    }

                case 2: // decay — exponential 0.28 → 0.001 over decaySamples
                    self.currentGain *= dm
                    self.decaySamplesLeft -= 1
                    if self.decaySamplesLeft <= 0 {
                        self.currentGain   = 0.001
                        self.envelopeState = 0   // → silence
                    }

                case 3: // continuous — smooth approach to 0.25
                    self.currentGain += (0.25 - self.currentGain) * 0.003

                default:
                    self.currentGain = 0.001
                }

                // ── Generate sine sample ────────────────────────────────────
                let sample = sinf(self.phase)
                self.phase += twoPi * self.currentFrequency / sr
                if self.phase >= twoPi { self.phase -= twoPi }

                // ── Stereo pan (balance law from spec) ──────────────────────
                //   leftVolume  = 1 − max(0, pan)
                //   rightVolume = 1 + min(0, pan)
                let p = self.currentPan
                let leftVol  = 1.0 - max(0, p)
                let rightVol = 1.0 + min(0, p)

                leftBuf[i]  = sample * self.currentGain * leftVol
                rightBuf[i] = sample * self.currentGain * rightVol
            }
            return noErr
        }

        guard let source = sourceNode else { return }
        audioEngine.attach(source)
        audioEngine.connect(source, to: audioEngine.mainMixerNode, format: stereoFormat)

        do {
            try audioEngine.start()
        } catch {
            speak("Audio engine failed to start.")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Navigation control
    // ─────────────────────────────────────────────────────────────────────────

    func startNavigation() {
        isRunning    = true
        isContinuous = false
        currentGain  = 0.001
        envelopeState = 0      // silence
        schedulePulse(after: 0.05)
        speak("Navigation started.")
    }

    func stopNavigation() {
        isRunning     = false
        isContinuous  = false
        envelopeState = 0      // silence immediately (80 ms fade handled by smoothing)
        speak("Navigation stopped.")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Live update
    //
    // Called by NavigationViewModel on every location and heading change.
    // No throttling. All distance values stay in metres internally.
    // ─────────────────────────────────────────────────────────────────────────

    func update(distanceMetres: Double, relativeBearingDegrees: Double) {
        guard isRunning else { return }

        // ── Frequency: 330 Hz @ 500 m+, 880 Hz @ 0 m ──────────────────────
        let clamped = max(0.0, min(distanceMetres, 500.0))
        targetFrequency = Float(330.0 + ((500.0 - clamped) / 500.0) * 550.0)

        // ── Pan ────────────────────────────────────────────────────────────
        // relativeBearingDegrees is 0–360 (0 = straight ahead).
        // Normalise to −180…+180 then scale: pan = clamp(diff/80, −1, +1)
        var diff = relativeBearingDegrees
        if diff > 180 { diff -= 360 }
        let pan = Float(max(-1.0, min(1.0, diff / 80.0)))
        targetPan = pan
        DispatchQueue.main.async { self.isPanning = pan }

        // ── Pulse interval ─────────────────────────────────────────────────
        let newInterval   = intervalForDistance(distanceMetres)
        let nowContinuous = distanceMetres < 3.0

        if nowContinuous != isContinuous {
            isContinuous  = nowContinuous
            envelopeState = nowContinuous ? 3 : 0   // continuous or silence
        }

        if !nowContinuous, abs(newInterval - pulseInterval) > 0.1 {
            pulseInterval = newInterval
        }
    }

    private func intervalForDistance(_ d: Double) -> TimeInterval {
        switch d {
        case ..<3:    return 0.250  // continuous — not used directly
        case 3..<6:   return 0.250
        case 6..<10:  return 0.500
        case 10..<15: return 0.900
        case 15..<20: return 1.400
        default:      return 2.000
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Pulse scheduling (serial recursive DispatchQueue.asyncAfter)
    // ─────────────────────────────────────────────────────────────────────────

    private func schedulePulse(after delay: TimeInterval) {
        guard isRunning, !isContinuous else { return }
        pulseQueue.asyncAfter(deadline: .now() + max(delay, 0.02)) { [weak self] in
            guard let self = self, self.isRunning, !self.isContinuous else { return }
            // Signal render block to start blip
            self.blipTrigger = 1
            // Recurse: schedule next pulse after current interval
            self.schedulePulse(after: self.pulseInterval)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Arrival chime
    //
    // Three sequential tones: 440 Hz, 523 Hz, 659 Hz
    // Each: 40 ms attack (uses blip envelope), held for 550 ms, then silence.
    // ─────────────────────────────────────────────────────────────────────────

    func playArrivalChime() {
        isRunning     = false
        isContinuous  = false
        envelopeState = 0

        let notes: [(Float, TimeInterval)] = [
            (440, 0.000),
            (523, 0.350),
            (659, 0.700)
        ]

        for (freq, t) in notes {
            // Start note
            pulseQueue.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self = self else { return }
                // Snap to frequency immediately (no ramp for chime)
                self.currentFrequency = freq
                self.targetFrequency  = freq
                self.attackFrame      = 0
                self.envelopeState    = 1   // attack
            }
            // End note after 550 ms
            pulseQueue.asyncAfter(deadline: .now() + t + 0.55) { [weak self] in
                self?.envelopeState = 0
            }
        }

        // Speak after chime finishes
        pulseQueue.asyncAfter(deadline: .now() + 1.5) {
            DispatchQueue.main.async { [weak self] in
                self?.speak("You have arrived.")
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Speech
    // ─────────────────────────────────────────────────────────────────────────

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate  = 0.52
        utterance.pitchMultiplier = 1.0
        speech.stopSpeaking(at: .word)
        speech.speak(utterance)
    }
}
