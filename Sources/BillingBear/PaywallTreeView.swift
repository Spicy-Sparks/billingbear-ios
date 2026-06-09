#if canImport(SwiftUI)
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
import WebKit
#endif

// MARK: - PaywallTreeView — native SwiftUI renderer for the v2 free-form component tree
//
// Recursively renders a PaywallNode tree (the FROZEN v2 schema) entirely natively — no webview on
// the hot path — so the paywall paints in a frame from cache (the v2 speed win over Superwall's
// web-in-a-webview). Only the `custom` escape-hatch node pays the webview cost, and only where it is
// used. Stacks map to HStack/VStack/ZStack (+ ScrollView / paging TabView / marquee); elements map
// to native views; the PaywallStyle CSS subset maps to view modifiers. Variable interpolation,
// conditional visibility, entry animations, haptics and actions all flow natively.
//
// Reuses the v1 building blocks: Color(css:), RemoteImage, the gradient/video/lottie background
// views (PaywallGradientView / PaywallVideoView / PaywallLottieView) and PaywallTreeTransforms
// (the Swift port of the paywallTree.ts helpers).

// MARK: - Render context

/// Immutable per-render context threaded down the tree: the resolved theme, variables, the products
/// catalog, the user context (for visibleIf), the locale, and the action handler. Reference-typed so
/// the recursive views share one instance cheaply.
@available(iOS 15.0, macOS 12.0, *)
final class PaywallTreeContext: ObservableObject {
    let theme: PaywallTheme
    let variables: [String: String]?
    let products: [PaywallProduct]
    let userContext: PaywallUserContext?
    let isSubscribed: Bool?
    let locale: String?
    /// The single source of truth for the currently-selected product (owned by PaywallTreeView).
    /// Selector / product-card nodes read this to drive their highlight, so a `selectProduct` action
    /// fired from ANY node (or a controlled host) reflects everywhere — mirroring the web renderer's
    /// shared selection state rather than per-selector local state.
    let selectedProductId: String?
    let onAction: (PaywallAction) -> Void

    init(
        theme: PaywallTheme,
        variables: [String: String]?,
        products: [PaywallProduct],
        userContext: PaywallUserContext?,
        isSubscribed: Bool?,
        locale: String?,
        selectedProductId: String?,
        onAction: @escaping (PaywallAction) -> Void
    ) {
        self.theme = theme
        self.variables = variables
        self.products = products
        self.userContext = userContext
        self.isSubscribed = isSubscribed
        self.locale = locale
        self.selectedProductId = selectedProductId
        self.onAction = onAction
    }

    /// The currently-selected product object (for `{{product.*}}` on bare CTAs etc.).
    var selectedProduct: PaywallProduct? {
        products.first { $0.identifier == selectedProductId }
    }

    var textColor: Color { Color.css(theme.textColor, fallback: .white) }
    var primary: Color { Color.css(theme.primaryColor, fallback: .accentColor) }
    var cardBg: Color { Color.css(theme.cardBackground, fallback: Color(white: 0.09)) }

    /// Build the `{{product.*}}` interpolation dict for one product (live price filled by the host
    /// via the `price`/`label`/etc. — we expose the known fields the catalog carries).
    func productDict(_ p: PaywallProduct?) -> [String: String] {
        guard let p else { return [:] }
        var d: [String: String] = ["identifier": p.identifier, "id": p.identifier, "label": p.label]
        if let s = p.sublabel { d["sublabel"] = s }
        if let b = p.badge { d["badge"] = b }
        if let t = p.trialDays { d["trialDays"] = String(t) }
        // Live store price (host-filled) carried on the product → {{product.price}} resolves.
        if let pr = p.price { d["price"] = pr }
        return d
    }

    /// Interpolate a string with the v2 namespacing (var./product./theme.).
    func interpolate(_ s: String, selectedProduct: PaywallProduct?) -> String {
        PaywallTreeTransforms.interpolate(
            s,
            variables: variables,
            product: productDict(selectedProduct),
            theme: theme
        )
    }
}

// MARK: - PaywallTreeView (the public-ish entry the renderer composes)

/// Renders one PaywallTree. Owns the selected-product + current-page state and the multi-page pager;
/// delegates each node to `PaywallNodeView`. Actions bubble up through `onAction`.
@available(iOS 15.0, macOS 12.0, *)
struct PaywallTreeView: View {
    let tree: PaywallTree
    let variables: [String: String]?
    let locale: String?
    let userContext: PaywallUserContext?
    let isSubscribed: Bool?
    /// Fired for purchase/restore/dismiss/url/event after the tree resolves selection + page nav
    /// internally (those it handles itself).
    let onAction: (PaywallAction, _ selectedProduct: PaywallProduct?) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedProductId: String?
    @State private var currentPage: Int = 0

    var body: some View {
        // Apply translation (locale) up front, then resolve dark theme.
        let translated = PaywallTreeTransforms.applyTranslation(tree, locale: locale ?? Locale.current.identifier)
        let pages = translated.pages ?? []
        let isMultiPage = pages.count > 1

        Group {
            if isMultiPage {
                multiPage(translated, pages: pages)
            } else {
                singlePage(translated.root, theme: resolvedTheme(base: translated.theme, override: nil), tree: translated)
            }
        }
        .onAppear { armSelection(translated) }
    }

    // MARK: Theme resolution (dark + page override)

    private func resolvedTheme(base: PaywallTheme, override: PaywallThemeOverride?) -> PaywallTheme {
        var theme = base
        if let override { theme = theme.merging(override) }
        if colorScheme == .dark, let dark = tree.darkTheme {
            theme = theme.merging(dark)
        }
        return theme
    }

    // MARK: Single page

    private func singlePage(_ root: PaywallNode, theme: PaywallTheme, tree: PaywallTree) -> some View {
        let ctx = makeContext(theme: theme, tree: tree)
        let fixedNodes = Self.collectFixed(root)
        return ZStack {
            Color.css(theme.background, fallback: .black).ignoresSafeArea()
            // Root-level theme background (gradient/video/lottie) when the root opts in.
            if root.style?.useThemeBackground == true {
                paywallBackground(theme, solid: Color.css(theme.background, fallback: .black))
            }
            PaywallNodeView(node: root, isRoot: true)
                .environmentObject(ctx)
                // `position: fixed` nodes (e.g. a global close button) anchor to the paywall viewport,
                // above all scrolling content — not to whatever scroll/hero container they're nested in.
                .overlay(OutOfFlowLayer(children: fixedNodes, boundProduct: nil).environmentObject(ctx))
        }
    }

    /// All `position: fixed` descendants, gathered for the root viewport overlay.
    static func collectFixed(_ node: PaywallNode) -> [PaywallNode] {
        var out: [PaywallNode] = []
        if node.style?.isFixed == true { out.append(node) }
        for child in node.children { out.append(contentsOf: collectFixed(child)) }
        return out
    }

    // MARK: Multi-page pager

    @ViewBuilder
    private func multiPage(_ tree: PaywallTree, pages: [PaywallPageNode]) -> some View {
        let idx = min(currentPage, pages.count - 1)
        let page = pages[idx]
        let theme = resolvedTheme(base: tree.theme, override: page.themeOverride)
        ZStack(alignment: .bottom) {
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, pg in
                    let pageTheme = resolvedTheme(base: tree.theme, override: pg.themeOverride)
                    singlePage(pg.root, theme: pageTheme, tree: tree)
                        .tag(i)
                }
            }
            .tabViewStyle(pageTabViewStyle())
            // Page-indicator dots.
            HStack(spacing: 6) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Capsule()
                        .fill(i == idx ? Color.css(theme.primaryColor, fallback: .accentColor)
                                       : Color.css(theme.textColor, fallback: .white).opacity(0.3))
                        .frame(width: i == idx ? 18 : 6, height: 6)
                }
            }
            .padding(.bottom, 18)
        }
    }

    private func pageTabViewStyle() -> some TabViewStyle {
        #if os(iOS)
        return PageTabViewStyle(indexDisplayMode: .never)
        #else
        return DefaultTabViewStyle()
        #endif
    }

    // MARK: Context + actions

    private func makeContext(theme: PaywallTheme, tree: PaywallTree) -> PaywallTreeContext {
        PaywallTreeContext(
            theme: theme,
            variables: tree.variables.map { merge($0, variables) } ?? variables,
            products: tree.products,
            userContext: userContext,
            isSubscribed: isSubscribed,
            locale: locale,
            selectedProductId: selectedProductId,
            onAction: { action in handle(action, tree: tree) }
        )
    }

    /// Tree-defined variables are the base; caller-supplied variables win on key collisions (the
    /// host can override a default for A/B or live values).
    private func merge(_ base: [String: String], _ override: [String: String]?) -> [String: String] {
        guard let override else { return base }
        return base.merging(override) { _, new in new }
    }

    private var selectedProduct: PaywallProduct? {
        tree.products.first { $0.identifier == selectedProductId }
    }

    /// Resolve nav + selection internally; bubble the rest (purchase/restore/dismiss/url/event) up.
    private func handle(_ action: PaywallAction, tree: PaywallTree) {
        switch action {
        case .selectProduct(let pid):
            selectedProductId = pid
        case .nextPage:
            let count = (tree.pages?.count ?? 1)
            withAnimation { currentPage = min(currentPage + 1, count - 1) }
        case .prevPage:
            withAnimation { currentPage = max(currentPage - 1, 0) }
        case .goToPage(let pageId):
            if let i = tree.pages?.firstIndex(where: { $0.id == pageId }) {
                withAnimation { currentPage = i }
            }
        case .purchase(let pid):
            // Resolve the product: explicit id on the action, else the current selection.
            let product = pid.flatMap { id in tree.products.first { $0.identifier == id } } ?? selectedProduct
            onAction(.purchase(productId: product?.identifier), product)
        default:
            onAction(action, selectedProduct)
        }
    }

    // MARK: Initial selection

    private func armSelection(_ tree: PaywallTree) {
        guard selectedProductId == nil else { return }
        selectedProductId = Self.firstDefaultProductId(tree)
            ?? tree.products.first(where: { $0.highlight == true })?.identifier
            ?? tree.products.first?.identifier
    }

    /// The first productSelector's resolved default product id (selection seed), falling through to
    /// the first bare `product` node, walking the root then every page. Mirrors the web renderer's
    /// `firstDefaultProductId` so the initial highlight matches byte-for-byte.
    static func firstDefaultProductId(_ tree: PaywallTree) -> String? {
        func visit(_ node: PaywallNode) -> String? {
            if node.kind == .productSelector {
                let ids = (node.productIds?.isEmpty == false)
                    ? node.productIds!
                    : tree.products.map { $0.identifier }
                let highlighted = tree.products.first { $0.highlight == true && ids.contains($0.identifier) }
                return node.defaultProductId ?? highlighted?.identifier ?? ids.first
            }
            if node.kind == .product { return node.productId }
            for c in node.children {
                if let f = visit(c) { return f }
            }
            return nil
        }
        if let f = visit(tree.root) { return f }
        for p in tree.pages ?? [] {
            if let f = visit(p.root) { return f }
        }
        return nil
    }
}

// MARK: - PaywallNodeView (recursive)

/// Renders a single node: dispatches on `kind`, applies visibleIf gating, the PaywallStyle modifier
/// chain, the entry animation, and the tap action (+ haptic). Recurses into stack children.
@available(iOS 15.0, macOS 12.0, *)
struct PaywallNodeView: View {
    let node: PaywallNode
    var isRoot: Bool = false
    /// The product this subtree is bound to (set when rendering a productSelector item template /
    /// a product card). Drives `{{product.*}}` interpolation for descendants.
    var boundProduct: PaywallProduct? = nil

    @EnvironmentObject private var ctx: PaywallTreeContext
    @State private var appeared = false

    /// A text node whose interpolated text resolves to empty (e.g. an unfilled {{product.badge}})
    /// must render NOTHING — including its styled box — or a colored-but-empty pill shows as a stray
    /// blob. Mirrors the web renderer collapsing empty text nodes.
    private var isEmptyResolvedText: Bool {
        guard node.kind == .text else { return false }
        let s = ctx.interpolate(node.text ?? "", selectedProduct: boundProduct)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if PaywallTreeTransforms.isNodeVisible(node, context: ctx.userContext, isSubscribed: ctx.isSubscribed, locale: ctx.locale ?? Locale.current.identifier) && !isEmptyResolvedText {
            content
                .paywallStyle(node.style, ctx: ctx, isRoot: isRoot)
                // Out-of-flow (absolute/fixed) children anchor to this node's BORDER box — applied
                // AFTER paywallStyle so insets are measured outside the node's padding (CSS parity).
                .modifier(OutOfFlowOverlayModifier(node: node, boundProduct: boundProduct))
                // Clip a layered stack to its own bounds AFTER sizing, so an absolute child (a
                // full-bleed image / gradient scrim) can't bleed past a fixed-height band (e.g. a
                // 300pt photo header) and darken the content below it. CSS clips a positioned box's
                // absolute fill to the box; SwiftUI ZStack/overlay does not, hence this.
                .modifier(LayeredClipModifier(active: node.kind == .stack && node.direction == .layered))
                .modifier(PaywallEntryAnimation(animation: node.animation, appeared: appeared))
                .modifier(PaywallTapModifier(action: node.onTap, haptic: node.haptic, ctx: ctx))
                .onAppear {
                    if let anim = node.animation {
                        // duration/delay are MILLISECONDS in the schema (matches the web renderer's
                        // 400 ms default). The web easing is cubic-bezier(0.16, 1, 0.3, 1) — a soft
                        // spring-like ease-out; `.easeOut` is the closest built-in approximation.
                        withAnimation(.easeOut(duration: anim.durationSeconds).delay(anim.delaySeconds)) {
                            appeared = true
                        }
                    } else {
                        appeared = true
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .stack:
            PaywallStackView(node: node, boundProduct: boundProduct)
        case .text:
            PaywallTextView(node: node, boundProduct: boundProduct)
        case .image:
            PaywallImageView(node: node)
        case .video:
            PaywallVideoElement(node: node)
        case .lottie:
            PaywallLottieElement(node: node)
        case .button:
            PaywallButtonView(node: node, boundProduct: boundProduct)
        case .productSelector:
            PaywallProductSelectorView(node: node)
        case .product:
            PaywallProductCardView(node: node)
        case .timer:
            PaywallTimerView(node: node)
        case .spacer:
            PaywallSpacerElement(node: node)
        case .divider:
            PaywallDividerElement(node: node)
        case .icon:
            PaywallIconElement(node: node)
        case .rating:
            PaywallRatingView(node: node)
        case .testimonial:
            PaywallTestimonialView(node: node)
        case .custom:
            PaywallCustomView(node: node)
        case .unknown:
            EmptyView()
        }
    }
}

/// Clips a layered stack to its laid-out bounds (applied after the style frame) so an absolute
/// full-bleed child can't spill past a fixed-size band. A no-op for every other node.
@available(iOS 15.0, macOS 12.0, *)
private struct LayeredClipModifier: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.clipped() } else { content }
    }
}

// MARK: - Stack

@available(iOS 15.0, macOS 12.0, *)
struct PaywallStackView: View {
    let node: PaywallNode
    var boundProduct: PaywallProduct?
    @EnvironmentObject private var ctx: PaywallTreeContext

    private var spacing: CGFloat { CGFloat(node.spacing ?? 0) }
    private var direction: PaywallStackDirection { node.direction ?? .vertical }

    // Out-of-flow (position: absolute/fixed/sticky) children are pulled OUT of EVERY stack — not just
    // layered ones — so an absolute node (e.g. a close "✕" inside a vertical header) anchors to its
    // inset edge in an overlay instead of taking an in-flow slot (which rendered it centered).
    private var inFlowKids: [PaywallNode] {
        direction == .layered ? node.children : node.children.filter { !($0.style?.isOutOfFlow ?? false) }
    }
    private var outOfFlowKids: [PaywallNode] {
        direction == .layered ? [] : node.children.filter { $0.style?.isOutOfFlow ?? false }
    }

    // NOTE: out-of-flow children are overlaid by PaywallNodeView AFTER this stack's padding is
    // applied — CSS anchors an absolute child to the positioned ancestor's BORDER box (outside its
    // padding). Overlaying here (inside padding) put a top-right close button at content-top + inset,
    // colliding with the first in-flow child (e.g. a tall title). Layered stacks still anchor their
    // own out-of-flow inside `layeredContent` (they are typically padding-less full-bleed boxes).
    var body: some View {
        coreContent
    }

    @ViewBuilder
    private var coreContent: some View {
        let inner = stackContent
        switch node.scroll?.mode ?? .none {
        case .none:
            inner
        case .normal:
            ScrollView(direction == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
                // Pin the content to the scroll viewport's cross-axis size so it has a definite width
                // (vertical scroll) / height (horizontal scroll). Without this the content hugs to its
                // intrinsic size, and a wrapping `grow` text with no width-establishing sibling
                // collapses to a single line — the whole scroll content then measures ~0 and clips.
                inner.frame(
                    maxWidth: direction == .horizontal ? nil : .infinity,
                    maxHeight: direction == .horizontal ? .infinity : nil,
                    alignment: .topLeading
                )
            }
        case .paging:
            PaywallPagingStack(node: node, boundProduct: boundProduct)
        case .infinite:
            PaywallMarqueeStack(node: node, boundProduct: boundProduct)
        }
    }

    @ViewBuilder
    private var stackContent: some View {
        switch direction {
        case .horizontal:
            if node.wrap == true {
                PaywallFlowLayout(spacing: spacing) { flowChildViews }
            } else {
                HStack(alignment: crossAlignVertical, spacing: spacing) { mainAxisChildren }
            }
        case .vertical:
            if node.wrap == true {
                // Wrapping vertical stack: flow children (column-wrap on the web reflows into rows).
                PaywallFlowLayout(spacing: spacing) { flowChildViews }
            } else {
                VStack(alignment: crossAlignHorizontal, spacing: spacing) { mainAxisChildrenVertical }
            }
        case .layered:
            layeredContent
        }
    }

    // MARK: Layered (ZStack with web LayeredChild semantics)

    /// Mirrors the web `LayeredChild`: the FIRST in-flow child establishes the box size (laid out
    /// normally); every later in-flow child fills that box on top, z-ordered by node order. Children
    /// with their own `position: absolute/fixed/sticky` leave the flow and anchor to the edge their
    /// insets imply (top/right/bottom/left), exactly like CSS inside a positioned ancestor.
    @ViewBuilder
    private var layeredContent: some View {
        // `fixed` children are hoisted to the root viewport overlay, so drop them here.
        let kids = Array(node.children.enumerated()).filter { !($0.element.style?.isFixed ?? false) }
        let inFlow = kids.filter { !($0.element.style?.isOutOfFlow ?? false) }
        let outOfFlow = kids.filter { $0.element.style?.isOutOfFlow ?? false }

        ZStack(alignment: layeredAlignment) {
            // When EVERY child is out-of-flow (the full-bleed pattern: absolute bg image + scrim +
            // bottom-pinned content), there is no in-flow child to establish the box size, so the
            // ZStack — and its out-of-flow overlay — would collapse to zero (bg image renders tiny,
            // content vanishes). A full-size clear layer makes the stack fill its container, exactly
            // like the web renderer promoting a fill-height root to a definite height.
            if inFlow.isEmpty {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // In-flow layers: first establishes size, rest fill it, z-ordered by declared order
            // (or explicit zIndex when the author sets one).
            ForEach(inFlow, id: \.offset) { i, child in
                if i == inFlow.first?.offset {
                    PaywallNodeView(node: child, boundProduct: boundProduct)
                        .zIndex(child.style?.zIndex ?? Double(i))
                } else {
                    PaywallNodeView(node: child, boundProduct: boundProduct)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .zIndex(child.style?.zIndex ?? Double(i))
                }
            }
        }
        // Out-of-flow layers: anchored to their inset-implied edges over the whole stack.
        .overlay(OutOfFlowLayer(children: outOfFlow.map { $0.element }, boundProduct: boundProduct))
    }

    /// Children with main-axis distribution spacers inserted for space-between/around/evenly (HStack).
    @ViewBuilder
    private var mainAxisChildren: some View {
        let kids = inFlowKids
        switch node.mainAlign ?? .start {
        case .start:
            childViews
            if needsTrailingFill { Spacer(minLength: 0) }
        case .end:
            Spacer(minLength: 0)
            childViews
        case .center:
            Spacer(minLength: 0)
            childViews
            Spacer(minLength: 0)
        case .spaceBetween, .spaceAround, .spaceEvenly:
            distributedChildren(kids, mode: node.mainAlign ?? .start)
        }
    }

    @ViewBuilder
    private var mainAxisChildrenVertical: some View {
        let kids = inFlowKids
        switch node.mainAlign ?? .start {
        case .start:
            childViews
        case .end:
            Spacer(minLength: 0)
            childViews
        case .center:
            Spacer(minLength: 0)
            childViews
            Spacer(minLength: 0)
        case .spaceBetween, .spaceAround, .spaceEvenly:
            distributedChildren(kids, mode: node.mainAlign ?? .start)
        }
    }

    /// Whether a trailing Spacer is needed for `start` alignment (only when no child grows).
    private var needsTrailingFill: Bool {
        false  // `start` packs children at the leading edge; let the parent frame govern width.
    }

    @ViewBuilder
    private func distributedChildren(_ kids: [PaywallNode], mode: PaywallMainAlign) -> some View {
        // space-between: spacers only between; space-around: half-spacers at the ends; space-evenly:
        // equal spacers everywhere. Modeled with Spacers (equal weight) — SwiftUI distributes them.
        if mode == .spaceAround || mode == .spaceEvenly { Spacer(minLength: 0) }
        ForEach(Array(kids.enumerated()), id: \.offset) { i, child in
            PaywallNodeView(node: child, boundProduct: boundProduct)
            if i < kids.count - 1 { Spacer(minLength: 0) }
        }
        if mode == .spaceAround || mode == .spaceEvenly { Spacer(minLength: 0) }
    }

    @ViewBuilder
    private var childViews: some View {
        ForEach(Array(inFlowKids.enumerated()), id: \.offset) { _, child in
            PaywallNodeView(node: child, boundProduct: boundProduct)
        }
    }

    /// Flow (wrap) children: each carries its percent-width fraction as a layout value and is flagged
    /// `paywallInFlow` so a percent-width card defers its sizing to `PaywallFlowLayoutNative` (which
    /// proposes the resolved width) instead of self-resolving via a height-collapsing GeometryReader.
    @ViewBuilder
    private var flowChildViews: some View {
        ForEach(Array(inFlowKids.enumerated()), id: \.offset) { _, child in
            PaywallNodeView(node: child, boundProduct: boundProduct)
                .environment(\.paywallInFlow, true)
                .modifier(PercentWidthLayoutValue(fraction: percentFraction(child)))
        }
    }

    private func percentFraction(_ node: PaywallNode) -> CGFloat? {
        if case .percent(let p)? = node.style?.width { return CGFloat(p) / 100 }
        return nil
    }

    // MARK: Alignment mapping

    private var crossAlignVertical: VerticalAlignment {
        switch node.crossAlign ?? .center {
        case .start: return .top
        case .center: return .center
        case .end: return .bottom
        case .stretch: return .center
        }
    }

    private var crossAlignHorizontal: HorizontalAlignment {
        switch node.crossAlign ?? .center {
        case .start: return .leading
        case .center: return .center
        case .end: return .trailing
        case .stretch: return .center
        }
    }

    private var layeredAlignment: Alignment {
        switch node.crossAlign ?? .center {
        case .start: return .topLeading
        case .center: return .center
        case .end: return .bottomTrailing
        case .stretch: return .center
        }
    }
}

/// Renders a stack's out-of-flow (CSS absolute/fixed/sticky) children anchored over the whole stack.
/// A GeometryReader gives a DEFINITE container size so a child stretched on an axis (both insets set)
/// gets a concrete width/height; otherwise it anchors to its inset-implied edge at its natural size.
/// Shared by layered AND ordinary (vertical/horizontal) stacks so an absolute close "✕" anchors
/// top-right instead of taking a centered in-flow slot.
@available(iOS 15.0, macOS 12.0, *)
struct OutOfFlowLayer: View {
    let children: [PaywallNode]
    var boundProduct: PaywallProduct?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(children.enumerated()), id: \.offset) { i, child in
                    let s = child.style
                    let stretchW = s?.left != nil && s?.right != nil
                    let stretchH = s?.top != nil && s?.bottom != nil
                    // The child's own PaywallPositionModifier applies its inset offset (top/right/
                    // bottom/left), so alignment alone anchors it to the right edge here.
                    PaywallNodeView(node: child, boundProduct: boundProduct)
                        .frame(width: stretchW ? geo.size.width : nil, height: stretchH ? geo.size.height : nil)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: s?.outOfFlowAlignment ?? .topLeading)
                        .zIndex(s?.zIndex ?? Double(100 + i))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Overlays a stack's out-of-flow (absolute/fixed) children AFTER the stack's padding, so they anchor
/// to its border box (CSS parity). Layered stacks anchor their own out-of-flow inside `layeredContent`.
struct OutOfFlowOverlayModifier: ViewModifier {
    let node: PaywallNode
    var boundProduct: PaywallProduct?
    func body(content: Content) -> some View {
        let kids = outOfFlowKids
        if kids.isEmpty {
            content
        } else {
            content.overlay(OutOfFlowLayer(children: kids, boundProduct: boundProduct))
        }
    }
    private var outOfFlowKids: [PaywallNode] {
        guard node.kind == .stack, (node.direction ?? .vertical) != .layered else { return [] }
        // `fixed` children are hoisted to the root viewport overlay, not anchored to this stack.
        return node.children.filter { ($0.style?.isOutOfFlow ?? false) && !($0.style?.isFixed ?? false) }
    }
}

// MARK: - Paging stack (scroll.mode = paging)

@available(iOS 15.0, macOS 12.0, *)
struct PaywallPagingStack: View {
    let node: PaywallNode
    var boundProduct: PaywallProduct?
    @EnvironmentObject private var ctx: PaywallTreeContext
    @State private var page = 0
    @State private var autoTick = false

    private var autoMs: Double? {
        if let ms = node.scroll?.autoPageMs, ms > 0 { return ms }
        return nil
    }

    var body: some View {
        let kids = node.children
        let style: any TabViewStyle = {
            #if os(iOS)
            return (node.scroll?.indicator ?? false)
                ? PageTabViewStyle(indexDisplayMode: .automatic)
                : PageTabViewStyle(indexDisplayMode: .never)
            #else
            return DefaultTabViewStyle()
            #endif
        }()

        TabView(selection: $page) {
            ForEach(Array(kids.enumerated()), id: \.offset) { i, child in
                PaywallNodeView(node: child, boundProduct: boundProduct).tag(i)
            }
        }
        .applyTabStyle(style)
        .onReceive(timer) { _ in
            guard let _ = autoMs, !kids.isEmpty else { return }
            withAnimation { page = (page + 1) % kids.count }
        }
    }

    private var timer: AnyPublisher<Date, Never> {
        if let ms = autoMs {
            return Timer.publish(every: ms / 1000.0, on: .main, in: .common).autoconnect().eraseToAnyPublisher()
        }
        // A never-firing publisher when there's no auto-advance.
        return Empty<Date, Never>(completeImmediately: false).eraseToAnyPublisher()
    }
}

// MARK: - Marquee stack (scroll.mode = infinite)

/// A looping reel (testimonials / logos). Renders the children twice end-to-end and animates a
/// continuous offset, wrapping seamlessly. Honours the stack direction (horizontal row vs vertical
/// column), matching the web marquee's per-axis support. Speed is px/s from the schema (web default 60).
@available(iOS 15.0, macOS 12.0, *)
struct PaywallMarqueeStack: View {
    let node: PaywallNode
    var boundProduct: PaywallProduct?
    @EnvironmentObject private var ctx: PaywallTreeContext
    @State private var offset: CGFloat = 0
    @State private var contentExtent: CGFloat = 0

    private var speed: CGFloat { CGFloat(node.scroll?.speed ?? 60) }
    private var spacing: CGFloat { CGFloat(node.spacing ?? 0) }
    private var isHorizontal: Bool { (node.direction ?? .vertical) != .vertical }

    @ViewBuilder private var row: some View {
        if isHorizontal {
            HStack(spacing: spacing) { reelChildren }
        } else {
            VStack(spacing: spacing) { reelChildren }
        }
    }

    @ViewBuilder private var reelChildren: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            PaywallNodeView(node: child, boundProduct: boundProduct)
        }
    }

    var body: some View {
        GeometryReader { _ in
            track
                .background(
                    GeometryReader { g in
                        Color.clear.onAppear {
                            let total = isHorizontal ? g.size.width : g.size.height
                            contentExtent = (total - spacing) / 2
                            startAnimation()
                        }
                    }
                )
                .offset(x: isHorizontal ? offset : 0, y: isHorizontal ? 0 : offset)
        }
        .clipped()
    }

    @ViewBuilder private var track: some View {
        if isHorizontal {
            HStack(spacing: spacing) { row; row }   // duplicate for seamless wrap
        } else {
            VStack(spacing: spacing) { row; row }
        }
    }

    private func startAnimation() {
        guard contentExtent > 0, speed > 0 else { return }
        let duration = Double(contentExtent / speed)
        offset = 0
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -contentExtent
        }
    }
}

// MARK: - Text

@available(iOS 15.0, macOS 12.0, *)
struct PaywallTextView: View {
    let node: PaywallNode
    var boundProduct: PaywallProduct?
    @EnvironmentObject private var ctx: PaywallTreeContext

    var body: some View {
        let raw = node.text ?? ""
        let interpolated = ctx.interpolate(raw, selectedProduct: boundProduct)
        let transformed = (node.style?.textTransform ?? .none).apply(interpolated)
        Text(transformed)
            .modifier(PaywallTypography(style: node.style, ctx: ctx))
            .lineLimit(node.maxLines)
            // Take the full height the text needs (up to maxLines when set) so multi-line / "\n"
            // copy WRAPS instead of being truncated to one line ("Unlock the…") when a flex parent
            // proposes a tight height. With lineLimit set this caps at N lines; without it, full text.
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Image

@available(iOS 15.0, macOS 12.0, *)
struct PaywallImageView: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext

    var body: some View {
        let url = ctx.interpolate(node.url ?? "", selectedProduct: nil)
        // Web objectFit: contain→.fit, cover→.fill (aspect-fill), fill→stretch (no aspect lock).
        let stretch = node.contentMode == .fill
        let mode: ContentMode = (node.contentMode == .contain) ? .fit : .fill
        ZStack {
            if let poster = node.posterUrl, !poster.isEmpty {
                RemoteImage(url: poster, contentMode: mode, stretch: stretch)
            }
            RemoteImage(url: url, contentMode: mode, stretch: stretch)
        }
        // Web defaults a dimensionless image to fill its parent width; honour that when the author
        // set neither width nor height (the style chain overrides when they did).
        .modifier(PaywallImageDefaultSize(hasWidth: node.style?.width != nil, hasHeight: node.style?.height != nil))
        .accessibilityLabel(node.alt ?? "")
    }
}

/// When an image node carries no explicit width/height, default it to fill the available width
/// (matching the web renderer's `style.width = '100%'` fallback) so it doesn't collapse to intrinsic.
@available(iOS 15.0, macOS 12.0, *)
struct PaywallImageDefaultSize: ViewModifier {
    let hasWidth: Bool
    let hasHeight: Bool
    func body(content: Content) -> some View {
        if !hasWidth && !hasHeight {
            content.frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

// MARK: - Video / Lottie elements (reuse the v1 background views)

@available(iOS 15.0, macOS 12.0, *)
struct PaywallVideoElement: View {
    let node: PaywallNode
    var body: some View {
        ZStack {
            if let poster = node.posterUrl, !poster.isEmpty {
                RemoteImage(url: poster, contentMode: node.contentMode == .contain ? .fit : .fill)
            }
            #if canImport(UIKit)
            if let u = URL(string: node.url ?? "") {
                PaywallVideoView(url: u, loop: node.loop ?? true, muted: node.muted ?? true)
            }
            #endif
        }
    }
}

@available(iOS 15.0, macOS 12.0, *)
struct PaywallLottieElement: View {
    let node: PaywallNode
    var body: some View {
        ZStack {
            if let poster = node.posterUrl, !poster.isEmpty {
                RemoteImage(url: poster, contentMode: .fit)
            }
            #if canImport(UIKit)
            if let u = URL(string: node.url ?? "") {
                PaywallLottieView(
                    url: u,
                    loop: node.loop ?? true,
                    autoplay: node.autoplay ?? true,
                    speed: node.speed ?? 1
                )
            }
            #endif
        }
    }
}

// MARK: - Button

@available(iOS 15.0, macOS 12.0, *)
struct PaywallButtonView: View {
    let node: PaywallNode
    var boundProduct: PaywallProduct?
    @EnvironmentObject private var ctx: PaywallTreeContext

    var body: some View {
        // A CTA interpolates `{{product.*}}` against the bound product (inside a template) else the
        // tree's currently-selected product — so "Start {{product.label}}" tracks the live selection.
        let label = ctx.interpolate(node.text ?? "", selectedProduct: boundProduct ?? ctx.selectedProduct)
        let transformed = (node.style?.textTransform ?? .none).apply(label)
        VStack(spacing: 6) {
            Button(action: { fire() }) {
                Text(transformed)
                    .modifier(PaywallTypography(style: node.style, ctx: ctx, defaultWeight: .bold, defaultColor: ctx.textColor))
                    // CTA labels are centered (the web renderer hard-centers them); without this a
                    // wrapped or non-center-styled label renders leading-aligned inside the button.
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            if let micro = node.microtext, !micro.isEmpty {
                // The microtext sits ON the button surface (the whole VStack gets the button's
                // background), so it must use the button's OWN foreground color — not the theme text
                // color, which is light-on-light (illegible) on a filled accent button.
                Text(ctx.interpolate(micro, selectedProduct: boundProduct ?? ctx.selectedProduct))
                    .font(.system(size: 11))
                    .foregroundColor(buttonForeground.opacity(0.78))
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// The button's resolved foreground color (same as the label), so the microtext stays legible on
    /// the filled button surface. Falls back to the theme text color when the button sets no color.
    private var buttonForeground: Color {
        node.style?.color.flatMap { Color(css: ctx.interpolate($0, selectedProduct: nil)) } ?? ctx.textColor
    }

    private func fire() {
        PaywallHapticEngine.fire(node.haptic ?? .medium)
        // A button's onTap defaults to a purchase action when none is set (the canonical CTA).
        ctx.onAction(node.onTap ?? .purchase(productId: nil))
    }
}

// MARK: - Product selector

@available(iOS 15.0, macOS 12.0, *)
struct PaywallProductSelectorView: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext

    private var products: [PaywallProduct] {
        let all = ctx.products.filter { PaywallTransforms.isProductVisible($0, ctx.userContext) }
        guard let ids = node.productIds, !ids.isEmpty else { return all }
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return all.filter { order[$0.identifier] != nil }
                  .sorted { (order[$0.identifier] ?? 0) < (order[$1.identifier] ?? 0) }
    }

    private var initialSelection: String? {
        node.defaultProductId
            ?? products.first(where: { $0.highlight == true })?.identifier
            ?? products.first?.identifier
    }

    var body: some View {
        let layout = node.layout ?? .list
        Group {
            switch layout {
            case .list:
                VStack(spacing: 10) { cards }
            case .horizontal:
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) { cards }
                }
            case .grid:
                let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) { cards }
            }
        }
        .onAppear {
            // Seed selection through the tree-owned state when nothing is selected yet. The tree
            // already arms an initial selection on appear; this guards a selector whose default
            // differs from the tree-wide default (defaultProductId on this node).
            if ctx.selectedProductId == nil, let s = node.defaultProductId ?? initialSelection {
                ctx.onAction(.selectProduct(productId: s))
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        ForEach(products, id: \.identifier) { product in
            card(for: product)
        }
    }

    @ViewBuilder
    private func card(for product: PaywallProduct) -> some View {
        let isSelected = ctx.selectedProductId == product.identifier
        Button {
            PaywallHapticEngine.fire(.selection)
            ctx.onAction(.selectProduct(productId: product.identifier))
        } label: {
            if let tpl = node.itemTemplate?.node {
                // Custom template: render the subtree bound to this product, highlighted on select.
                PaywallNodeView(node: tpl, boundProduct: product)
                    .overlay(selectionBorder(isSelected))
            } else {
                defaultCard(product, isSelected: isSelected)
            }
        }
        .buttonStyle(.plain)
    }

    private func selectionBorder(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(selected ? ctx.primary : Color.clear, lineWidth: 2)
    }

    @ViewBuilder
    private func defaultCard(_ product: PaywallProduct, isSelected: Bool) -> some View {
        let bg = isSelected ? ctx.primary.opacity(0.12) : ctx.cardBg
        VStack(alignment: .leading, spacing: 3) {
            if let badge = product.badge.map({ ctx.interpolate($0, selectedProduct: product) }) {
                Text(badge.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(Color.css(ctx.theme.ctaTextColor, fallback: .white))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(ctx.primary)
                    .clipShape(Capsule())
                    .padding(.bottom, 2)
            }
            Text(ctx.interpolate(product.label, selectedProduct: product))
                .font(PaywallFontResolver.font(family: ctx.theme.fontFamily, size: 16, weight: .bold))
                .foregroundColor(ctx.textColor)
            if let sub = product.sublabel {
                Text(ctx.interpolate(sub, selectedProduct: product))
                    .font(PaywallFontResolver.font(family: ctx.theme.fontFamily, size: 13, weight: .regular))
                    .foregroundColor(ctx.textColor.opacity(0.6))
            }
            if let trial = product.trialDays, trial > 0 {
                Text("\(trial)-day free trial")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(ctx.primary)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(bg)
        .overlay(
            // Selected → accent border; unselected → a faint hairline so the card stays defined on
            // any background (a borderless card vanishes on a dark photo).
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? ctx.primary : ctx.textColor.opacity(0.15), lineWidth: isSelected ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Single product card

@available(iOS 15.0, macOS 12.0, *)
struct PaywallProductCardView: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext

    private var product: PaywallProduct? {
        ctx.products.first { $0.identifier == node.productId }
    }

    var body: some View {
        Group {
            if let product {
                let isSelected = ctx.selectedProductId == product.identifier
                Button {
                    PaywallHapticEngine.fire(.selection)
                    ctx.onAction(.selectProduct(productId: product.identifier))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ctx.interpolate(product.label, selectedProduct: product))
                            .font(PaywallFontResolver.font(family: ctx.theme.fontFamily, size: 16, weight: .bold))
                            .foregroundColor(ctx.textColor)
                        if let sub = product.sublabel {
                            Text(ctx.interpolate(sub, selectedProduct: product))
                                .font(.system(size: 13))
                                .foregroundColor(ctx.textColor.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Web always renders DefaultProductCard for a product node and reflects selection
                    // via data-selected + a primary border. Mirror the built-in card chrome here.
                    .padding(16)
                    .background(isSelected ? ctx.primary.opacity(0.12) : ctx.cardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isSelected ? ctx.primary : Color.clear, lineWidth: 1.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                EmptyView()
            }
        }
    }
}

// MARK: - Timer

@available(iOS 15.0, macOS 12.0, *)
struct PaywallTimerView: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext
    @State private var now = Date()
    @State private var firstView = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Deadline: explicit endsAt, else firstView + durationSec (rolling per-view countdown).
    private var deadline: Date? {
        if let endsAt = node.endsAt, let d = PaywallTransforms.parseISODate(endsAt) { return d }
        if let dur = node.durationSec { return firstView.addingTimeInterval(dur) }
        return nil
    }

    var body: some View {
        let remaining = deadline.map { Int($0.timeIntervalSince(now).rounded(.down)) } ?? 0
        let expired = remaining <= 0
        let hide = node.hideOnExpiry ?? true
        Group {
            if !(expired && hide) {
                Text(PaywallTimerFormatter.format(remaining: max(0, remaining), pattern: node.format))
                    .modifier(PaywallTypography(style: node.style, ctx: ctx, defaultWeight: .bold, defaultColor: ctx.primary, monospacedDigits: true))
            }
        }
        .onReceive(tick) { now = $0 }
    }
}

// MARK: - Spacer / Divider

/// Flexible space. Web: `flex: grow ?? 1`. SwiftUI Spacer already grows along the parent's main axis;
/// an explicit fixed width/height (via style) is honoured by the surrounding style modifier.
@available(iOS 15.0, macOS 12.0, *)
struct PaywallSpacerElement: View {
    let node: PaywallNode
    var body: some View {
        // A grow > 0 (the default) lets the spacer expand. minLength 0 so it can fully collapse when
        // the parent has no slack, matching flexbox.
        Spacer(minLength: 0)
    }
}

/// Hairline rule. Web maps `style.background` to the line colour (default a translucent grey) and
/// spans the full width. Honours an explicit height from style (a thicker rule) via the style chain.
@available(iOS 15.0, macOS 12.0, *)
struct PaywallDividerElement: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext

    var body: some View {
        let color = node.style?.background
            .flatMap { Color(css: ctx.interpolate($0, selectedProduct: nil)) }
            ?? ctx.textColor.opacity(0.18)
        // A 1pt rule by default; the style chain's frame/height can thicken it. Rectangle (not
        // Divider) so the colour + full-width behaviour is deterministic across platforms.
        Rectangle()
            .fill(color)
            .frame(height: node.style?.height == nil ? 1 : nil)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Icon

@available(iOS 15.0, macOS 12.0, *)
struct PaywallIconElement: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext

    var body: some View {
        let name = node.name ?? ""
        let size = CGFloat(node.style?.fontSize ?? 18)
        let color = node.style?.color.flatMap { Color(css: $0) } ?? ctx.primary
        if PaywallIconClassifier.isEmoji(name) {
            Text(name).font(.system(size: size))
        } else {
            // SF Symbol name on iOS; if it isn't a valid symbol the glyph simply won't draw, so map
            // through the v1 alias table first (covers the builder's named icon set).
            Image(systemName: PaywallIconClassifier.symbolName(name))
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
        }
    }
}

// MARK: - Rating (stars)

@available(iOS 15.0, macOS 12.0, *)
struct PaywallRatingView: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext

    var body: some View {
        let value = node.value ?? 0
        let maxStars = Int(node.max ?? 5)
        let accent = node.style?.color.flatMap { Color(css: $0) } ?? Color(css: "#f59e0b") ?? .yellow
        HStack(spacing: 3) {
            ForEach(0..<maxStars, id: \.self) { i in
                Image(systemName: starSymbol(index: i, value: value))
                    .font(.system(size: CGFloat(node.style?.fontSize ?? 14)))
                    .foregroundColor(accent)
            }
            if let label = node.label, !label.isEmpty {
                Text(ctx.interpolate(label, selectedProduct: nil))
                    .font(.system(size: 12))
                    .foregroundColor(ctx.textColor.opacity(0.7))
                    .padding(.leading, 4)
            }
        }
    }

    private func starSymbol(index: Int, value: Double) -> String {
        PaywallStarRow.symbol(index: index, value: value)
    }
}

/// Shared star-symbol resolution for rating + testimonial rows (half-star aware). Mirrors the web
/// <Stars> component: a star at position `index` (0-based) is full when value ≥ index+1, half when
/// value ≥ index+0.5, else empty.
@available(iOS 15.0, macOS 12.0, *)
enum PaywallStarRow {
    static func symbol(index: Int, value: Double) -> String {
        let filled = Double(index) + 1
        if value >= filled { return "star.fill" }
        if value >= filled - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

// MARK: - Testimonial

@available(iOS 15.0, macOS 12.0, *)
struct PaywallTestimonialView: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rating = node.rating {
                // 5-star row with half-star support, matching the web <Stars value> component.
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { i in
                        Image(systemName: PaywallStarRow.symbol(index: i, value: rating))
                            .font(.system(size: 11))
                            .foregroundColor(Color(css: "#f59e0b") ?? .yellow)
                    }
                }
            }
            Text("“\(ctx.interpolate(node.quote ?? "", selectedProduct: nil))”")
                .font(PaywallFontResolver.font(family: ctx.theme.fontFamily, size: 15, weight: .medium))
                .foregroundColor(ctx.textColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let avatar = node.avatarUrl, !avatar.isEmpty {
                    RemoteImage(url: avatar, contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                }
                if let author = node.author {
                    Text(ctx.interpolate(author, selectedProduct: nil))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(ctx.textColor.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ctx.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Custom (escape hatch — webview)

@available(iOS 15.0, macOS 12.0, *)
struct PaywallCustomView: View {
    let node: PaywallNode
    @EnvironmentObject private var ctx: PaywallTreeContext

    var body: some View {
        #if canImport(UIKit)
        PaywallWebView(
            html: node.html.map { ctx.interpolate($0, selectedProduct: nil) },
            css: node.css,
            url: node.url
        )
        #else
        EmptyView()
        #endif
    }
}

#if canImport(UIKit)
/// The ONLY webview in the renderer (the v2 escape hatch). Renders inline html+css or a remote url.
@available(iOS 15.0, *)
struct PaywallWebView: UIViewRepresentable {
    let html: String?
    let css: String?
    let url: String?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if let urlString = url, !urlString.isEmpty, let u = URL(string: urlString) {
            webView.load(URLRequest(url: u))
        } else if let html {
            let style = css.map { "<style>\($0)</style>" } ?? ""
            let doc = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">\
            <style>html,body{margin:0;padding:0;background:transparent;}</style>\(style)</head>\
            <body>\(html)</body></html>
            """
            webView.loadHTMLString(doc, baseURL: nil)
        }
    }
}
#endif
#endif
