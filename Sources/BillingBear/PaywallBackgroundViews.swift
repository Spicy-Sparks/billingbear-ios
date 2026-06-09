import SwiftUI
import AVFoundation
import Lottie
#if canImport(UIKit)
import UIKit
#endif

// Native paywall backgrounds (#12) — gradient + looping video, both with SwiftUI/AVFoundation
// built-ins so there is NO extra dependency to install (plug-and-play). Lottie is added separately
// via the lottie-ios SPM dependency. Each falls back to the solid theme colour / poster so a
// paywall never renders blank.

/// Linear gradient background. Converts the CSS angle (0 = to top, 90 = to right, 180 = to bottom)
/// into SwiftUI start/end unit points (SwiftUI y grows downward).
struct PaywallGradientView: View {
    let gradient: PaywallGradient
    let fallback: Color

    var body: some View {
        let from = Color(css: gradient.from) ?? fallback
        let to = Color(css: gradient.to) ?? fallback
        let pts = PaywallGradientMath.unitPoints(angleDegrees: gradient.angle)
        return LinearGradient(colors: [from, to], startPoint: pts.start, endPoint: pts.end)
            .ignoresSafeArea()
    }
}

/// Pure mapping from a CSS gradient angle to SwiftUI start/end unit points. CSS convention:
/// 0° = to top, 90° = to right, 180° = to bottom, 270° = to left. SwiftUI's y axis grows DOWNWARD,
/// so the vertical component is negated. Extracted for unit testing the angle math directly.
enum PaywallGradientMath {
    static func unitPoints(angleDegrees: Double) -> (start: UnitPoint, end: UnitPoint) {
        let r = angleDegrees * .pi / 180
        let x = sin(r)
        let y = -cos(r)
        let start = UnitPoint(x: 0.5 - 0.5 * x, y: 0.5 - 0.5 * y)
        let end = UnitPoint(x: 0.5 + 0.5 * x, y: 0.5 + 0.5 * y)
        return (start, end)
    }
}

#if canImport(UIKit)
/// A muted, looping, controls-free background video using AVPlayerLayer (built-in AVFoundation).
/// `repeat` is achieved with AVPlayerLooper over an AVQueuePlayer.
struct PaywallVideoView: UIViewRepresentable {
    let url: URL
    let loop: Bool
    let muted: Bool

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer(playerItem: item)
        queue.isMuted = muted
        queue.actionAtItemEnd = .none
        if loop {
            context.coordinator.looper = AVPlayerLooper(player: queue, templateItem: item)
        }
        view.playerLayer.player = queue
        view.playerLayer.videoGravity = .resizeAspectFill
        queue.play()
        context.coordinator.player = queue
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }

    /// A UIView whose backing layer is an AVPlayerLayer, so the video fills the view bounds.
    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif

#if canImport(UIKit)
/// Animated Lottie background loaded from a remote URL (lottie-ios, bundled). Plays looped at the
/// configured speed; until the animation finishes loading the poster (if any) shows through behind.
struct PaywallLottieView: UIViewRepresentable {
    let url: URL
    let loop: Bool
    let autoplay: Bool
    let speed: Double

    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.contentMode = .scaleAspectFill
        view.loopMode = loop ? .loop : .playOnce
        view.animationSpeed = speed
        view.backgroundBehavior = .pauseAndRestore
        LottieAnimation.loadedFrom(url: url, closure: { animation in
            guard let animation else { return }
            view.animation = animation
            if autoplay { view.play() }
        }, animationCache: DefaultAnimationCache.sharedCache)
        return view
    }

    func updateUIView(_ uiView: LottieAnimationView, context: Context) {}
}
#endif

/// Resolves the full background for a theme: gradient / video / lottie (with poster + overlay).
/// Image is handled by the caller. Returns EmptyView for solid (the solid colour is underneath).
@ViewBuilder
func paywallBackground(_ theme: PaywallTheme, solid: Color) -> some View {
    switch theme.backgroundType {
    case .gradient:
        if let g = theme.backgroundGradient {
            PaywallGradientView(gradient: g, fallback: solid)
        }
    case .lottie:
        if let l = theme.backgroundLottie {
            ZStack {
                if let poster = l.posterUrl { RemoteImage(url: poster, contentMode: .fill).ignoresSafeArea() }
                #if canImport(UIKit)
                if let u = URL(string: l.url) {
                    PaywallLottieView(url: u, loop: l.loop ?? true, autoplay: l.autoplay ?? true, speed: l.speed ?? 1)
                        .ignoresSafeArea()
                }
                #endif
                if let overlay = l.overlay, let c = Color(css: overlay) { c.ignoresSafeArea() }
            }
        }
    case .video:
        if let v = theme.backgroundVideo {
            ZStack {
                if let poster = v.posterUrl { RemoteImage(url: poster, contentMode: .fill).ignoresSafeArea() }
                #if canImport(UIKit)
                if let u = URL(string: v.url) {
                    PaywallVideoView(url: u, loop: v.loop ?? true, muted: v.muted ?? true)
                        .ignoresSafeArea()
                }
                #endif
                if let overlay = v.overlay, let c = Color(css: overlay) { c.ignoresSafeArea() }
            }
        }
    default:
        EmptyView()
    }
}
