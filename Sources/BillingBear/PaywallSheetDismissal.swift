#if canImport(SwiftUI)
import SwiftUI

// MARK: - Sheet swipe-down and the exit offer
//
// A paywall presented as a sheet can be swiped away. While its exit offer is armed (a close would
// show it) or on screen (its close ends the flow), a swipe must go through the same close flow as the
// close button: show the exit offer in place, or perform the final close. SwiftUI has no "attempted
// dismiss" callback, so the interceptor below joins the hosting sheet's presentation-controller
// delegate (forwarding every call to SwiftUI's own delegate) and reports the blocked swipe. When it
// cannot join (not presented, or not as a sheet), the swipe is never blocked: the customer can always
// leave, the exit offer is simply not shown on that path.

/// When a swipe-down is blocked and routed through the close flow instead. Pure, so it is testable.
public enum PaywallSheetDismissPolicy {
    /// Block the swipe only while it would skip the exit offer (armed) or its final close (pending),
    /// and only when the blocked attempt is delivered to the paywall (`intercepting`); otherwise the
    /// swipe dismisses as before, so a customer is never trapped.
    public static func blocksSwipe(armed: Bool, pending: Bool, intercepting: Bool) -> Bool {
        intercepting && (armed || pending)
    }
}

#if os(iOS)
import UIKit

/// Joins the presentation controller of the sheet hosting the paywall. `onAttempt` runs when UIKit
/// blocked a swipe-down (the paywall disabled interactive dismissal); `onSwipeDismissed` when a swipe
/// did dismiss it. `onInstalled` reports whether the attempt can be delivered at all.
struct PaywallSheetDismissInterceptor: UIViewControllerRepresentable {
    let active: Bool
    let onInstalled: (Bool) -> Void
    let onAttempt: () -> Void
    let onSwipeDismissed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> ProbeController {
        let controller = ProbeController()
        controller.coordinator = context.coordinator
        update(context.coordinator)
        return controller
    }

    func updateUIViewController(_ controller: ProbeController, context: Context) {
        update(context.coordinator)
        // The sheet may only now be on screen, or the paywall's state changed: (re)join it.
        DispatchQueue.main.async { [weak controller] in controller?.join() }
    }

    static func dismantleUIViewController(_ controller: ProbeController, coordinator: Coordinator) {
        coordinator.leave()
    }

    private func update(_ coordinator: Coordinator) {
        coordinator.active = active
        coordinator.onInstalled = onInstalled
        coordinator.onAttempt = onAttempt
        coordinator.onSwipeDismissed = onSwipeDismissed
    }

    /// An invisible child of the paywall's hosting controller, used to find the presented controller.
    final class ProbeController: UIViewController {
        weak var coordinator: Coordinator?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            join()
        }

        func join() { coordinator?.join(from: self) }
    }

    final class Coordinator {
        var active = false
        var onInstalled: (Bool) -> Void = { _ in }
        var onAttempt: () -> Void = {}
        var onSwipeDismissed: () -> Void = {}
        /// Retained here: UIPresentationController.delegate is weak.
        private var proxy: Proxy?
        private weak var joined: UIPresentationController?
        private var reported: Bool?

        func join(from probe: UIViewController) {
            guard active else {
                leave()
                report(false)
                return
            }
            var presented: UIViewController = probe
            while let parent = presented.parent { presented = parent }
            guard presented.presentingViewController != nil,
                  let controller = presented.presentationController,
                  controller.presentedViewController === presented else {
                leave()
                report(false)
                return
            }
            if let existing = controller.delegate as? Proxy {
                existing.owner = self
                proxy = existing
            } else {
                let fresh = Proxy(original: controller.delegate)
                fresh.owner = self
                controller.delegate = fresh
                proxy = fresh
            }
            joined = controller
            report(true)
        }

        func leave() {
            if let controller = joined, let proxy, controller.delegate === proxy {
                controller.delegate = proxy.original
            }
            proxy = nil
            joined = nil
        }

        private func report(_ installed: Bool) {
            guard reported != installed else { return }
            reported = installed
            let callback = onInstalled
            DispatchQueue.main.async { callback(installed) }
        }

        fileprivate func attempted() { onAttempt() }
        fileprivate func swipeDismissed() { onSwipeDismissed() }
    }

    /// Forwards every delegate call to the delegate it replaced (SwiftUI's), and tells the paywall
    /// about a blocked or completed swipe.
    final class Proxy: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var original: UIAdaptivePresentationControllerDelegate?
        weak var owner: Coordinator?

        init(original: UIAdaptivePresentationControllerDelegate?) {
            self.original = original
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            original?.presentationControllerDidAttemptToDismiss?(presentationController)
            owner?.attempted()
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            original?.presentationControllerDidDismiss?(presentationController)
            owner?.swipeDismissed()
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            original
        }
    }
}
#endif
#endif
