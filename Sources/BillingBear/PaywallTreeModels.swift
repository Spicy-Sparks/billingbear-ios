import Foundation

// MARK: - Paywall v2 — free-form component-tree model (Codable mirror)
//
// Swift mirror of the FROZEN TypeScript contract in:
//   • web/src/lib/paywallTree.ts   (canonical)
//   • sdk/web/src/paywallTree.ts   (identical SDK mirror)
//
// A paywall v2 document is a tree of nodes (Stack | Element). The dashboard authors this shape, the
// backend stores it as opaque jsonb, and three renderers parse this exact shape (web flexbox, iOS
// SwiftUI, Android Compose). This file is the iOS Codable half; PaywallTreeView.swift renders it.
//
// DECODING IS TOLERANT BY DESIGN — mirroring normalizePaywallTree(): a partially-authored or
// future-versioned document degrades to something renderable rather than throwing. An unknown node
// `type` decodes to a `.unknown` no-op node (rendered as EmptyView), an unknown direction falls back
// to vertical, sizes/edges/corners decode from number|string|object, and the top-level decode never
// crashes (the renderer wraps the raw decode and falls back to an empty tree on hard failure).
//
// The v2 tree reuses the v1 theme/background/animation/product/visibility types from
// PaywallModels.swift (PaywallTheme, PaywallGradient, PaywallBackground*, PaywallAnimation,
// PaywallProduct, PaywallProductVisibility, PaywallUserContext) so a v2 paywall can mix the rich
// primitives the SDK already ships. JSON keys are camelCase (the wire format) — no key strategy set.

// MARK: - Top level

public struct PaywallTree: Codable, Equatable, Sendable {
    /// Always 2 for v2. Decodes tolerantly (defaults to 2 when missing/garbage).
    public var version: Int
    /// Palette + typography + (light) background. Reused 1:1 from v1.
    public var theme: PaywallTheme
    /// Overrides merged over `theme` when the host is in dark mode.
    public var darkTheme: PaywallThemeOverride?
    /// Named variables referenced anywhere as `{{var.NAME}}`.
    public var variables: [String: String]?
    /// The component tree. Conventionally a vertical scroll stack.
    public var root: PaywallNode
    /// Products available to product / productSelector nodes + purchase actions.
    public var products: [PaywallProduct]
    /// Multi-page (onboarding) flow. When present + length > 1 the tree renders as a horizontal
    /// pager of root-shaped pages; nextPage/goToPage actions advance it.
    public var pages: [PaywallPageNode]?
    /// Locale → nodeId → text/url override, applied at render time over the base.
    public var translations: [String: [String: PaywallTreeTranslationEntry]]?

    public init(
        version: Int = 2,
        theme: PaywallTheme,
        darkTheme: PaywallThemeOverride? = nil,
        variables: [String: String]? = nil,
        root: PaywallNode,
        products: [PaywallProduct] = [],
        pages: [PaywallPageNode]? = nil,
        translations: [String: [String: PaywallTreeTranslationEntry]]? = nil
    ) {
        self.version = version
        self.theme = theme
        self.darkTheme = darkTheme
        self.variables = variables
        self.root = root
        self.products = products
        self.pages = pages
        self.translations = translations
    }

    private enum CodingKeys: String, CodingKey {
        case version, theme, darkTheme, variables, root, products, pages, translations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 2
        theme = (try? c.decode(PaywallTheme.self, forKey: .theme)) ?? PaywallTree.fallbackTheme
        darkTheme = try? c.decodeIfPresent(PaywallThemeOverride.self, forKey: .darkTheme)
        variables = try? c.decodeIfPresent([String: String].self, forKey: .variables)
        // A malformed / missing root degrades to an empty vertical scroll stack (never throws).
        root = (try? c.decode(PaywallNode.self, forKey: .root)) ?? PaywallNode.emptyRoot
        products = (try? c.decode([PaywallProduct].self, forKey: .products)) ?? []
        pages = try? c.decodeIfPresent([PaywallPageNode].self, forKey: .pages)
        translations = try? c.decodeIfPresent([String: [String: PaywallTreeTranslationEntry]].self, forKey: .translations)
    }

    /// Last-resort theme used when a tree omits one entirely (kept dark to match the renderer's
    /// default backdrop). Authors always supply a theme; this only guards corrupt input.
    static let fallbackTheme = PaywallTheme(
        primaryColor: "#5b5bd6",
        background: "#0a0a0a",
        textColor: "#ffffff",
        ctaTextColor: "#ffffff",
        cardBackground: nil,
        backgroundType: nil,
        backgroundGradient: nil,
        backgroundImage: nil,
        backgroundVideo: nil,
        backgroundLottie: nil,
        cardBorderRadius: nil,
        buttonBorderRadius: nil,
        fontFamily: nil,
        titleSize: nil,
        titleWeight: nil,
        subtitleSize: nil,
        bodySize: nil
    )
}

/// One page of a multi-step paywall. Same node tree as `root`.
public struct PaywallPageNode: Codable, Equatable, Sendable {
    public var id: String
    /// Editor-only label, never shown to users.
    public var name: String?
    public var root: PaywallNode
    /// Theme override scoped to this page.
    public var themeOverride: PaywallThemeOverride?

    public init(id: String, name: String? = nil, root: PaywallNode, themeOverride: PaywallThemeOverride? = nil) {
        self.id = id
        self.name = name
        self.root = root
        self.themeOverride = themeOverride
    }

    private enum CodingKeys: String, CodingKey { case id, name, root, themeOverride }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        root = (try? c.decode(PaywallNode.self, forKey: .root)) ?? PaywallNode.emptyRoot
        themeOverride = try? c.decodeIfPresent(PaywallThemeOverride.self, forKey: .themeOverride)
    }
}

/// A single locale's per-node text/url override.
public struct PaywallTreeTranslationEntry: Codable, Equatable, Sendable {
    public var text: String?
    public var url: String?

    public init(text: String? = nil, url: String? = nil) {
        self.text = text
        self.url = url
    }
}

// MARK: - PaywallTreeTheme PaywallTheme PaywallThemeOverride merge helper for tree pages

public extension PaywallTheme {
    /// Apply a (partial) override only where the override sets a value. Used for darkTheme + page
    /// themeOverride. Distinct from `merging(_:)` (which already exists for v1) — same semantics.
    func merged(with override: PaywallThemeOverride?) -> PaywallTheme {
        merging(override)
    }
}

// MARK: - Node (the discriminated union)
//
// PaywallNode wraps either a Stack or one of the element kinds, discriminated by `type`. We model
// it as a struct carrying every possible field (most optional) + a `kind` enum, decoded by reading
// the `type` discriminant first. This keeps the renderer's switch exhaustive while letting a single
// Codable type round-trip the whole tree, and lets unknown types decode to `.unknown` (no throw).

public struct PaywallNode: Codable, Equatable, Sendable {

    public enum Kind: String, Sendable {
        case stack, text, image, video, lottie, button
        case productSelector, product, timer, spacer, divider
        case icon, rating, testimonial, custom
        /// Any `type` the SDK doesn't recognise (forward-compat). Renders as EmptyView.
        case unknown
    }

    // ── Common (PaywallNodeBase) ──
    public var id: String
    public var kind: Kind
    public var style: PaywallStyle?
    public var visibleIf: PaywallVisibilityRule?
    public var animation: PaywallAnimation?
    public var onTap: PaywallAction?
    public var haptic: PaywallHaptic?

    // ── Stack ──
    public var direction: PaywallStackDirection?
    public var mainAlign: PaywallMainAlign?
    public var crossAlign: PaywallCrossAlign?
    public var spacing: Double?
    public var wrap: Bool?
    public var scroll: PaywallScroll?
    public var children: [PaywallNode]

    // ── text ──
    public var text: String?
    public var maxLines: Int?

    // ── image / video / lottie ──
    public var url: String?
    public var posterUrl: String?
    public var contentMode: PaywallContentMode?
    public var alt: String?
    public var loop: Bool?
    public var muted: Bool?
    public var autoplay: Bool?
    public var speed: Double?

    // ── button ──
    public var microtext: String?

    // ── productSelector ──
    public var productIds: [String]?
    public var layout: PaywallSelectorLayout?
    public var defaultProductId: String?
    /// Indirect because a node can nest a node (recursive struct). Boxed for value-type recursion.
    public var itemTemplate: PaywallNodeBox?

    // ── product ──
    public var productId: String?

    // ── timer ──
    public var endsAt: String?
    public var durationSec: Double?
    public var format: String?
    public var hideOnExpiry: Bool?

    // ── icon ──
    public var name: String?

    // ── rating ──
    public var value: Double?
    public var max: Double?
    public var label: String?

    // ── testimonial ──
    public var quote: String?
    public var author: String?
    public var avatarUrl: String?
    public var rating: Double?

    // ── custom ──
    public var html: String?
    public var css: String?

    public init(
        id: String,
        kind: Kind,
        style: PaywallStyle? = nil,
        visibleIf: PaywallVisibilityRule? = nil,
        animation: PaywallAnimation? = nil,
        onTap: PaywallAction? = nil,
        haptic: PaywallHaptic? = nil,
        direction: PaywallStackDirection? = nil,
        mainAlign: PaywallMainAlign? = nil,
        crossAlign: PaywallCrossAlign? = nil,
        spacing: Double? = nil,
        wrap: Bool? = nil,
        scroll: PaywallScroll? = nil,
        children: [PaywallNode] = [],
        text: String? = nil,
        maxLines: Int? = nil,
        url: String? = nil,
        posterUrl: String? = nil,
        contentMode: PaywallContentMode? = nil,
        alt: String? = nil,
        loop: Bool? = nil,
        muted: Bool? = nil,
        autoplay: Bool? = nil,
        speed: Double? = nil,
        microtext: String? = nil,
        productIds: [String]? = nil,
        layout: PaywallSelectorLayout? = nil,
        defaultProductId: String? = nil,
        itemTemplate: PaywallNode? = nil,
        productId: String? = nil,
        endsAt: String? = nil,
        durationSec: Double? = nil,
        format: String? = nil,
        hideOnExpiry: Bool? = nil,
        name: String? = nil,
        value: Double? = nil,
        max: Double? = nil,
        label: String? = nil,
        quote: String? = nil,
        author: String? = nil,
        avatarUrl: String? = nil,
        rating: Double? = nil,
        html: String? = nil,
        css: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.style = style
        self.visibleIf = visibleIf
        self.animation = animation
        self.onTap = onTap
        self.haptic = haptic
        self.direction = direction
        self.mainAlign = mainAlign
        self.crossAlign = crossAlign
        self.spacing = spacing
        self.wrap = wrap
        self.scroll = scroll
        self.children = children
        self.text = text
        self.maxLines = maxLines
        self.url = url
        self.posterUrl = posterUrl
        self.contentMode = contentMode
        self.alt = alt
        self.loop = loop
        self.muted = muted
        self.autoplay = autoplay
        self.speed = speed
        self.microtext = microtext
        self.productIds = productIds
        self.layout = layout
        self.defaultProductId = defaultProductId
        self.itemTemplate = itemTemplate.map(PaywallNodeBox.init)
        self.productId = productId
        self.endsAt = endsAt
        self.durationSec = durationSec
        self.format = format
        self.hideOnExpiry = hideOnExpiry
        self.name = name
        self.value = value
        self.max = max
        self.label = label
        self.quote = quote
        self.author = author
        self.avatarUrl = avatarUrl
        self.rating = rating
        self.html = html
        self.css = css
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, style, visibleIf, animation, onTap, haptic
        case direction, mainAlign, crossAlign, spacing, wrap, scroll, children
        case text, maxLines
        case url, posterUrl, contentMode, alt, loop, muted, autoplay, speed
        case microtext
        case productIds, layout, defaultProductId, itemTemplate
        case productId
        case endsAt, durationSec, format, hideOnExpiry
        case name
        case value, max, label
        case quote, author, avatarUrl, rating
        case html, css
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // The `type` discriminant drives the union. An unknown / missing type degrades to `.unknown`
        // (a no-op node), mirroring normalizeNode dropping malformed nodes — here we keep it but
        // render nothing, which is safer for layout (a sibling-positioned node isn't shifted away).
        let rawType = (try? c.decode(String.self, forKey: .type)) ?? ""
        kind = Kind(rawValue: rawType) ?? .unknown

        // Auto-id when missing, mirroring normalizeNode's `n${++autoId}` so keys stay stable enough.
        if let decodedId = try? c.decode(String.self, forKey: .id), !decodedId.isEmpty {
            id = decodedId
        } else {
            id = PaywallNode.autoId()
        }

        style = try? c.decodeIfPresent(PaywallStyle.self, forKey: .style)
        visibleIf = try? c.decodeIfPresent(PaywallVisibilityRule.self, forKey: .visibleIf)
        animation = try? c.decodeIfPresent(PaywallAnimation.self, forKey: .animation)
        onTap = try? c.decodeIfPresent(PaywallAction.self, forKey: .onTap)
        haptic = try? c.decodeIfPresent(PaywallHaptic.self, forKey: .haptic)

        direction = try? c.decodeIfPresent(PaywallStackDirection.self, forKey: .direction)
        mainAlign = try? c.decodeIfPresent(PaywallMainAlign.self, forKey: .mainAlign)
        crossAlign = try? c.decodeIfPresent(PaywallCrossAlign.self, forKey: .crossAlign)
        spacing = try? c.decodeIfPresent(Double.self, forKey: .spacing)
        wrap = try? c.decodeIfPresent(Bool.self, forKey: .wrap)
        scroll = try? c.decodeIfPresent(PaywallScroll.self, forKey: .scroll)
        // Children only meaningful for stacks; tolerate malformed entries by dropping them.
        if let raw = try? c.decode([FailableNode].self, forKey: .children) {
            children = raw.compactMap { $0.node }
        } else {
            children = []
        }

        text = try? c.decodeIfPresent(String.self, forKey: .text)
        maxLines = try? c.decodeIfPresent(Int.self, forKey: .maxLines)

        url = try? c.decodeIfPresent(String.self, forKey: .url)
        posterUrl = try? c.decodeIfPresent(String.self, forKey: .posterUrl)
        contentMode = try? c.decodeIfPresent(PaywallContentMode.self, forKey: .contentMode)
        alt = try? c.decodeIfPresent(String.self, forKey: .alt)
        loop = try? c.decodeIfPresent(Bool.self, forKey: .loop)
        muted = try? c.decodeIfPresent(Bool.self, forKey: .muted)
        autoplay = try? c.decodeIfPresent(Bool.self, forKey: .autoplay)
        speed = try? c.decodeIfPresent(Double.self, forKey: .speed)

        microtext = try? c.decodeIfPresent(String.self, forKey: .microtext)

        productIds = try? c.decodeIfPresent([String].self, forKey: .productIds)
        layout = try? c.decodeIfPresent(PaywallSelectorLayout.self, forKey: .layout)
        defaultProductId = try? c.decodeIfPresent(String.self, forKey: .defaultProductId)
        if let tpl = try? c.decode(PaywallNode.self, forKey: .itemTemplate) {
            itemTemplate = PaywallNodeBox(tpl)
        } else {
            itemTemplate = nil
        }

        productId = try? c.decodeIfPresent(String.self, forKey: .productId)

        endsAt = try? c.decodeIfPresent(String.self, forKey: .endsAt)
        durationSec = try? c.decodeIfPresent(Double.self, forKey: .durationSec)
        format = try? c.decodeIfPresent(String.self, forKey: .format)
        hideOnExpiry = try? c.decodeIfPresent(Bool.self, forKey: .hideOnExpiry)

        name = try? c.decodeIfPresent(String.self, forKey: .name)

        value = try? c.decodeIfPresent(Double.self, forKey: .value)
        max = try? c.decodeIfPresent(Double.self, forKey: .max)
        label = try? c.decodeIfPresent(String.self, forKey: .label)

        quote = try? c.decodeIfPresent(String.self, forKey: .quote)
        author = try? c.decodeIfPresent(String.self, forKey: .author)
        avatarUrl = try? c.decodeIfPresent(String.self, forKey: .avatarUrl)
        rating = try? c.decodeIfPresent(Double.self, forKey: .rating)

        html = try? c.decodeIfPresent(String.self, forKey: .html)
        css = try? c.decodeIfPresent(String.self, forKey: .css)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind == .unknown ? "unknown" : kind.rawValue, forKey: .type)
        try c.encodeIfPresent(style, forKey: .style)
        try c.encodeIfPresent(visibleIf, forKey: .visibleIf)
        try c.encodeIfPresent(animation, forKey: .animation)
        try c.encodeIfPresent(onTap, forKey: .onTap)
        try c.encodeIfPresent(haptic, forKey: .haptic)
        try c.encodeIfPresent(direction, forKey: .direction)
        try c.encodeIfPresent(mainAlign, forKey: .mainAlign)
        try c.encodeIfPresent(crossAlign, forKey: .crossAlign)
        try c.encodeIfPresent(spacing, forKey: .spacing)
        try c.encodeIfPresent(wrap, forKey: .wrap)
        try c.encodeIfPresent(scroll, forKey: .scroll)
        if kind == .stack { try c.encode(children, forKey: .children) }
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(maxLines, forKey: .maxLines)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(posterUrl, forKey: .posterUrl)
        try c.encodeIfPresent(contentMode, forKey: .contentMode)
        try c.encodeIfPresent(alt, forKey: .alt)
        try c.encodeIfPresent(loop, forKey: .loop)
        try c.encodeIfPresent(muted, forKey: .muted)
        try c.encodeIfPresent(autoplay, forKey: .autoplay)
        try c.encodeIfPresent(speed, forKey: .speed)
        try c.encodeIfPresent(microtext, forKey: .microtext)
        try c.encodeIfPresent(productIds, forKey: .productIds)
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encodeIfPresent(defaultProductId, forKey: .defaultProductId)
        try c.encodeIfPresent(itemTemplate?.node, forKey: .itemTemplate)
        try c.encodeIfPresent(productId, forKey: .productId)
        try c.encodeIfPresent(endsAt, forKey: .endsAt)
        try c.encodeIfPresent(durationSec, forKey: .durationSec)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encodeIfPresent(hideOnExpiry, forKey: .hideOnExpiry)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(max, forKey: .max)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(quote, forKey: .quote)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(avatarUrl, forKey: .avatarUrl)
        try c.encodeIfPresent(rating, forKey: .rating)
        try c.encodeIfPresent(html, forKey: .html)
        try c.encodeIfPresent(css, forKey: .css)
    }

    // Auto-id counter (mirrors normalizeNode's `n${++autoId}`). Atomic enough for decode on one
    // thread; collisions across decodes don't matter because ids are per-tree render keys.
    private static let lock = NSLock()
    private static var counter = 0
    static func autoId() -> String {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return "n\(counter)"
    }

    /// A minimal empty vertical scroll root used as the never-throw fallback.
    static var emptyRoot: PaywallNode {
        PaywallNode(
            id: "root",
            kind: .stack,
            style: PaywallStyle(padding: .all(20), useThemeBackground: true),
            direction: .vertical,
            crossAlign: .stretch,
            spacing: 12,
            scroll: PaywallScroll(mode: .normal),
            children: []
        )
    }
}

/// Value-type box for the recursive `itemTemplate` field (a struct can't directly contain itself).
public final class PaywallNodeBox: Codable, Equatable, @unchecked Sendable {
    public let node: PaywallNode
    public init(_ node: PaywallNode) { self.node = node }
    public init(from decoder: Decoder) throws { node = try PaywallNode(from: decoder) }
    public func encode(to encoder: Encoder) throws { try node.encode(to: encoder) }
    public static func == (lhs: PaywallNodeBox, rhs: PaywallNodeBox) -> Bool { lhs.node == rhs.node }
}

/// Wrapper so a malformed child in a children[] array is dropped instead of failing the whole array.
private struct FailableNode: Decodable {
    let node: PaywallNode?
    init(from decoder: Decoder) throws {
        node = try? PaywallNode(from: decoder)
    }
}

// MARK: - Stack enums

public enum PaywallStackDirection: String, Codable, Sendable {
    case horizontal, vertical, layered
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallStackDirection(rawValue: raw) ?? .vertical
    }
}

public enum PaywallMainAlign: String, Codable, Sendable {
    case start, center, end
    case spaceBetween = "space-between"
    case spaceAround = "space-around"
    case spaceEvenly = "space-evenly"
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallMainAlign(rawValue: raw) ?? .start
    }
}

public enum PaywallCrossAlign: String, Codable, Sendable {
    case start, center, end, stretch
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallCrossAlign(rawValue: raw) ?? .start
    }
}

public struct PaywallScroll: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case none, normal, paging, infinite
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Mode(rawValue: raw) ?? .none
        }
    }
    public var mode: Mode
    public var snap: Bool?
    public var autoPageMs: Double?
    public var speed: Double?
    public var indicator: Bool?

    public init(mode: Mode, snap: Bool? = nil, autoPageMs: Double? = nil, speed: Double? = nil, indicator: Bool? = nil) {
        self.mode = mode
        self.snap = snap
        self.autoPageMs = autoPageMs
        self.speed = speed
        self.indicator = indicator
    }
}

// MARK: - Element enums

public enum PaywallContentMode: String, Codable, Sendable {
    case cover, contain, fill
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallContentMode(rawValue: raw) ?? .cover
    }
}

public enum PaywallSelectorLayout: String, Codable, Sendable {
    case list, grid, horizontal
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallSelectorLayout(rawValue: raw) ?? .list
    }
}

public enum PaywallHaptic: String, Codable, Sendable {
    case light, medium, heavy
    case selection, success, warning, error
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // Unknown haptic = no haptic; decode to `.selection` would be wrong, so map to light (the
        // mildest) rather than throwing. The renderer treats any value as a valid intensity.
        self = PaywallHaptic(rawValue: raw) ?? .light
    }
}

// MARK: - Style

public struct PaywallStyle: Codable, Equatable, Sendable {
    // ── size ──
    public var width: PaywallSize?
    public var height: PaywallSize?
    public var minWidth: Double?
    public var maxWidth: Double?
    public var minHeight: Double?
    public var maxHeight: Double?
    public var grow: Double?
    public var alignSelf: PaywallAlignSelf?

    // ── spacing ──
    public var padding: PaywallEdges?
    public var margin: PaywallEdges?

    // ── background ──
    public var background: String?
    public var backgroundGradient: PaywallGradient?
    public var backgroundImage: PaywallBackgroundImage?
    public var backgroundVideo: PaywallBackgroundVideo?
    public var backgroundLottie: PaywallBackgroundLottie?
    public var useThemeBackground: Bool?

    // ── shape ──
    public var cornerRadius: PaywallCornerRadius?
    public var border: PaywallBorder?
    public var shadow: PaywallShadow?
    public var opacity: Double?
    public var clip: Bool?

    // ── typography ──
    public var fontFamily: String?
    public var fontSize: Double?
    public var fontWeight: FlexibleString?
    public var lineHeight: Double?
    public var letterSpacing: Double?
    public var color: String?
    public var textAlign: PaywallTextAlign?
    public var textTransform: PaywallTextTransform?

    // ── position ──
    public var position: PaywallPosition?
    public var top: Double?
    public var right: Double?
    public var bottom: Double?
    public var left: Double?
    public var zIndex: Double?

    public init(
        width: PaywallSize? = nil,
        height: PaywallSize? = nil,
        minWidth: Double? = nil,
        maxWidth: Double? = nil,
        minHeight: Double? = nil,
        maxHeight: Double? = nil,
        grow: Double? = nil,
        alignSelf: PaywallAlignSelf? = nil,
        padding: PaywallEdges? = nil,
        margin: PaywallEdges? = nil,
        background: String? = nil,
        backgroundGradient: PaywallGradient? = nil,
        backgroundImage: PaywallBackgroundImage? = nil,
        backgroundVideo: PaywallBackgroundVideo? = nil,
        backgroundLottie: PaywallBackgroundLottie? = nil,
        useThemeBackground: Bool? = nil,
        cornerRadius: PaywallCornerRadius? = nil,
        border: PaywallBorder? = nil,
        shadow: PaywallShadow? = nil,
        opacity: Double? = nil,
        clip: Bool? = nil,
        fontFamily: String? = nil,
        fontSize: Double? = nil,
        fontWeight: FlexibleString? = nil,
        lineHeight: Double? = nil,
        letterSpacing: Double? = nil,
        color: String? = nil,
        textAlign: PaywallTextAlign? = nil,
        textTransform: PaywallTextTransform? = nil,
        position: PaywallPosition? = nil,
        top: Double? = nil,
        right: Double? = nil,
        bottom: Double? = nil,
        left: Double? = nil,
        zIndex: Double? = nil
    ) {
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.grow = grow
        self.alignSelf = alignSelf
        self.padding = padding
        self.margin = margin
        self.background = background
        self.backgroundGradient = backgroundGradient
        self.backgroundImage = backgroundImage
        self.backgroundVideo = backgroundVideo
        self.backgroundLottie = backgroundLottie
        self.useThemeBackground = useThemeBackground
        self.cornerRadius = cornerRadius
        self.border = border
        self.shadow = shadow
        self.opacity = opacity
        self.clip = clip
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
        self.color = color
        self.textAlign = textAlign
        self.textTransform = textTransform
        self.position = position
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.zIndex = zIndex
    }
}

public enum PaywallAlignSelf: String, Codable, Sendable {
    case start, center, end, stretch
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallAlignSelf(rawValue: raw) ?? .start
    }
}

public enum PaywallTextAlign: String, Codable, Sendable {
    case left, center, right
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallTextAlign(rawValue: raw) ?? .left
    }
}

public enum PaywallTextTransform: String, Codable, Sendable {
    case none, uppercase, lowercase, capitalize
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallTextTransform(rawValue: raw) ?? .none
    }

    /// Apply this transform to a string.
    public func apply(_ s: String) -> String {
        switch self {
        case .none: return s
        case .uppercase: return s.uppercased()
        case .lowercase: return s.lowercased()
        case .capitalize: return s.capitalized
        }
    }
}

public enum PaywallPosition: String, Codable, Sendable {
    case normal, relative, absolute, fixed, sticky
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallPosition(rawValue: raw) ?? .normal
    }
}

// MARK: - Size (number | "fill" | "hug" | { percent })

public enum PaywallSize: Codable, Equatable, Sendable {
    case points(Double)
    case fill
    case hug
    case percent(Double)

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let d = try? single.decode(Double.self) {
            self = .points(d)
            return
        }
        if let s = try? single.decode(String.self) {
            switch s {
            case "fill": self = .fill
            case "hug": self = .hug
            default:
                // Tolerate "50%" string form (CSS-ish) → percent. Otherwise treat as hug.
                if s.hasSuffix("%"), let p = Double(s.dropLast()) { self = .percent(p) }
                else { self = .hug }
            }
            return
        }
        // Object form: { "percent": N }.
        let obj = try decoder.container(keyedBy: ObjectKeys.self)
        if let p = try? obj.decode(Double.self, forKey: .percent) {
            self = .percent(p)
            return
        }
        // Unknown shape → hug (wrap content) so layout never breaks.
        self = .hug
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .points(let d):
            var c = encoder.singleValueContainer()
            try c.encode(d)
        case .fill:
            var c = encoder.singleValueContainer()
            try c.encode("fill")
        case .hug:
            var c = encoder.singleValueContainer()
            try c.encode("hug")
        case .percent(let p):
            var c = encoder.container(keyedBy: ObjectKeys.self)
            try c.encode(p, forKey: .percent)
        }
    }

    private enum ObjectKeys: String, CodingKey { case percent }
}

// MARK: - Edges (number | { per-side })

public struct PaywallEdges: Codable, Equatable, Sendable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double = 0, right: Double = 0, bottom: Double = 0, left: Double = 0) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    /// Convenience: same inset on every side.
    public static func all(_ v: Double) -> PaywallEdges { PaywallEdges(top: v, right: v, bottom: v, left: v) }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let d = try? single.decode(Double.self) {
            self = .all(d)
            return
        }
        let obj = try decoder.container(keyedBy: ObjectKeys.self)
        top = (try? obj.decodeIfPresent(Double.self, forKey: .top)) ?? 0
        right = (try? obj.decodeIfPresent(Double.self, forKey: .right)) ?? 0
        bottom = (try? obj.decodeIfPresent(Double.self, forKey: .bottom)) ?? 0
        left = (try? obj.decodeIfPresent(Double.self, forKey: .left)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        // Round-trip as the object form (lossless for the per-side case).
        var c = encoder.container(keyedBy: ObjectKeys.self)
        try c.encode(top, forKey: .top)
        try c.encode(right, forKey: .right)
        try c.encode(bottom, forKey: .bottom)
        try c.encode(left, forKey: .left)
    }

    private enum ObjectKeys: String, CodingKey { case top, right, bottom, left }
}

// MARK: - Corner radius (number | { per-corner })

public struct PaywallCornerRadius: Codable, Equatable, Sendable {
    public var topLeft: Double
    public var topRight: Double
    public var bottomRight: Double
    public var bottomLeft: Double

    public init(topLeft: Double = 0, topRight: Double = 0, bottomRight: Double = 0, bottomLeft: Double = 0) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Convenience: same radius on every corner.
    public static func all(_ v: Double) -> PaywallCornerRadius {
        PaywallCornerRadius(topLeft: v, topRight: v, bottomRight: v, bottomLeft: v)
    }

    /// True when every corner shares the same radius (the common case → a plain RoundedRectangle).
    public var isUniform: Bool {
        topLeft == topRight && topRight == bottomRight && bottomRight == bottomLeft
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let d = try? single.decode(Double.self) {
            self = .all(d)
            return
        }
        let obj = try decoder.container(keyedBy: ObjectKeys.self)
        topLeft = (try? obj.decodeIfPresent(Double.self, forKey: .topLeft)) ?? 0
        topRight = (try? obj.decodeIfPresent(Double.self, forKey: .topRight)) ?? 0
        bottomRight = (try? obj.decodeIfPresent(Double.self, forKey: .bottomRight)) ?? 0
        bottomLeft = (try? obj.decodeIfPresent(Double.self, forKey: .bottomLeft)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ObjectKeys.self)
        try c.encode(topLeft, forKey: .topLeft)
        try c.encode(topRight, forKey: .topRight)
        try c.encode(bottomRight, forKey: .bottomRight)
        try c.encode(bottomLeft, forKey: .bottomLeft)
    }

    private enum ObjectKeys: String, CodingKey { case topLeft, topRight, bottomRight, bottomLeft }
}

// MARK: - Border / shadow

public struct PaywallBorder: Codable, Equatable, Sendable {
    public var width: Double
    public var color: String
    public var style: BorderStyle?

    public enum BorderStyle: String, Codable, Sendable {
        case solid, dashed, dotted
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = BorderStyle(rawValue: raw) ?? .solid
        }
    }

    public init(width: Double, color: String, style: BorderStyle? = nil) {
        self.width = width
        self.color = color
        self.style = style
    }
}

public struct PaywallShadow: Codable, Equatable, Sendable {
    public var color: String?
    public var radius: Double
    public var x: Double?
    public var y: Double?
    public var opacity: Double?

    public init(color: String? = nil, radius: Double, x: Double? = nil, y: Double? = nil, opacity: Double? = nil) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
        self.opacity = opacity
    }
}

// MARK: - Action

public enum PaywallAction: Codable, Equatable, Sendable {
    case purchase(productId: String?)
    case restore
    case dismiss
    case url(String)
    case selectProduct(productId: String)
    case nextPage
    case prevPage
    case goToPage(pageId: String)
    case event(name: String)
    /// Forward-compat: any action `type` the SDK doesn't recognise. No-op when tapped.
    case unknown

    private enum CodingKeys: String, CodingKey { case type, productId, url, pageId, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "purchase": self = .purchase(productId: try? c.decodeIfPresent(String.self, forKey: .productId))
        case "restore": self = .restore
        case "dismiss": self = .dismiss
        case "url": self = .url((try? c.decode(String.self, forKey: .url)) ?? "")
        case "selectProduct": self = .selectProduct(productId: (try? c.decode(String.self, forKey: .productId)) ?? "")
        case "nextPage": self = .nextPage
        case "prevPage": self = .prevPage
        case "goToPage": self = .goToPage(pageId: (try? c.decode(String.self, forKey: .pageId)) ?? "")
        case "event": self = .event(name: (try? c.decode(String.self, forKey: .name)) ?? "")
        default: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .purchase(let pid):
            try c.encode("purchase", forKey: .type)
            try c.encodeIfPresent(pid, forKey: .productId)
        case .restore: try c.encode("restore", forKey: .type)
        case .dismiss: try c.encode("dismiss", forKey: .type)
        case .url(let u):
            try c.encode("url", forKey: .type)
            try c.encode(u, forKey: .url)
        case .selectProduct(let pid):
            try c.encode("selectProduct", forKey: .type)
            try c.encode(pid, forKey: .productId)
        case .nextPage: try c.encode("nextPage", forKey: .type)
        case .prevPage: try c.encode("prevPage", forKey: .type)
        case .goToPage(let pid):
            try c.encode("goToPage", forKey: .type)
            try c.encode(pid, forKey: .pageId)
        case .event(let n):
            try c.encode("event", forKey: .type)
            try c.encode(n, forKey: .name)
        case .unknown: try c.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - Visibility rule (superset of v1 PaywallProductVisibility)

public struct PaywallVisibilityRule: Codable, Equatable, Sendable {
    // Shared dimensions (mirror PaywallProductVisibility).
    public var isNewUser: Bool?
    public var hasUsedTrial: Bool?
    public var countries: [String]?
    public var platforms: [String]?
    public var daysSinceInstallMin: Int?
    public var daysSinceInstallMax: Int?
    // v2 extras.
    public var isSubscribed: Bool?
    public var locales: [String]?

    public init(
        isNewUser: Bool? = nil,
        hasUsedTrial: Bool? = nil,
        countries: [String]? = nil,
        platforms: [String]? = nil,
        daysSinceInstallMin: Int? = nil,
        daysSinceInstallMax: Int? = nil,
        isSubscribed: Bool? = nil,
        locales: [String]? = nil
    ) {
        self.isNewUser = isNewUser
        self.hasUsedTrial = hasUsedTrial
        self.countries = countries
        self.platforms = platforms
        self.daysSinceInstallMin = daysSinceInstallMin
        self.daysSinceInstallMax = daysSinceInstallMax
        self.isSubscribed = isSubscribed
        self.locales = locales
    }

    /// Project the shared dimensions onto the v1 PaywallProductVisibility so isProductVisible reuse
    /// stays byte-for-byte with the v1 logic. Uses the v1 struct's synthesized memberwise init.
    var asProductVisibility: PaywallProductVisibility {
        PaywallProductVisibility(
            isNewUser: isNewUser,
            hasUsedTrial: hasUsedTrial,
            countries: countries,
            platforms: platforms,
            daysSinceInstallMin: daysSinceInstallMin,
            daysSinceInstallMax: daysSinceInstallMax
        )
    }
}

// MARK: - Tree transforms (mirror the TS helpers in paywallTree.ts)

public enum PaywallTreeTransforms {

    /// Interpolate `{{ ns.key }}` tokens. Namespaces:
    ///   {{var.NAME}}    — tree.variables
    ///   {{product.X}}   — fields of the bound/selected product
    ///   {{theme.X}}     — theme color tokens
    /// Unresolved tokens render EMPTY (never leak raw `{{...}}` to end users) — mirrors interpolate()
    /// in paywallTree.ts. Note the v2 namespacing differs from the v1 flat PaywallTransforms.interpolate.
    public static func interpolate(
        _ text: String,
        variables: [String: String]?,
        product: [String: String]?,
        theme: PaywallTheme?
    ) -> String {
        guard !text.isEmpty, text.contains("{{") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{"),
              let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            result += rest[rest.startIndex..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound]
            let token = inner.trimmingCharacters(in: .whitespaces)
            result += resolveToken(token, original: "{{\(inner)}}", variables: variables, product: product, theme: theme)
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    private static func resolveToken(
        _ token: String,
        original: String,
        variables: [String: String]?,
        product: [String: String]?,
        theme: PaywallTheme?
    ) -> String {
        let parts = token.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "" }
        let ns = parts[0], key = parts[1]
        switch ns {
        case "var":
            if let v = variables?[key] { return v }
        case "product":
            if let v = product?[key] { return v }
        case "theme":
            if let v = themeToken(key, theme: theme) { return v }
        default:
            break
        }
        // Unresolved → empty (a paywall must never show literal mustache syntax).
        _ = original
        return ""
    }

    /// Resolve the small set of theme color/typography tokens addressable via `{{theme.X}}`.
    private static func themeToken(_ key: String, theme: PaywallTheme?) -> String? {
        guard let theme else { return nil }
        switch key {
        case "primaryColor", "primary": return theme.primaryColor
        case "background": return theme.background
        case "textColor", "text": return theme.textColor
        case "ctaTextColor": return theme.ctaTextColor
        case "cardBackground": return theme.cardBackground
        case "fontFamily": return theme.fontFamily
        default: return nil
        }
    }

    /// Whether a node renders for the given user context. Reuses the v1 product-visibility logic
    /// for the shared dimensions, then applies the v2 extras (isSubscribed, locales). Missing
    /// context fields skip their rule (over-show rather than silently hide). Mirrors isNodeVisible().
    public static func isNodeVisible(
        _ node: PaywallNode,
        context: PaywallUserContext?,
        isSubscribed: Bool? = nil,
        locale: String? = nil
    ) -> Bool {
        guard let rule = node.visibleIf else { return true }
        // Shared dimensions via the v1 helper (projects the rule onto a product-like shape).
        let probe = PaywallProduct(identifier: "", label: "", visibility: rule.asProductVisibility)
        if !PaywallTransforms.isProductVisible(probe, context) { return false }
        if let want = rule.isSubscribed, let have = isSubscribed, want != have { return false }
        if let locales = rule.locales, !locales.isEmpty, let loc = locale {
            if !locales.contains(where: { $0.lowercased() == loc.lowercased() }) { return false }
        }
        return true
    }

    /// Apply a locale's per-node text/url overrides over a tree (returns a new tree). Falls back
    /// from a region code ("fr-CA") to the language-only code ("fr"). Mirrors applyTreeTranslation().
    public static func applyTranslation(_ tree: PaywallTree, locale: String?) -> PaywallTree {
        guard let locale, let translations = tree.translations else { return tree }
        let base = String(locale.split(separator: "-").first ?? "")
        guard let t = translations[locale] ?? translations[base] else { return tree }

        func apply(_ node: PaywallNode) -> PaywallNode {
            var next = node
            if let o = t[node.id] {
                if let txt = o.text { next.text = txt }
                if let u = o.url { next.url = u }
            }
            if next.kind == .stack {
                next.children = next.children.map(apply)
            }
            return next
        }

        var out = tree
        out.root = apply(tree.root)
        out.pages = tree.pages?.map { page in
            var p = page
            p.root = apply(page.root)
            return p
        }
        return out
    }

    /// Find a node by id anywhere in the tree (incl. pages + item templates). Mirrors findNode().
    public static func findNode(_ tree: PaywallTree, id: String) -> PaywallNode? {
        var roots: [PaywallNode] = [tree.root]
        roots.append(contentsOf: tree.pages?.map { $0.root } ?? [])
        for r in roots {
            if let found = walkFind(r, id: id) { return found }
        }
        return nil
    }

    private static func walkFind(_ node: PaywallNode, id: String) -> PaywallNode? {
        if node.id == id { return node }
        if node.kind == .stack {
            for c in node.children {
                if let f = walkFind(c, id: id) { return f }
            }
        }
        if let tpl = node.itemTemplate?.node {
            if let f = walkFind(tpl, id: id) { return f }
        }
        return nil
    }
}

// MARK: - Document-version detection

/// Sniff the `version` field off raw paywall JSON so the public entry can route v2 trees to the
/// native tree renderer and v1 documents to the existing preset renderer. Tolerant — anything that
/// isn't an explicit `2` is treated as v1 (the established format).
public enum PaywallDocumentVersion {
    case v1
    case v2

    /// Detect from a JSON `Data` blob that may be a bare document/tree OR a wrapping
    /// `PaywallResponse` (`{ "document": { "version": N, ... } }`).
    public static func detect(from data: Data) -> PaywallDocumentVersion {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .v1 }
        // Unwrap a response envelope if present.
        let docObj = (obj["document"] as? [String: Any]) ?? obj
        if let v = docObj["version"] as? Int, v >= 2 { return .v2 }
        if let n = docObj["version"] as? NSNumber, n.intValue >= 2 { return .v2 }
        return .v1
    }
}
