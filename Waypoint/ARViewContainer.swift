import SwiftUI
import ARKit
import SceneKit

/// UIViewRepresentable wrapping ARSCNView.
/// Receives the ARSession from ARSceneAnalyzer so the same session drives
/// both the rendered feed and the analysis pipeline.
struct ARViewContainer: UIViewRepresentable {

    let session: ARSession
    let showDebug: Bool

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.session                    = session
        arView.automaticallyUpdatesLighting = false
        arView.debugOptions               = []
        arView.rendersCameraGrain         = false
        arView.rendersMotionBlur          = false
        return arView
    }

    func updateUIView(_ arView: ARSCNView, context: Context) {
        arView.debugOptions = showDebug ? [.showFeaturePoints] : []
    }
}
