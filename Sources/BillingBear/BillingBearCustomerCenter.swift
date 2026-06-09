#if canImport(SwiftUI)
import SwiftUI

// MARK: - BillingBearCustomerCenter
//
// Native SwiftUI in-app subscription-management screen for END USERS (RevenueCat Customer Center
// parity). Ported from the React Native SDK's `CustomerCenter.tsx`. On appear it loads the Customer
// Center payload for the tracked (or overridden) appUserId, renders each subscription with its
// server-driven action buttons, and wires the actions:
//
//   - manage_in_store              → open the store/billing portal URL
//   - cancel / cancel_at_period_end → optional survey → win-back offer → retention, then cancel
//   - reactivate                   → re-enable a period-end cancellation
//   - request_refund               → confirm, then request a refund
//   - change_plan                  → switch to a target product, or fall back to support
//
// Support links, custom sections and deep links render below; an empty state shows when the user
// has no subscriptions. Themed from config.appearance (light/dark/system + accent/background/card/
// text colours + cornerRadius + logoUrl) and FULLY localized from config.localizations via a
// t(key, fallback) helper resolving the device locale (Locale.current).

@available(iOS 15.0, macOS 12.0, *)
public struct BillingBearCustomerCenter: View {

    private let appUserId: String?
    private let themeOverride: CustomerCenterAppearance?
    private let onClose: (() -> Void)?

    public init(
        appUserId: String? = nil,
        themeOverride: CustomerCenterAppearance? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.appUserId = appUserId
        self.themeOverride = themeOverride
        self.onClose = onClose
    }

    @Environment(\.colorScheme) private var systemScheme
    @StateObject private var model = CustomerCenterModel()
    @State private var alert: CCAlert?
    @State private var cancelFlow: CancelFlow?

    public var body: some View {
        let palette = resolvePalette()
        let t = makeTranslator()

        ZStack {
            palette.background.ignoresSafeArea()

            if model.loading && model.data == nil {
                loadingState(palette, t)
            } else if let err = model.loadError, model.data == nil {
                errorState(err, palette, t)
            } else if let data = model.data {
                loaded(data, palette: palette, t: t)
            }
        }
        .task { await model.load(appUserId: appUserId) }
        .alert(item: $alert) { a in
            if let secondary = a.secondary {
                return Alert(title: Text(a.title), message: a.message.map(Text.init),
                             primaryButton: secondary, secondaryButton: a.primary)
            }
            return Alert(title: Text(a.title), message: a.message.map(Text.init), dismissButton: a.primary)
        }
        .sheet(item: $cancelFlow) { flow in
            cancelSheet(flow, palette: palette, t: t)
        }
    }

    // MARK: Loaded

    @ViewBuilder
    private func loaded(_ data: CustomerCenterData, palette: CCPalette, t: @escaping Translator) -> some View {
        VStack(spacing: 0) {
            header(data, palette: palette, t: t)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if data.subscriptions.isEmpty {
                        emptyCard(palette, t)
                    } else {
                        ForEach(data.subscriptions) { sub in
                            SubscriptionCardView(sub: sub, palette: palette, busy: model.busyId == sub.id, t: t) { action in
                                handle(action: action, sub: sub, data: data, t: t)
                            }
                        }
                    }

                    supportSection(data, palette: palette, t: t)
                    customSections(data, palette: palette, t: t)
                    deepLinkSection(data, palette: palette, t: t)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 48)
            }
        }
    }

    @ViewBuilder
    private func header(_ data: CustomerCenterData, palette: CCPalette, t: @escaping Translator) -> some View {
        HStack {
            if let logo = data.config.appearance.logoUrl {
                RemoteImage(url: logo, contentMode: .fit).frame(width: 120, height: 36)
            } else {
                Text(t("title", "Subscriptions"))
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundColor(palette.text)
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(palette.muted)
                        .frame(width: 32, height: 32)
                        .background(palette.subtle)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private func emptyCard(_ palette: CCPalette, _ t: @escaping Translator) -> some View {
        VStack(spacing: 8) {
            Text(t("noSubscriptions", "No active subscriptions"))
                .font(.system(size: 17, weight: .bold)).foregroundColor(palette.text)
            Text(t("noSubscriptionsBody", "When you subscribe, you’ll be able to manage it here."))
                .font(.system(size: 14)).foregroundColor(palette.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32).padding(.horizontal, 18)
        .background(palette.card)
        .overlay(RoundedRectangle(cornerRadius: palette.radius).stroke(palette.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: palette.radius))
        .padding(.top, 14)
    }

    @ViewBuilder
    private func supportSection(_ data: CustomerCenterData, palette: CCPalette, t: @escaping Translator) -> some View {
        if let s = data.config.support, (s.contactEmail != nil || s.supportUrl != nil || s.faqUrl != nil) {
            SectionGroupView(title: t("support", "Support"), palette: palette) {
                if let email = s.contactEmail {
                    LinkRowView(label: t("contactSupport", "Contact support"), palette: palette) { open("mailto:\(email)") }
                }
                if let url = s.supportUrl {
                    LinkRowView(label: t("helpCenter", "Help center"), palette: palette) { open(url) }
                }
                if let url = s.faqUrl {
                    LinkRowView(label: t("faq", "FAQ"), palette: palette) { open(url) }
                }
            }
        }
    }

    @ViewBuilder
    private func customSections(_ data: CustomerCenterData, palette: CCPalette, t: @escaping Translator) -> some View {
        if let sections = data.config.sections, !sections.isEmpty {
            SectionGroupView(title: t("more", "More"), palette: palette) {
                ForEach(sections) { sec in
                    LinkRowView(label: t(sec.title, sec.title), palette: palette) { open(sec.url) }
                }
            }
        }
    }

    @ViewBuilder
    private func deepLinkSection(_ data: CustomerCenterData, palette: CCPalette, t: @escaping Translator) -> some View {
        if let links = data.deepLinks, !links.isEmpty {
            SectionGroupView(title: t("links", "Links"), palette: palette) {
                ForEach(links) { link in
                    LinkRowView(label: t(link.title, link.title), palette: palette) { open(link.url) }
                }
            }
        }
    }

    // MARK: Loading / error

    private func loadingState(_ palette: CCPalette, _ t: @escaping Translator) -> some View {
        VStack(spacing: 14) {
            ProgressView().tint(palette.accent)
            Text(t("loading", "Loading your subscriptions…")).font(.system(size: 14)).foregroundColor(palette.muted)
        }
    }

    private func errorState(_ err: Error, _ palette: CCPalette, _ t: @escaping Translator) -> some View {
        VStack(spacing: 12) {
            Text(t("loadErrorTitle", "Couldn’t load this page"))
                .font(.system(size: 18, weight: .bold)).foregroundColor(palette.text)
            Text(err.localizedDescription).font(.system(size: 14)).foregroundColor(palette.muted).multilineTextAlignment(.center)
            PrimaryButtonView(label: t("tryAgain", "Try again"), palette: palette) {
                Task { await model.load(appUserId: appUserId) }
            }
        }
        .padding(24)
    }

    // MARK: Action dispatch

    private func handle(action: CustomerCenterAction, sub: CustomerCenterSubscription, data: CustomerCenterData, t: @escaping Translator) {
        switch action.type {
        case .manageInStore:
            if let url = action.url { open(url) }
        case .cancel, .cancelAtPeriodEnd:
            let mode: CustomerCenterCancelMode = action.type == .cancelAtPeriodEnd ? .periodEnd : .immediate
            beginCancel(sub: sub, mode: mode, data: data, t: t)
        case .reactivate:
            runMutation(subId: sub.id, errorTitle: t("reactivateFailed", "Could not reactivate")) {
                try await Purchases.shared.ccReactivate(subscriptionId: sub.id, appUserId: effectiveUserId)
            }
        case .requestRefund:
            alert = CCAlert(
                title: t("refundConfirmTitle", "Request a refund?"),
                message: t("refundConfirmBody", "We’ll submit a refund request for this subscription."),
                primary: .destructive(Text(t("requestRefund", "Request refund"))) {
                    runMutation(subId: sub.id, errorTitle: t("refundFailed", "Refund failed")) {
                        try await Purchases.shared.ccRefund(subscriptionId: sub.id, appUserId: effectiveUserId)
                        await MainActor.run {
                            alert = CCAlert(title: t("refundDoneTitle", "Refund requested"),
                                            message: t("refundDoneBody", "Your refund request has been submitted."),
                                            primary: .default(Text("OK")))
                        }
                    }
                },
                secondary: .cancel(Text(t("notNow", "Not now")))
            )
        case .changePlan:
            if let newId = action.newProductId {
                runMutation(subId: sub.id, errorTitle: t("changePlanFailed", "Could not change plan")) {
                    try await Purchases.shared.ccChangePlan(subscriptionId: sub.id, newProductId: newId, appUserId: effectiveUserId)
                }
            } else if let url = data.config.support?.supportUrl {
                open(url)
            } else if let email = data.config.support?.contactEmail {
                open("mailto:\(email)?subject=Change%20my%20plan")
            } else {
                alert = CCAlert(title: t("changePlan", "Change plan"),
                                message: t("changePlanSupport", "Please contact support to change your plan."),
                                primary: .default(Text("OK")))
            }
        case .unknown:
            break
        }
    }

    private var effectiveUserId: String { appUserId ?? model.data?.appUserId ?? "" }

    // MARK: Cancel flow

    private func beginCancel(sub: CustomerCenterSubscription, mode: CustomerCenterCancelMode, data: CustomerCenterData, t: @escaping Translator) {
        let survey = data.config.survey
        if let survey, survey.enabled, !survey.reasons.isEmpty {
            cancelFlow = CancelFlow(sub: sub, mode: mode, step: .survey)
            return
        }
        if let step = retentionStep(for: sub, data: data) {
            cancelFlow = CancelFlow(sub: sub, mode: mode, step: step)
            return
        }
        // No survey / offer / retention → confirm with a system dialog.
        alert = CCAlert(
            title: mode == .periodEnd ? t("cancelAtPeriodEndTitle", "Cancel at period end?") : t("cancelTitle", "Cancel subscription?"),
            message: mode == .periodEnd
                ? t("cancelAtPeriodEndBody", "Your subscription stays active until the end of the current period.")
                : t("cancelBody", "Your subscription will be cancelled immediately."),
            primary: .destructive(Text(t("continueCancel", "Continue cancelling"))) {
                performCancel(sub: sub, mode: mode, reason: nil, comment: "", t: t)
            },
            secondary: .cancel(Text(t("keepSubscription", "Keep subscription")))
        )
    }

    private func retentionStep(for sub: CustomerCenterSubscription, data: CustomerCenterData) -> CancelStep? {
        if !offers(for: sub, data: data).isEmpty { return .offer }
        if data.config.retention?.enabled == true { return .retention }
        return nil
    }

    private func offers(for sub: CustomerCenterSubscription, data: CustomerCenterData) -> [CustomerCenterOffer] {
        let p = sub.provider.lowercased()
        let managed = p == "stripe" || p == "paddle"
        return managed ? (data.config.retention?.offers ?? []) : []
    }

    private func performCancel(sub: CustomerCenterSubscription, mode: CustomerCenterCancelMode, reason: String?, comment: String, t: @escaping Translator) {
        cancelFlow = nil
        runMutation(subId: sub.id, errorTitle: t("cancelFailedTitle", "Cancellation failed")) {
            if let reason {
                // Best-effort survey — never block the cancel on telemetry.
                try? await Purchases.shared.ccSurvey(
                    reason: reason,
                    comment: comment.trimmingCharacters(in: .whitespaces).isEmpty ? nil : comment,
                    subscriptionId: sub.id,
                    appUserId: effectiveUserId
                )
            }
            try await Purchases.shared.ccCancel(subscriptionId: sub.id, mode: mode, appUserId: effectiveUserId)
        }
    }

    private func acceptOffer(sub: CustomerCenterSubscription, offer: CustomerCenterOffer, t: @escaping Translator) {
        cancelFlow = nil
        runMutation(subId: sub.id, errorTitle: t("offerFailedTitle", "Could not apply offer")) {
            let res = try await Purchases.shared.ccAcceptOffer(subscriptionId: sub.id, offerId: offer.id, appUserId: effectiveUserId)
            await MainActor.run {
                if res.accepted {
                    alert = CCAlert(title: t("offerClaimedTitle", "Offer applied"),
                                    message: res.message ?? t("offerClaimedBody", "Your discount has been applied and your subscription will continue."),
                                    primary: .default(Text("OK")))
                } else {
                    alert = CCAlert(title: t("offerUnavailableTitle", "Offer unavailable"),
                                    message: res.message ?? t("offerUnavailableBody", "This offer could not be applied. Please try again."),
                                    primary: .default(Text("OK")))
                }
            }
        }
    }

    @ViewBuilder
    private func cancelSheet(_ flow: CancelFlow, palette: CCPalette, t: @escaping Translator) -> some View {
        if let data = model.data {
            CancelFlowSheet(
                flow: flow,
                config: data.config,
                offers: offers(for: flow.sub, data: data),
                palette: palette,
                t: t,
                onContinueSurvey: { reason, comment in
                    if let step = retentionStep(for: flow.sub, data: data) {
                        cancelFlow = CancelFlow(sub: flow.sub, mode: flow.mode, step: step, reason: reason, comment: comment)
                    } else {
                        performCancel(sub: flow.sub, mode: flow.mode, reason: reason, comment: comment, t: t)
                    }
                },
                onClaimOffer: { offer in acceptOffer(sub: flow.sub, offer: offer, t: t) },
                onDeclineOffer: {
                    if data.config.retention?.enabled == true {
                        cancelFlow = CancelFlow(sub: flow.sub, mode: flow.mode, step: .retention, reason: flow.reason, comment: flow.comment)
                    } else {
                        performCancel(sub: flow.sub, mode: flow.mode, reason: flow.reason, comment: flow.comment, t: t)
                    }
                },
                onConfirmCancel: { performCancel(sub: flow.sub, mode: flow.mode, reason: flow.reason, comment: flow.comment, t: t) },
                onDismiss: { cancelFlow = nil }
            )
        }
    }

    // MARK: Mutation helper

    private func runMutation(subId: String, errorTitle: String, _ fn: @escaping () async throws -> Void) {
        Task { @MainActor in
            model.busyId = subId
            defer { model.busyId = nil }
            do {
                try await fn()
                await model.load(appUserId: appUserId)
            } catch {
                alert = CCAlert(title: errorTitle, message: error.localizedDescription, primary: .default(Text("OK")))
            }
        }
    }

    // MARK: Theming + localization

    private func resolvePalette() -> CCPalette {
        let base = model.data?.config.appearance ?? CustomerCenterAppearance(mode: themeOverride?.mode ?? "system")
        let merged = base.merged(with: themeOverride)
        let isDark: Bool
        switch merged.mode {
        case "dark": isDark = true
        case "light": isDark = false
        default: isDark = systemScheme == .dark
        }
        return CCPalette(appearance: merged, dark: isDark)
    }

    private func makeTranslator() -> Translator {
        let localizations = model.data?.config.localizations
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        guard let localizations else { return { _, fallback in fallback } }
        let full = localizations[locale]
        let base = localizations[String(locale.split(separator: "-").first ?? "")]
        return { key, fallback in full?[key] ?? base?[key] ?? fallback }
    }

    private func open(_ urlString: String) {
        #if canImport(UIKit)
        if let url = URL(string: urlString) { UIApplication.shared.open(url) }
        #endif
    }
}

// MARK: - Translator

public typealias Translator = (_ key: String, _ fallback: String) -> String

// MARK: - Cancel flow state

@available(iOS 15.0, macOS 12.0, *)
enum CancelStep { case survey, offer, retention }

@available(iOS 15.0, macOS 12.0, *)
struct CancelFlow: Identifiable {
    let id = UUID()
    let sub: CustomerCenterSubscription
    let mode: CustomerCenterCancelMode
    let step: CancelStep
    var reason: String?
    var comment: String = ""
}

// MARK: - Alert wrapper

@available(iOS 15.0, macOS 12.0, *)
struct CCAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String?
    let primary: Alert.Button
    var secondary: Alert.Button?
}

// MARK: - Palette

@available(iOS 15.0, macOS 12.0, *)
struct CCPalette {
    let background: Color
    let card: Color
    let text: Color
    let muted: Color
    let accent: Color
    let onAccent: Color
    let border: Color
    let subtle: Color
    let destructive: Color
    let radius: CGFloat

    init(appearance: CustomerCenterAppearance, dark: Bool) {
        let lightBase = (bg: "#f5f5f7", card: "#ffffff", text: "#111114", muted: "#6b6b73", border: "#e4e4e9", subtle: "#f0f0f3", destructive: "#d92d20")
        let darkBase = (bg: "#0a0a0b", card: "#171719", text: "#fafafa", muted: "#9a9aa2", border: "#2a2a2e", subtle: "#202024", destructive: "#ff6b60")
        let b = dark ? darkBase : lightBase
        background = Color.css(appearance.backgroundColor ?? b.bg, fallback: .black)
        card = Color.css(appearance.cardColor ?? b.card, fallback: .gray)
        text = Color.css(appearance.textColor ?? b.text, fallback: .white)
        muted = Color.css(b.muted, fallback: .gray)
        accent = Color.css(appearance.accentColor ?? "#5b5bd6", fallback: .accentColor)
        onAccent = .white
        border = Color.css(b.border, fallback: .gray)
        subtle = Color.css(b.subtle, fallback: .gray)
        destructive = Color.css(b.destructive, fallback: .red)
        radius = CGFloat(appearance.cornerRadius ?? 16)
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension CustomerCenterAppearance {
    func merged(with override: CustomerCenterAppearance?) -> CustomerCenterAppearance {
        guard let o = override else { return self }
        return CustomerCenterAppearance(
            mode: o.mode,
            accentColor: o.accentColor ?? accentColor,
            backgroundColor: o.backgroundColor ?? backgroundColor,
            cardColor: o.cardColor ?? cardColor,
            textColor: o.textColor ?? textColor,
            logoUrl: o.logoUrl ?? logoUrl,
            cornerRadius: o.cornerRadius ?? cornerRadius
        )
    }
}

// MARK: - Sub-views

@available(iOS 15.0, macOS 12.0, *)
private struct SubscriptionCardView: View {
    let sub: CustomerCenterSubscription
    let palette: CCPalette
    let busy: Bool
    let t: Translator
    let onAction: (CustomerCenterAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sub.displayName.isEmpty ? sub.productId : sub.displayName)
                        .font(.system(size: 18, weight: .bold)).foregroundColor(palette.text).lineLimit(2)
                    if !sub.displayName.isEmpty, sub.displayName != sub.productId {
                        Text(sub.productId).font(.system(size: 12)).foregroundColor(palette.muted).lineLimit(1)
                    }
                }
                Spacer()
                StatusPillView(status: sub.status, willRenew: sub.willRenew, palette: palette)
            }

            VStack(alignment: .leading, spacing: 2) {
                if let price = sub.priceText {
                    Text(price).font(.system(size: 14)).foregroundColor(palette.text)
                }
                if let renewal = renewalLine {
                    Text(renewal).font(.system(size: 14)).foregroundColor(palette.muted)
                }
            }
            .padding(.top, 12)

            if busy {
                HStack { Spacer(); ProgressView().tint(palette.accent); Spacer() }
                    .padding(.top, 20).padding(.bottom, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(sub.actions) { action in
                        ActionButtonView(action: action, palette: palette, t: t) { onAction(action) }
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(18)
        .background(palette.card)
        .overlay(RoundedRectangle(cornerRadius: palette.radius).stroke(palette.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: palette.radius))
        .padding(.top, 14)
    }

    private var renewalLine: String? {
        let when = Self.formatDate(sub.expiresAt)
        if sub.willRenew {
            return when.map { "\(t("renewsOn", "Renews on")) \($0)" } ?? t("renewsAutomatically", "Renews automatically")
        }
        return when.map { "\(t("expiresOn", "Expires on")) \($0)" }
    }

    static func formatDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return nil }
        let out = DateFormatter()
        out.dateStyle = .medium
        return out.string(from: date)
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct StatusPillView: View {
    let status: String
    let willRenew: Bool
    let palette: CCPalette

    var body: some View {
        let lower = status.lowercased()
        let isActive = ["active", "trialing", "grace_period"].contains(lower)
        let isCancelling = (lower == "active" && !willRenew) || lower == "cancelled" || lower == "canceled"
        let color = isCancelling ? palette.destructive : (isActive ? palette.accent : palette.muted)
        let label = (isActive && !willRenew) ? "Cancelling" : (status.isEmpty ? "Unknown" : status)
        Text(label)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(color.opacity(0.1))
            .overlay(Capsule().stroke(color, lineWidth: 1))
            .clipShape(Capsule())
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct ActionButtonView: View {
    let action: CustomerCenterAction
    let palette: CCPalette
    let t: Translator
    let onPress: () -> Void

    var body: some View {
        let destructive = action.type == .cancel || action.type == .cancelAtPeriodEnd || action.type == .requestRefund
        let primary = action.type == .manageInStore || action.type == .reactivate
        if primary {
            PrimaryButtonView(label: label, palette: palette, action: onPress)
        } else {
            SecondaryButtonView(label: label, palette: palette, destructive: destructive, action: onPress)
        }
    }

    private var label: String {
        switch action.type {
        case .manageInStore:
            if !action.label.isEmpty { return action.label }
            return t("manageInStore", "Manage in App Store")
        case .cancel: return t("cancel", action.label.isEmpty ? "Cancel subscription" : action.label)
        case .cancelAtPeriodEnd: return t("cancelAtPeriodEnd", action.label.isEmpty ? "Cancel at period end" : action.label)
        case .reactivate: return t("reactivate", action.label.isEmpty ? "Reactivate" : action.label)
        case .changePlan: return t("changePlan", action.label.isEmpty ? "Change plan" : action.label)
        case .requestRefund: return t("requestRefund", action.label.isEmpty ? "Request refund" : action.label)
        case .unknown: return action.label
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct SectionGroupView<Content: View>: View {
    let title: String
    let palette: CCPalette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold)).foregroundColor(palette.muted)
                .padding(.leading, 4)
            VStack(spacing: 0) { content }
                .background(palette.card)
                .overlay(RoundedRectangle(cornerRadius: palette.radius).stroke(palette.border, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: palette.radius))
        }
        .padding(.top, 28)
    }
}

@available(iOS 15.0, macOS 12.0, *)
private struct LinkRowView: View {
    let label: String
    let palette: CCPalette
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            HStack {
                Text(label).font(.system(size: 15, weight: .medium)).foregroundColor(palette.text)
                Spacer()
                Text("›").font(.system(size: 22)).foregroundColor(palette.muted)
            }
            .padding(.vertical, 15).padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@available(iOS 15.0, macOS 12.0, *)
struct PrimaryButtonView: View {
    let label: String
    let palette: CCPalette
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .bold)).foregroundColor(palette.onAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(palette.accent)
                .clipShape(RoundedRectangle(cornerRadius: palette.radius * 0.75))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .padding(.top, 10)
    }
}

@available(iOS 15.0, macOS 12.0, *)
struct SecondaryButtonView: View {
    let label: String
    let palette: CCPalette
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        let color = destructive ? palette.destructive : palette.text
        Button(action: action) {
            Text(label).font(.system(size: 15, weight: .bold)).foregroundColor(color)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .overlay(RoundedRectangle(cornerRadius: palette.radius * 0.75)
                    .stroke(destructive ? palette.destructive : palette.border, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
    }
}

// MARK: - Cancel flow sheet

@available(iOS 15.0, macOS 12.0, *)
private struct CancelFlowSheet: View {
    let flow: CancelFlow
    let config: CustomerCenterConfig
    let offers: [CustomerCenterOffer]
    let palette: CCPalette
    let t: Translator
    let onContinueSurvey: (_ reason: String?, _ comment: String) -> Void
    let onClaimOffer: (CustomerCenterOffer) -> Void
    let onDeclineOffer: () -> Void
    let onConfirmCancel: () -> Void
    let onDismiss: () -> Void

    @State private var selectedReason: String?
    @State private var comment: String = ""

    var body: some View {
        ZStack {
            palette.card.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch flow.step {
                    case .survey: surveyView
                    case .offer: offerView
                    case .retention: retentionView
                    }
                }
                .padding(22)
            }
        }
    }

    private var surveyView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(config.survey?.prompt.map { t($0, $0) } ?? t("surveyTitle", "Before you go…"))
                .font(.system(size: 19, weight: .heavy)).foregroundColor(palette.text)
            Text(t("surveyPrompt", "Tell us why you’re cancelling."))
                .font(.system(size: 14)).foregroundColor(palette.muted)
                .padding(.top, 6).padding(.bottom, 12)

            ForEach(config.survey?.reasons ?? [], id: \.self) { reason in
                let selected = selectedReason == reason
                Button { selectedReason = reason } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().stroke(selected ? palette.accent : palette.muted, lineWidth: 2).frame(width: 20, height: 20)
                            if selected { Circle().fill(palette.accent).frame(width: 10, height: 10) }
                        }
                        Text(t(reason, reason)).font(.system(size: 15)).foregroundColor(palette.text)
                        Spacer()
                    }
                    .padding(14)
                    .background(selected ? palette.accent.opacity(0.08) : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: palette.radius * 0.6)
                        .stroke(selected ? palette.accent : palette.border, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }

            if config.survey?.commentEnabled == true {
                // iOS 15-compatible multiline input: a TextEditor with a placeholder overlay.
                ZStack(alignment: .topLeading) {
                    if comment.isEmpty {
                        Text(t("commentPlaceholder", "Anything else? (optional)"))
                            .font(.system(size: 14)).foregroundColor(palette.muted)
                            .padding(.horizontal, 14).padding(.vertical, 16)
                    }
                    TextEditor(text: $comment)
                        .frame(minHeight: 72)
                        .padding(6)
                        .foregroundColor(palette.text)
                }
                .background(palette.subtle)
                .overlay(RoundedRectangle(cornerRadius: palette.radius * 0.6).stroke(palette.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: palette.radius * 0.6))
                .padding(.top, 4)
            }

            PrimaryButtonView(label: t("continue", "Continue"), palette: palette, disabled: selectedReason == nil) {
                onContinueSurvey(selectedReason, comment)
            }
            SecondaryButtonView(label: t("keepSubscription", "Keep my subscription"), palette: palette, action: onDismiss)
        }
    }

    private var offerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(config.retention?.message.map { t($0, $0) } ?? t("offerTitle", "Wait — here’s an exclusive offer"))
                .font(.system(size: 19, weight: .heavy)).foregroundColor(palette.text)
            Text(t("offerSubtitle", "Stay with us and save."))
                .font(.system(size: 14)).foregroundColor(palette.muted).padding(.top, 6).padding(.bottom, 12)

            ForEach(offers) { offer in
                VStack(alignment: .leading, spacing: 6) {
                    Text(offerHeadline(offer)).font(.system(size: 17, weight: .heavy)).foregroundColor(palette.accent)
                    Text(t(offer.title, offer.title)).font(.system(size: 15, weight: .bold)).foregroundColor(palette.text)
                    Text(t(offer.description, offer.description)).font(.system(size: 14)).foregroundColor(palette.muted)
                    PrimaryButtonView(label: t("offerCta", "Claim offer"), palette: palette) { onClaimOffer(offer) }
                }
                .padding(16)
                .background(palette.accent.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: palette.radius * 0.6).stroke(palette.accent, lineWidth: 1.5))
                .padding(.bottom, 12)
            }

            SecondaryButtonView(label: t("offerDecline", "No thanks, cancel"), palette: palette, destructive: true, action: onDeclineOffer)
        }
    }

    private var retentionView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(config.retention?.message.map { t($0, $0) } ?? t("retentionTitle", "Are you sure you want to cancel?"))
                .font(.system(size: 19, weight: .heavy)).foregroundColor(palette.text)
            if let offerText = config.retention?.offerText {
                Text(t(offerText, offerText))
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(palette.text)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: palette.radius * 0.6).stroke(palette.accent, lineWidth: 1.5))
                    .padding(.top, 14)
            }
            PrimaryButtonView(label: t("keepSubscription", "Keep my subscription"), palette: palette, action: onDismiss)
            SecondaryButtonView(label: t("continueCancel", "Continue cancelling"), palette: palette, destructive: true, action: onConfirmCancel)
        }
    }

    private func offerHeadline(_ offer: CustomerCenterOffer) -> String {
        let valueInt = offer.value == offer.value.rounded() ? String(Int(offer.value)) : String(offer.value)
        let forMonths: String = {
            guard let m = offer.durationMonths, m > 0 else { return "" }
            let unit = m == 1 ? t("offerMonth", "month") : t("offerMonths", "months")
            return " \(t("offerForMonths", "for")) \(m) \(unit)"
        }()
        switch offer.discountType {
        case .percent: return "\(t("offerGet", "Get")) \(valueInt)% \(t("offerOff", "off"))\(forMonths)"
        case .amount: return "\(t("offerGet", "Get")) \(valueInt) \(t("offerOff", "off"))\(forMonths)"
        case .freeMonths:
            let n = Int(offer.value)
            let unit = n == 1 ? t("offerFreeMonth", "free month") : t("offerFreeMonths", "free months")
            return "\(t("offerGet", "Get")) \(n) \(unit)"
        case .unknown: return offer.title
        }
    }
}

// MARK: - Fetch model

@available(iOS 15.0, macOS 12.0, *)
@MainActor
private final class CustomerCenterModel: ObservableObject {
    @Published var data: CustomerCenterData?
    @Published var loading = true
    @Published var loadError: Error?
    @Published var busyId: String?

    func load(appUserId: String?) async {
        loadError = nil
        if data == nil { loading = true }
        do {
            data = try await Purchases.shared.getCustomerCenter(appUserId: appUserId)
        } catch {
            loadError = error
        }
        loading = false
    }
}
#endif
