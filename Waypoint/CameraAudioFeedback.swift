import AVFoundation

/// Owns a completely separate AVAudioEngine from AudioNavigationEngine.
/// No shared state with the navigation audio — switching tabs cannot
/// interrupt or modify the navigation tone in any way.
class CameraAudioFeedback: NSObject, ObservableObject {

    // MARK: - Private audio engine
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var sampleRate: Float = 44100

    // Click burst state (read on audio thread, written on main/pulse queue)
    // Float/Bool/Int reads are naturally atomic on ARM64.
    private var burstActive      = false
    private var burstSamplesLeft = 0
    private var burstFrame       = 0
    private var burstPhase: Float = 0

    private var lastWarningTime: Date = .distantPast
    private var lastSurface: String   = ""

    private let speech = AVSpeechSynthesizer()

    // MARK: - Lifecycle

    func start() {
        buildGraph()
    }

    func stop() {
        burstActive = false
        if audioEngine.isRunning { audioEngine.stop() }
    }

    // MARK: - Audio graph

    private func buildGraph() {
        let hwRate  = audioEngine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate  = hwRate > 0 ? Float(hwRate) : 44100

        let sr             = sampleRate
        let attackSamples  = Int(sr * 0.010)   // 10 ms
        let totalSamples   = Int(sr * 0.040)   // 40 ms total burst
        // Exponential decay multiplier from 0.3 → 0.001 over (total − attack) samples
        let decaySamples   = totalSamples - attackSamples
        let decayMult: Float = powf(0.001 / 0.3, 1.0 / Float(max(1, decaySamples)))

        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 2)!
        let twoPi: Float = .pi * 2
        let phaseInc     = twoPi * 800.0 / sr   // 800 Hz click

        sourceNode = AVAudioSourceNode(format: stereoFormat) { [weak self] _, _, frameCount, abl in
            guard let self = self else { return noErr }
            let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
            guard ablPtr.count >= 2,
                  let leftBuf  = ablPtr[0].mData?.assumingMemoryBound(to: Float.self),
                  let rightBuf = ablPtr[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }

            for i in 0 ..< Int(frameCount) {
                var out: Float = 0
                if self.burstActive {
                    self.burstFrame += 1
                    let gain: Float
                    if self.burstFrame <= attackSamples {
                        // Linear attack
                        gain = 0.3 * Float(self.burstFrame) / Float(attackSamples)
                    } else {
                        // Exponential decay (accumulate into burstPhase re-use below)
                        // We track gain via burstSamplesLeft as an index
                        let decayIdx = self.burstFrame - attackSamples
                        gain = 0.3 * powf(decayMult, Float(decayIdx))
                    }
                    out = sinf(self.burstPhase) * gain
                    self.burstPhase += phaseInc
                    if self.burstPhase >= twoPi { self.burstPhase -= twoPi }

                    self.burstSamplesLeft -= 1
                    if self.burstSamplesLeft <= 0 {
                        self.burstActive = false
                        self.burstPhase  = 0
                    }
                }
                leftBuf[i]  = out
                rightBuf[i] = out
            }
            return noErr
        }

        guard let source = sourceNode else { return }
        audioEngine.attach(source)
        audioEngine.connect(source, to: audioEngine.mainMixerNode, format: stereoFormat)

        do {
            try audioEngine.start()
        } catch {
            print("[CameraAudioFeedback] Engine failed to start: \(error)")
        }
    }

    // MARK: - Public interface

    /// Call every time obstacleDistanceFt updates.
    func checkObstacle(distanceFt: Double, audioEnabled: Bool) {
        guard audioEnabled, distanceFt < 6.6 else { return }   // 6.6 ft ≈ 2 m
        let now = Date()
        guard now.timeIntervalSince(lastWarningTime) >= 3.0 else { return }
        lastWarningTime = now
        triggerClickBurst()
    }

    /// Call every time surfaceClassification changes.
    func checkSurface(_ newSurface: String, audioEnabled: Bool) {
        defer { lastSurface = newSurface }
        guard newSurface == "door", lastSurface != "door", audioEnabled else { return }
        speak("Door detected.")
    }

    /// Always spoken — ignores the audio toggle. This is a system warning.
    func announceThermalWarning() {
        speak("Device overheating, camera processing reduced.")
    }

    // MARK: - Private helpers

    private func triggerClickBurst() {
        let total        = Int(sampleRate * 0.040)
        burstSamplesLeft = total
        burstFrame       = 0
        burstPhase       = 0
        burstActive      = true
    }

    private func speak(_ text: String) {
        let utterance           = AVSpeechUtterance(string: text)
        utterance.voice         = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate          = 0.52
        speech.stopSpeaking(at: .word)
        speech.speak(utterance)
    }
}
