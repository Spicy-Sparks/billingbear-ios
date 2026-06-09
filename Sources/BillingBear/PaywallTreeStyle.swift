#if canImport(SwiftUI)
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PaywallStyle → SwiftUI modifiers
//
// Maps the v2 PaywallStyle CSS subset onto SwiftUI view modifiers, in the order CSS resolves:
// padding (inside) → background/shape (the box) → border/shadow → frame (size) → margin (outside) →
// opacity → position. Typography is applied at the Text leaf (PaywallTypography) so non-text nodes
// don't inherit a font; this modifier handles the box-model + visual styling.

@available(iOS 15.0, macOS 12.0, *)
extension View {
    func paywallStyle(_ style: PaywallStyle?, ctx: PaywallTreeContext, isRoot: Bool) -> some View {
        modifier(PaywallStyleModifier(style: style, ctx: ctx, isRoot: isRoot))
    }

    /// Apply a transform only when an optional value is present (keeps the modifier chain readable).
    @ViewBuilder
    func ifLet<T, Content: View>(_ value: T?, transform: (Self, T) -> Content) -> some View {
        if let value { transform(self, value) } else { self }
    }
}

@available(iOS 15.0, macOS 12.0, *)
struct PaywallStyleModifier: ViewModifier {
    let style: PaywallStyle?
    let ctx: PaywallTreeContext
    let isRoot: Bool

    func body(content: Content) -> some View {
        guard let style else {
            // Root with no style still wants the full-bleed safe-area padding handled by the tree.
            return AnyView(content)
        }
        var view = AnyView(content)

        // 1. padding (inner)
        if let pad = style.padding {
            view = AnyView(view.padding(EdgeInsets(top: pad.top, leading: pad.left, bottom: pad.bottom, trailing: pad.right)))
        }

        // 2. background + shape (clip happens via the shape so the bg respects corners)
        view = AnyView(view.modifier(PaywallBackgroundModifier(style: style, ctx: ctx)))

        // 3. border
        if let border = style.border {
            view = AnyView(view.overlay(borderShape(border, corners: style.cornerRadius)))
        }

        // 4. shadow
        if let shadow = style.shadow {
            let c = (shadow.color.flatMap { Color(css: $0) } ?? .black).opacity(shadow.opacity ?? 0.25)
            view = AnyView(view.shadow(color: c, radius: shadow.radius, x: shadow.x ?? 0, y: shadow.y ?? 0))
        }

        // 5. frame (size). Width/height (fill/hug/percent/points) + min/max + grow.
        view = AnyView(view.modifier(PaywallFrameModifier(style: style, isRoot: isRoot)))

        // 6. margin (outer)
        if let margin = style.margin {
            view = AnyView(view.padding(EdgeInsets(top: margin.top, leading: margin.left, bottom: margin.bottom, trailing: margin.right)))
        }

        // 7. opacity
        if let opacity = style.opacity {
            view = AnyView(view.opacity(opacity))
        }

        // 8. alignSelf (cross-axis override) → frame alignment hint
        if let alignSelf = style.alignSelf {
            view = AnyView(view.frame(maxWidth: alignSelf == .stretch ? .infinity : nil, alignment: alignSelfAlignment(alignSelf)))
        }

        // 9. position (relative offset / absolute via offset+zIndex)
        view = AnyView(view.modifier(PaywallPositionModifier(style: style)))

        return view
    }

    @ViewBuilder
    private func borderShape(_ border: PaywallBorder, corners: PaywallCornerRadius?) -> some View {
        let color = Color(css: border.color) ?? .clear
        let dash: [CGFloat] = {
            switch border.style ?? .solid {
            case .solid: return []
            case .dashed: return [6, 4]
            case .dotted: return [1, 3]
            }
        }()
        if let corners, !corners.isUniform {
            PaywallRoundedShape(corners: corners)
                .stroke(color, style: StrokeStyle(lineWidth: border.width, dash: dash))
        } else {
            RoundedRectangle(cornerRadius: corners?.topLeft ?? 0, style: .continuous)
                .stroke(color, style: StrokeStyle(lineWidth: border.width, dash: dash))
        }
    }

    private func alignSelfAlignment(_ a: PaywallAlignSelf) -> Alignment {
        switch a {
        case .start: return .leading
        case .center: return .center
        case .end: return .trailing
        case .stretch: return .center
        }
    }
}

// MARK: - Background modifier (solid / gradient / image / video / lottie / theme), clipped to shape

@available(iOS 15.0, macOS 12.0, *)
struct PaywallBackgroundModifier: ViewModifier {
    let style: PaywallStyle
    let ctx: PaywallTreeContext

    func body(content: Content) -> some View {
        let shape = PaywallShapeRef(corners: style.cornerRadius)
        let clip = style.clip ?? (style.cornerRadius != nil)
        content
            .background(backgroundView.clipShape(shape))
            .ifLet(clip ? shape : nil) { v, s in v.clipShape(s) }
    }

    @ViewBuilder
    private var backgroundView: some View {
        ZStack {
            if style.useThemeBackground == true {
                // Per-node theme background. The solid theme color underlays gradient/video/lottie.
                Color.css(ctx.theme.background, fallback: .clear)
                paywallBackground(ctx.theme, solid: Color.css(ctx.theme.background, fallback: .clear))
            }
            if let solid = style.background, let c = Color(css: ctx.interpolate(solid, selectedProduct: nil)) {
                c
            }
            if let g = style.backgroundGradient {
                PaywallGradientView(gradient: g, fallback: .clear)
            }
            if let img = style.backgroundImage {
                ZStack {
                    RemoteImage(url: img.url, contentMode: img.size == "contain" ? .fit : .fill)
                        .opacity(img.opacity ?? 1)
                    if let overlay = img.overlay, let c = Color(css: overlay) { c }
                }
            }
            #if canImport(UIKit)
            if let v = style.backgroundVideo, let u = URL(string: v.url) {
                PaywallVideoView(url: u, loop: v.loop ?? true, muted: v.muted ?? true)
            }
            if let l = style.backgroundLottie, let u = URL(string: l.url) {
                PaywallLottieView(url: u, loop: l.loop ?? true, autoplay: l.autoplay ?? true, speed: l.speed ?? 1)
            }
            #endif
        }
    }
}

/// A type-erased shape that picks a uniform RoundedRectangle or the per-corner PaywallRoundedShape.
@available(iOS 15.0, macOS 12.0, *)
struct PaywallShapeRef: InsettableShape {
    let corners: PaywallCornerRadius?
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        guard let corners else { return Path(r) }
        if corners.isUniform {
            return RoundedRectangle(cornerRadius: corners.topLeft, style: .continuous).path(in: r)
        }
        return PaywallRoundedShape(corners: corners).path(in: r)
    }

    func inset(by amount: CGFloat) -> PaywallShapeRef {
        var copy = self
        copy.inset += amount
        return copy
    }
}

/// Per-corner rounded rectangle (used when cornerRadius is a per-corner object).
@available(iOS 15.0, macOS 12.0, *)
struct PaywallRoundedShape: Shape {
    let corners: PaywallCornerRadius

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = min(CGFloat(corners.topLeft), min(rect.width, rect.height) / 2)
        let tr = min(CGFloat(corners.topRight), min(rect.width, rect.height) / 2)
        let br = min(CGFloat(corners.bottomRight), min(rect.width, rect.height) / 2)
        let bl = min(CGFloat(corners.bottomLeft), min(rect.width, rect.height) / 2)

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - Frame modifier (size resolution)

@available(iOS 15.0, macOS 12.0, *)
struct PaywallFrameModifier: ViewModifier {
    let style: PaywallStyle
    let isRoot: Bool

    func body(content: Content) -> some View {
        content.modifier(SizeApply(style: style))
            .modifier(MinMaxApply(style: style))
            .modifier(GrowApply(style: style))
    }

    /// width/height (points/fill/hug/percent). Percent needs a GeometryReader-relative frame.
    struct SizeApply: ViewModifier {
        let style: PaywallStyle
        @Environment(\.paywallInFlow) private var inFlow
        func body(content: Content) -> some View {
            let w = style.width
            let h = style.height
            let needsGeo = isPercent(w) || isPercent(h)
            // Percent-width flow children are sized by the flow itself (it proposes the resolved width):
            // accept the proposal at natural height instead of a GeometryReader, which would collapse
            // the height and make the cards overlap.
            if inFlow, isPercent(w), !isPercent(h) {
                return AnyView(content.frame(maxWidth: .infinity, alignment: .topLeading))
            }
            if needsGeo {
                return AnyView(
                    GeometryReader { geo in
                        content
                            .frame(
                                width: dimension(w, parent: geo.size.width),
                                height: dimension(h, parent: geo.size.height)
                            )
                    }
                )
            }
            return AnyView(
                content
                    .frame(
                        width: fixed(w),
                        height: fixed(h),
                        alignment: .center
                    )
                    .modifier(FillApply(width: w, height: h))
                    .modifier(HugApply(width: w, height: h))
            )
        }

        private func isPercent(_ s: PaywallSize?) -> Bool {
            if case .percent = s { return true }
            return false
        }
        private func fixed(_ s: PaywallSize?) -> CGFloat? {
            if case .points(let v) = s { return CGFloat(v) }
            return nil
        }
        private func dimension(_ s: PaywallSize?, parent: CGFloat) -> CGFloat? {
            switch s {
            case .points(let v): return CGFloat(v)
            case .percent(let p): return parent * CGFloat(p) / 100
            case .fill: return parent
            default: return nil
            }
        }
    }

    /// fill = expand to parent (maxWidth/Height .infinity).
    struct FillApply: ViewModifier {
        let width: PaywallSize?
        let height: PaywallSize?
        func body(content: Content) -> some View {
            content.frame(
                maxWidth: width == .fill ? .infinity : nil,
                maxHeight: height == .fill ? .infinity : nil
            )
        }
    }

    /// hug = wrap content (fixedSize on that axis).
    struct HugApply: ViewModifier {
        let width: PaywallSize?
        let height: PaywallSize?
        func body(content: Content) -> some View {
            content.fixedSize(horizontal: width == .hug, vertical: height == .hug)
        }
    }

    struct MinMaxApply: ViewModifier {
        let style: PaywallStyle
        func body(content: Content) -> some View {
            content.frame(
                minWidth: style.minWidth.map { CGFloat($0) },
                maxWidth: style.maxWidth.map { CGFloat($0) },
                minHeight: style.minHeight.map { CGFloat($0) },
                maxHeight: style.maxHeight.map { CGFloat($0) }
            )
        }
    }

    /// grow > 0 → expand on the main axis (modeled as maxWidth/.infinity; SwiftUI weights with layoutPriority).
    struct GrowApply: ViewModifier {
        let style: PaywallStyle
        func body(content: Content) -> some View {
            if let grow = style.grow, grow > 0 {
                content.frame(maxWidth: .infinity).layoutPriority(grow)
            } else {
                content
            }
        }
    }
}

// MARK: - Position modifier

@available(iOS 15.0, macOS 12.0, *)
struct PaywallPositionModifier: ViewModifier {
    let style: PaywallStyle

    /// True when this node is taken out of normal flow (absolute / fixed / sticky). The enclosing
    /// layered stack reads this (via PaywallStyle.isOutOfFlow) to place the node in an alignment
    /// overlay rather than the in-flow ZStack content, so top/right/bottom/left resolve against the
    /// positioned ancestor's edges — the SwiftUI analogue of CSS `position: absolute`.
    func body(content: Content) -> some View {
        switch style.position ?? .normal {
        case .normal:
            content
        case .relative:
            // In-flow, but visually offset (CSS `relative`). left/right and top/bottom are mutually
            // exclusive in CSS; left/top win, else fall back to the inverse of right/bottom.
            let o = style.positionOffset
            content
                .offset(x: o.width, y: o.height)
                .zIndex(style.zIndex ?? 0)
        case .absolute, .fixed, .sticky:
            // Out-of-flow: anchored to an edge of the positioned ancestor by whichever of
            // top/right/bottom/left is set. A positive `right`/`bottom` insets FROM that edge, so the
            // sign is inverted relative to left/top. The layered parent supplies the alignment frame
            // (PaywallStackView.layeredContent overlay) that makes the anchor edge meaningful.
            let o = style.positionOffset
            content
                .offset(x: o.width, y: o.height)
                .zIndex(style.zIndex ?? 1)
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
extension PaywallStyle {
    /// Whether this node is removed from normal flow (CSS absolute/fixed/sticky). Used by the layered
    /// stack to route the child into an edge-anchored overlay instead of the in-flow stack.
    var isOutOfFlow: Bool {
        switch position ?? .normal {
        case .absolute, .fixed, .sticky: return true
        case .normal, .relative: return false
        }
    }

    /// `position: fixed` — anchored to the paywall VIEWPORT, not the nearest positioned ancestor.
    /// These nodes are hoisted to a single root-level overlay (a global close button must sit at the
    /// screen's top-right, above the scrolling content — anchoring it to a scroll container instead
    /// drops it onto the first content row, e.g. over the title).
    var isFixed: Bool { (position ?? .normal) == .fixed }

    /// The alignment an out-of-flow child anchors to, derived from which insets are set. Defaults to
    /// top-leading (CSS's static-position origin when no inset wins on an axis).
    var outOfFlowAlignment: Alignment {
        Alignment(horizontal: PaywallPositionMath.horizontal(left: left, right: right),
                  vertical: PaywallPositionMath.vertical(top: top, bottom: bottom))
    }

    /// The (x, y) offset this position style applies (left/top win; else inverse of right/bottom).
    var positionOffset: CGSize {
        PaywallPositionMath.offset(top: top, right: right, bottom: bottom, left: left)
    }
}

/// Pure CSS-position math (offset + anchor), extracted for unit testing. CSS rules: on each axis the
/// near inset (left / top) wins; if only the far inset (right / bottom) is set, the offset is its
/// negative and the node anchors to the far edge.
@available(iOS 15.0, macOS 12.0, *)
enum PaywallPositionMath {
    static func offset(top: Double?, right: Double?, bottom: Double?, left: Double?) -> CGSize {
        let x = left ?? right.map { -$0 } ?? 0
        let y = top ?? bottom.map { -$0 } ?? 0
        return CGSize(width: x, height: y)
    }

    static func horizontal(left: Double?, right: Double?) -> HorizontalAlignment {
        (right != nil && left == nil) ? .trailing : .leading
    }

    static func vertical(top: Double?, bottom: Double?) -> VerticalAlignment {
        (bottom != nil && top == nil) ? .bottom : .top
    }
}

// MARK: - Typography modifier (Text-leaf only)

@available(iOS 15.0, macOS 12.0, *)
struct PaywallTypography: ViewModifier {
    let style: PaywallStyle?
    let ctx: PaywallTreeContext
    var defaultWeight: Font.Weight = .regular
    var defaultColor: Color? = nil
    var monospacedDigits: Bool = false

    func body(content: Content) -> some View {
        let size = CGFloat(style?.fontSize ?? 16)
        let weight = PaywallFontResolver.weight(style?.fontWeight?.value) ?? defaultWeight
        let family = style?.fontFamily ?? ctx.theme.fontFamily
        let color = style?.color.flatMap { Color(css: ctx.interpolate($0, selectedProduct: nil)) } ?? defaultColor ?? ctx.textColor

        var font = PaywallFontResolver.font(family: family, size: size, weight: weight)
        if monospacedDigits {
            font = font.monospacedDigit()
        }

        return content
            .font(font)
            .foregroundColor(color)
            .ifLet(style?.lineHeight) { v, lh in v.lineSpacing(max(0, CGFloat(lh) - size)) }
            .modifier(LetterSpacing(value: style?.letterSpacing))
            .multilineTextAlignment(textAlign(style?.textAlign))
            .frame(maxWidth: .infinity, alignment: frameAlignment(style?.textAlign))
    }

    private func textAlign(_ a: PaywallTextAlign?) -> TextAlignment {
        switch a ?? .left {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func frameAlignment(_ a: PaywallTextAlign?) -> Alignment {
        switch a ?? .left {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

/// Letter spacing (kerning). `View.tracking` is iOS 16 / macOS 13; on older OSes the spacing is a
/// no-op (the text still renders, just without the kern adjustment).
@available(iOS 15.0, macOS 12.0, *)
struct LetterSpacing: ViewModifier {
    let value: Double?
    func body(content: Content) -> some View {
        if let value {
            if #available(iOS 16.0, macOS 13.0, *) {
                content.tracking(CGFloat(value))
            } else {
                content
            }
        } else {
            content
        }
    }
}

// MARK: - Entry animation timing

@available(iOS 15.0, macOS 12.0, *)
extension PaywallAnimation {
    /// The schema/web renderer expresses `duration` and `delay` in MILLISECONDS (web defaults
    /// `duration ?? 400`, `delay ?? 0`). SwiftUI's `withAnimation` takes SECONDS, so convert. A
    /// missing duration matches the web's 400 ms default; a missing delay is 0.
    var durationSeconds: Double { (duration ?? 400) / 1000.0 }
    var delaySeconds: Double { (delay ?? 0) / 1000.0 }
}

// MARK: - Entry animation modifier

@available(iOS 15.0, macOS 12.0, *)
struct PaywallEntryAnimation: ViewModifier {
    let animation: PaywallAnimation?
    let appeared: Bool

    func body(content: Content) -> some View {
        guard let animation else { return AnyView(content) }
        let hidden = !appeared
        switch animation.type {
        case "fade":
            return AnyView(content.opacity(hidden ? 0 : 1))
        case "fade-up", "slide-up":
            return AnyView(content.opacity(hidden ? 0 : 1).offset(y: hidden ? 16 : 0))
        case "fade-down", "slide-down":
            return AnyView(content.opacity(hidden ? 0 : 1).offset(y: hidden ? -16 : 0))
        case "slide-left":
            return AnyView(content.opacity(hidden ? 0 : 1).offset(x: hidden ? 24 : 0))
        case "slide-right":
            return AnyView(content.opacity(hidden ? 0 : 1).offset(x: hidden ? -24 : 0))
        case "scale":
            return AnyView(content.opacity(hidden ? 0 : 1).scaleEffect(hidden ? 0.92 : 1))
        default:
            return AnyView(content.opacity(hidden ? 0 : 1))
        }
    }
}

// MARK: - Tap modifier (action + haptic)

@available(iOS 15.0, macOS 12.0, *)
struct PaywallTapModifier: ViewModifier {
    let action: PaywallAction?
    let haptic: PaywallHaptic?
    let ctx: PaywallTreeContext

    func body(content: Content) -> some View {
        if let action {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    PaywallHapticEngine.fire(haptic ?? .light)
                    ctx.onAction(action)
                }
        } else {
            content
        }
    }
}

// MARK: - Flow layout (for stack wrap)

/// A minimal flow layout: lays children left-to-right, wrapping to the next line when the row width
/// is exceeded. Used by horizontal stacks with `wrap: true` (badge rows, feature chips).
@available(iOS 16.0, macOS 13.0, *)
struct PaywallFlowLayoutNative: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(childProposal(sub, rowWidth: maxWidth))
            if rowWidth + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                totalHeight += rowHeight + spacing
                rows.append([])
                rowWidth = 0
                rowHeight = 0
            }
            rows[rows.count - 1].append(size)
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? rowWidth : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(childProposal(sub, rowWidth: bounds.width))
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    /// A percent-width child (e.g. a 47% grid card) declares its fraction via `PercentWidthValue`; we
    /// resolve it against the row width and propose that exact width so the card fills it at its
    /// natural height. (A child can't self-resolve percent — its GeometryReader would collapse the
    /// height and the cards would overlap.) Non-percent children get an unconstrained proposal so they
    /// hug their content.
    private func childProposal(_ sub: LayoutSubview, rowWidth: CGFloat) -> ProposedViewSize {
        let frac = sub[PercentWidthValue.self]
        if frac > 0, rowWidth != .infinity {
            return ProposedViewSize(width: rowWidth * frac, height: nil)
        }
        return ProposedViewSize(width: nil, height: nil)
    }
}

/// Carries a flow child's percent width fraction (0...1) to `PaywallFlowLayoutNative` so it can
/// resolve percent against the row width itself. 0 = not a percent child (hug/natural).
@available(iOS 16.0, macOS 13.0, *)
struct PercentWidthValue: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// True while a node renders as a direct child of a flow (wrap) stack. `SizeApply` reads it: a
/// percent-width flow child must NOT self-resolve percent (the flow proposes its width instead), so
/// it just accepts the proposed width at natural height rather than wrapping in a GeometryReader.
private struct PaywallInFlowKey: EnvironmentKey {
    static let defaultValue: Bool = false
}
extension EnvironmentValues {
    var paywallInFlow: Bool {
        get { self[PaywallInFlowKey.self] }
        set { self[PaywallInFlowKey.self] = newValue }
    }
}

/// Applies the flow's `PercentWidthValue` layout value (iOS 16+) carrying a child's percent fraction.
struct PercentWidthLayoutValue: ViewModifier {
    let fraction: CGFloat?
    func body(content: Content) -> some View {
        if #available(iOS 16.0, macOS 13.0, *), let f = fraction {
            content.layoutValue(key: PercentWidthValue.self, value: f)
        } else {
            content
        }
    }
}

/// iOS 15-compatible flow wrapper: uses the native Layout on iOS 16+, else falls back to a simple
/// VStack of HStacks built at render time (good enough for small wrap groups on iOS 15).
@available(iOS 15.0, macOS 12.0, *)
struct PaywallFlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            PaywallFlowLayoutNative(spacing: spacing) { content() }
        } else {
            // iOS 15 fallback: a plain HStack that wraps via fixedSize is not possible, so we let it
            // scroll horizontally instead of clipping — the content stays fully reachable.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) { content() }
            }
        }
    }
}

// MARK: - Font resolution

/// Resolves a SwiftUI Font for a custom family name with a graceful system fallback. The host app
/// is expected to register custom fonts (Info.plist UIAppFonts / CTFontManager); when a family isn't
/// available `.custom` still falls back to the system font at the requested size, so a missing font
/// never blanks the text.
@available(iOS 15.0, macOS 12.0, *)
enum PaywallFontResolver {
    static func font(family: String?, size: CGFloat, weight: Font.Weight) -> Font {
        if let family, !family.isEmpty, !isSystemFamily(family) {
            // .custom honors the dynamic weight via .weight() applied after.
            return Font.custom(family, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    /// Map a CSS font-weight (numeric or keyword) to a SwiftUI Font.Weight.
    static func weight(_ raw: String?) -> Font.Weight? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let n = Int(raw) {
            switch n {
            case ..<150: return .ultraLight
            case 150..<250: return .thin
            case 250..<350: return .light
            case 350..<450: return .regular
            case 450..<550: return .medium
            case 550..<650: return .semibold
            case 650..<750: return .bold
            case 750..<850: return .heavy
            default: return .black
            }
        }
        switch raw.lowercased() {
        case "thin": return .thin
        case "ultralight", "ultra-light": return .ultraLight
        case "light": return .light
        case "normal", "regular": return .regular
        case "medium": return .medium
        case "semibold", "semi-bold", "demibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return nil
        }
    }

    private static func isSystemFamily(_ family: String) -> Bool {
        let f = family.lowercased()
        return f == "system" || f == "-apple-system" || f == "sf pro" || f == "sf-pro" || f == "default"
    }
}

// MARK: - Icon classification (SF Symbol / emoji)

@available(iOS 15.0, macOS 12.0, *)
enum PaywallIconClassifier {
    /// A bare emoji renders as text everywhere. Heuristic: the string's first scalar is in an emoji
    /// range / has the emoji presentation property.
    static func isEmoji(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        if first.properties.isEmoji && (first.value > 0x238C || first.properties.isEmojiPresentation) {
            return true
        }
        // Multi-scalar emoji (ZWJ sequences, flags) — if any scalar is emoji-presentation.
        return s.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    /// Resolve an icon name to an SF Symbol that is GUARANTEED to render. Resolution order:
    ///   1. the builder's named-icon alias table (shared with the v1 feature icons),
    ///   2. the raw name verbatim IF it is a real SF Symbol (authors can use "bolt.fill" etc.),
    ///   3. a neutral fallback symbol — NEVER the raw name as a glyph and NEVER a blank.
    /// The web renderer falls back to `•` for an unmapped identifier (resolveIconGlyph); the native
    /// equivalent is a real SF Symbol so the icon always paints. Mirrors that "never leak the raw
    /// token" guarantee — an invalid systemName on iOS otherwise draws *nothing* (an empty Image).
    static func symbolName(_ name: String) -> String {
        let lower = name.lowercased()
        let aliased = PaywallIcon.symbol(for: name)
        // PaywallIcon.symbol returns "checkmark" for unknown names; if the input wasn't one of its
        // known aliases, prefer the raw name when it is a valid SF Symbol the table doesn't list.
        if aliased == "checkmark" && lower != "check" && lower != "checkmark" {
            if isValidSymbol(name) { return name }
            // Try a dot/underscore-normalised variant (Material "lock_open" → SF "lock.open") before
            // giving up — covers Android-authored names rendered on iOS.
            let dotted = name.replacingOccurrences(of: "_", with: ".")
            if dotted != name, isValidSymbol(dotted) { return dotted }
            return fallbackSymbol
        }
        return aliased
    }

    /// Neutral fallback glyph — the SF-Symbol counterpart of the web renderer's `•`. A filled small
    /// circle that exists on every supported OS, so an unresolvable icon name still paints something.
    static let fallbackSymbol = "circle.fill"

    /// Whether `name` resolves to a real SF Symbol. On platforms without UIKit (macOS-without-AppKit
    /// SwiftUI previews / Linux test host) we can't introspect the symbol catalog, so we optimistically
    /// accept the name (SwiftUI on those targets degrades gracefully) — the guarantee that matters in
    /// production is the iOS path, which validates against the live catalog via UIImage(systemName:).
    static func isValidSymbol(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #else
        return true
        #endif
    }
}

// MARK: - Timer formatting (DD HH mm ss tokens)

@available(iOS 15.0, macOS 12.0, *)
enum PaywallTimerFormatter {
    /// Format remaining seconds against a token pattern (default "HH:mm:ss"). Tokens:
    ///   DD = days (zero-padded to 2), HH = hours, mm = minutes, ss = seconds.
    /// Anything that isn't a token is emitted verbatim (so ":" / " " separators survive).
    static func format(remaining seconds: Int, pattern: String?) -> String {
        let total = Swift.max(0, seconds)
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        let p = (pattern?.isEmpty == false ? pattern! : "HH:mm:ss")

        var out = ""
        var i = p.startIndex
        func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        while i < p.endIndex {
            if matches(p, at: i, "DD") { out += pad(days); i = p.index(i, offsetBy: 2); continue }
            if matches(p, at: i, "HH") { out += pad(hours); i = p.index(i, offsetBy: 2); continue }
            if matches(p, at: i, "mm") { out += pad(minutes); i = p.index(i, offsetBy: 2); continue }
            if matches(p, at: i, "ss") { out += pad(secs); i = p.index(i, offsetBy: 2); continue }
            out.append(p[i])
            i = p.index(after: i)
        }
        return out
    }

    private static func matches(_ s: String, at index: String.Index, _ token: String) -> Bool {
        guard let end = s.index(index, offsetBy: token.count, limitedBy: s.endIndex) else { return false }
        return s[index..<end] == token
    }
}

// MARK: - Haptics

@available(iOS 15.0, macOS 12.0, *)
enum PaywallHapticEngine {
    static func fire(_ haptic: PaywallHaptic) {
        #if canImport(UIKit) && os(iOS)
        switch haptic {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        #endif
    }
}

// MARK: - TabView style application helper (type-erase across styles)

@available(iOS 15.0, macOS 12.0, *)
extension View {
    @ViewBuilder
    func applyTabStyle(_ style: any TabViewStyle) -> some View {
        #if os(iOS)
        if let page = style as? PageTabViewStyle {
            self.tabViewStyle(page)
        } else {
            self.tabViewStyle(.automatic)
        }
        #else
        self.tabViewStyle(.automatic)
        #endif
    }
}
#endif
