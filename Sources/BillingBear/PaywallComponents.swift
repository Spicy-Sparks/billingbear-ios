#if canImport(SwiftUI)
import SwiftUI

// MARK: - Paywall component catalog (native SwiftUI)
//
// The reusable building blocks the renderer composes into a paywall, all native SwiftUI so they
// render + animate with zero extra dependencies:
//
//   • ComparisonTableView   — feature × plan matrix (rows = features, columns = products, ✓/× cells)
//   • FreeTrialToggleView    — a Switch that flips the selection between a trial and a paid product
//   • PaywallTabsView        — a segmented tier switcher that filters the visible product set
//   • CountdownView          — a live ticking deadline timer (urgency)
//   • TimelineView           — a vertical "how it works" stepper with a connecting line
//
// They share the renderer's theming helpers (Color.css, themedFont, PaywallIcon) so a paywall keeps
// one coherent look. Pure formatting / cell logic lives in PaywallTransforms so it is unit-tested
// independently of the view layer.

@available(iOS 15.0, macOS 12.0, *)
struct PaywallComponentStyle {
    let theme: PaywallTheme
    let variables: [String: String]?

    var textColor: Color { Color.css(theme.textColor, fallback: .white) }
    var primary: Color { Color.css(theme.primaryColor, fallback: .accentColor) }
    var cardBg: Color { Color.css(theme.cardBackground, fallback: Color(white: 0.09)) }

    func t(_ s: String?) -> String? {
        guard let s else { return nil }
        return PaywallTransforms.interpolate(s, variables)
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        if let family = theme.fontFamily, !family.isEmpty {
            return .custom(family, size: size)
        }
        return .system(size: size, weight: weight)
    }
}

// MARK: - Comparison table

/// Feature × plan matrix for the `comparison-table` layout. Header row = product columns (with
/// badge + highlight styling), body rows = features, cells = ✓ (primary) or × (dimmed) driven by
/// each product's `featureMatches`. Mirrors the web ComparisonTable shape. Horizontally scrollable
/// when there are many columns so it never clips on a phone.
@available(iOS 15.0, macOS 12.0, *)
struct ComparisonTableView: View {
    let products: [PaywallProduct]
    let features: [PaywallFeature]
    let style: PaywallComponentStyle
    let cardRadius: CGFloat

    private let featureColWidth: CGFloat = 140
    private let planColWidth: CGFloat = 92

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 0) {
                headerRow
                ForEach(Array(features.enumerated()), id: \.offset) { fIdx, feature in
                    Divider().background(style.textColor.opacity(0.08))
                    bodyRow(feature: feature, featureIndex: fIdx)
                }
            }
            .background(style.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("Feature")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(style.textColor.opacity(0.6))
                .frame(width: featureColWidth, alignment: .leading)

            ForEach(products, id: \.identifier) { product in
                VStack(spacing: 2) {
                    Text(style.t(product.label) ?? "")
                        .font(style.font(size: 12, weight: product.highlight == true ? .bold : .semibold))
                        .foregroundColor(product.highlight == true ? style.primary : style.textColor)
                        .multilineTextAlignment(.center)
                    if let badge = style.t(product.badge) {
                        Text(badge.uppercased())
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(Color.css(style.theme.ctaTextColor, fallback: .white))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(style.primary)
                            .clipShape(Capsule())
                    }
                    if let sub = style.t(product.sublabel) {
                        Text(sub)
                            .font(.system(size: 9))
                            .foregroundColor(style.textColor.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(width: planColWidth)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
    }

    private func bodyRow(feature: PaywallFeature, featureIndex: Int) -> some View {
        HStack(spacing: 0) {
            Text(style.t(feature.text) ?? "")
                .font(style.font(size: 12, weight: .regular))
                .foregroundColor(style.textColor)
                .frame(width: featureColWidth, alignment: .leading)

            ForEach(products, id: \.identifier) { product in
                cell(on: PaywallTransforms.comparisonCellOn(product, featureIndex: featureIndex))
                    .frame(width: planColWidth)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func cell(on: Bool) -> some View {
        if on {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(style.primary)
        } else {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(style.textColor.opacity(0.3))
        }
    }
}

// MARK: - Free-trial toggle

/// A Switch that selects between a free-trial product and a paid product. Flipping ON writes the
/// trial product's identifier into the bound selection; OFF writes the paid product's. Resolves
/// product ids from the document if the toggle config omits them (trial = first product with
/// trialDays > 0; paid = first without). No-ops gracefully if neither can be resolved.
@available(iOS 15.0, macOS 12.0, *)
struct FreeTrialToggleView: View {
    let config: PaywallTrialToggle
    let products: [PaywallProduct]
    let style: PaywallComponentStyle
    let cardRadius: CGFloat
    @Binding var selectedProductId: String?
    @State private var isOn: Bool

    init(
        config: PaywallTrialToggle,
        products: [PaywallProduct],
        style: PaywallComponentStyle,
        cardRadius: CGFloat,
        selectedProductId: Binding<String?>
    ) {
        self.config = config
        self.products = products
        self.style = style
        self.cardRadius = cardRadius
        self._selectedProductId = selectedProductId
        self._isOn = State(initialValue: config.defaultOn ?? true)
    }

    private var trialId: String? {
        config.trialProductId ?? products.first(where: { ($0.trialDays ?? 0) > 0 })?.identifier
    }

    private var paidId: String? {
        config.paidProductId ?? products.first(where: { ($0.trialDays ?? 0) == 0 })?.identifier
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(style.t(config.label) ?? "Enable free trial")
                    .font(style.font(size: 15, weight: .semibold))
                    .foregroundColor(style.textColor)
                if let caption = style.t(config.caption) {
                    Text(caption)
                        .font(style.font(size: 12, weight: .regular))
                        .foregroundColor(style.textColor.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(style.primary)
                .accessibilityLabel(style.t(config.label) ?? "Free trial")
        }
        .padding(14)
        .background(style.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .onAppear { apply(isOn) }
        .onChange(of: isOn) { apply($0) }
    }

    private func apply(_ on: Bool) {
        if on {
            if let id = trialId { selectedProductId = id }
        } else {
            if let id = paidId { selectedProductId = id }
        }
    }
}

// MARK: - Tabs (tier switcher)

/// A pill segmented control. Selecting a tab calls `onSelect` so the renderer can filter the
/// product list. The active pill is filled with the primary colour; inactive pills are dimmed.
@available(iOS 15.0, macOS 12.0, *)
struct PaywallTabsView: View {
    let tabs: [PaywallTab]
    let style: PaywallComponentStyle
    @Binding var selectedTabId: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.id) { tab in
                let active = selectedTabId == tab.id
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selectedTabId = tab.id }
                } label: {
                    HStack(spacing: 5) {
                        Text(style.t(tab.label) ?? tab.label)
                            .font(style.font(size: 13, weight: active ? .bold : .medium))
                        if let badge = style.t(tab.badge) {
                            Text(badge.uppercased())
                                .font(.system(size: 8, weight: .black))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background((active ? Color.css(style.theme.ctaTextColor, fallback: .white) : style.primary).opacity(0.25))
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundColor(active ? Color.css(style.theme.ctaTextColor, fallback: .white) : style.textColor.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(active ? style.primary : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(style.textColor.opacity(0.08))
        .clipShape(Capsule())
    }
}

// MARK: - Countdown

/// A live deadline timer. Ticks once a second on a SwiftUI Timer publisher and renders the
/// remaining time via the shared `formatCountdown` helper. Disappears (renders nothing) once the
/// deadline passes — matching the web behaviour where an expired deal hides the ticker.
@available(iOS 15.0, macOS 12.0, *)
struct CountdownView: View {
    let deadline: Date
    let accent: Color
    let monospaced: Bool

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let remaining = Int(deadline.timeIntervalSince(now).rounded(.down))
        Group {
            if remaining > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .semibold))
                    Text(PaywallTransforms.formatCountdown(remaining: remaining))
                        .font(.system(size: 12, weight: .bold, design: monospaced ? .monospaced : .default))
                }
                .foregroundColor(accent)
            }
        }
        .onReceive(tick) { now = $0 }
    }
}

/// Urgency banner: optional headline + an optional live countdown, tinted by the urgency tone.
/// Renders nothing when there is neither text nor an active deadline.
@available(iOS 15.0, macOS 12.0, *)
struct UrgencyBannerView: View {
    let urgency: PaywallUrgency
    let style: PaywallComponentStyle

    private static let toneColors: [String: String] = [
        "limited": "#f59e0b",
        "discount": "#10b981",
        "trial": "#6366f1",
        "lastChance": "#ef4444"
    ]

    private var accent: Color {
        if let tone = urgency.tone, let hex = Self.toneColors[tone], let c = Color(css: hex) { return c }
        return style.primary
    }

    var body: some View {
        let deadline = PaywallTransforms.parseISODate(urgency.endsAt)
        let active = (deadline.map { $0.timeIntervalSinceNow > 0 } ?? false)
        let text = style.t(urgency.bannerText)
        Group {
            if text != nil || active {
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: urgency.tone == "lastChance" ? "exclamationmark.triangle.fill" : "clock.fill")
                            .font(.system(size: 11, weight: .semibold))
                        if let text {
                            Text(text)
                                .font(style.font(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundColor(accent)
                    Spacer(minLength: 0)
                    if let deadline, active {
                        CountdownView(deadline: deadline, accent: accent, monospaced: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(accent.opacity(0.13))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(accent.opacity(0.33), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }
}

// MARK: - Timeline

/// Vertical "how it works" stepper. Each step is a node (icon or number) with a connecting line to
/// the next, plus a label/title/description. The connecting line is drawn behind the nodes so it
/// threads continuously, RevenueCat onboarding-style.
@available(iOS 15.0, macOS 12.0, *)
struct TimelineView: View {
    let timeline: PaywallTimeline
    let style: PaywallComponentStyle

    private let nodeSize: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let heading = style.t(timeline.heading) {
                Text(heading)
                    .font(style.font(size: 16, weight: .bold))
                    .foregroundColor(style.textColor)
                    .padding(.bottom, 14)
            }
            ForEach(Array(timeline.steps.enumerated()), id: \.offset) { idx, step in
                row(step: step, index: idx, isLast: idx == timeline.steps.count - 1)
            }
        }
    }

    private func row(step: PaywallTimelineStep, index: Int, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(style.primary.opacity(0.15)).frame(width: nodeSize, height: nodeSize)
                    if let icon = step.icon {
                        Image(systemName: PaywallIcon.symbol(for: icon))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(style.primary)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(style.primary)
                    }
                }
                if !isLast {
                    Rectangle()
                        .fill(style.primary.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: nodeSize)

            VStack(alignment: .leading, spacing: 2) {
                if let label = style.t(step.label) {
                    Text(label.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundColor(style.primary)
                }
                Text(style.t(step.title) ?? "")
                    .font(style.font(size: 15, weight: .semibold))
                    .foregroundColor(style.textColor)
                if let desc = style.t(step.description) {
                    Text(desc)
                        .font(style.font(size: 13, weight: .regular))
                        .foregroundColor(style.textColor.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 18)
            Spacer(minLength: 0)
        }
    }
}
#endif
