import Foundation

// MARK: - Paywall document
//
// Mirrors the document shape served by `GET /v1/paywalls/by-identifier/{id}`, ported from the
// React Native SDK's `types.ts`. The dashboard owns the canonical schema; the SDK consumes it
// forward-compatibly — unknown fields are ignored by the decoder, and adding new optional fields
// is non-breaking. JSON keys are camelCase (matching the wire format), so no key strategy is set.

public enum PaywallLayout: String, Codable, Sendable {
    case verticalFeatures = "vertical-features"
    case horizontalProducts = "horizontal-products"
    case comparisonTable = "comparison-table"
    case minimal
    case heroImage = "hero-image"

    /// Forward-compatible decode: an unknown layout falls back to vertical-features.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallLayout(rawValue: raw) ?? .verticalFeatures
    }
}

public enum PaywallBackgroundType: String, Codable, Sendable {
    case solid, gradient, image, video, lottie

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaywallBackgroundType(rawValue: raw) ?? .solid
    }
}

public struct PaywallGradient: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    /// Degrees, CSS convention: 0 = top, 90 = right, 180 = bottom.
    public let angle: Double
}

public struct PaywallBackgroundImage: Codable, Equatable, Sendable {
    public let url: String
    /// Optional rgba overlay applied above the image so text stays readable.
    public let overlay: String?
    /// CSS background-position keyword pair (e.g. "center", "top left").
    public let position: String?
    /// CSS background-size keyword ("cover" | "contain") or percentage.
    public let size: String?
    /// Blur applied to the image only (CSS px).
    public let blur: Double?
    /// Image opacity 0-1. Fades the image into the solid background.
    public let opacity: Double?
}

public struct PaywallBackgroundLottie: Codable, Equatable, Sendable {
    public let url: String
    public let posterUrl: String?
    public let autoplay: Bool?
    public let loop: Bool?
    public let speed: Double?
    public let overlay: String?
}

public struct PaywallBackgroundVideo: Codable, Equatable, Sendable {
    public let url: String
    public let posterUrl: String?
    public let loop: Bool?
    public let muted: Bool?
    public let overlay: String?
}

/// `titleWeight` is `number | string` on the wire — decode either into a string.
public struct FlexibleString: Codable, Equatable, Sendable {
    public let value: String?
    public init(_ value: String?) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let d = try? c.decode(Double.self) { value = (d == d.rounded()) ? String(Int(d)) : String(d) }
        else { value = nil }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

public struct PaywallTheme: Codable, Equatable, Sendable {
    public var primaryColor: String
    /// Solid fallback colour, also used when backgroundType is 'solid'.
    public var background: String
    public var textColor: String
    public var ctaTextColor: String?
    public var cardBackground: String?

    public var backgroundType: PaywallBackgroundType?
    public var backgroundGradient: PaywallGradient?
    public var backgroundImage: PaywallBackgroundImage?
    public var backgroundVideo: PaywallBackgroundVideo?
    public var backgroundLottie: PaywallBackgroundLottie?

    public var cardBorderRadius: Double?
    public var buttonBorderRadius: Double?

    public var fontFamily: String?
    public var titleSize: Double?
    public var titleWeight: FlexibleString?
    public var subtitleSize: Double?
    public var bodySize: Double?

    /// Merge another (partial) theme on top of this one — used to apply darkTheme / themeOverride.
    public func merging(_ override: PaywallThemeOverride?) -> PaywallTheme {
        guard let o = override else { return self }
        var t = self
        if let v = o.primaryColor { t.primaryColor = v }
        if let v = o.background { t.background = v }
        if let v = o.textColor { t.textColor = v }
        if let v = o.ctaTextColor { t.ctaTextColor = v }
        if let v = o.cardBackground { t.cardBackground = v }
        if let v = o.backgroundType { t.backgroundType = v }
        if let v = o.backgroundGradient { t.backgroundGradient = v }
        if let v = o.backgroundImage { t.backgroundImage = v }
        if let v = o.backgroundVideo { t.backgroundVideo = v }
        if let v = o.backgroundLottie { t.backgroundLottie = v }
        if let v = o.cardBorderRadius { t.cardBorderRadius = v }
        if let v = o.buttonBorderRadius { t.buttonBorderRadius = v }
        if let v = o.fontFamily { t.fontFamily = v }
        if let v = o.titleSize { t.titleSize = v }
        if let v = o.titleWeight { t.titleWeight = v }
        if let v = o.subtitleSize { t.subtitleSize = v }
        if let v = o.bodySize { t.bodySize = v }
        return t
    }
}

/// Partial theme override (darkTheme / page themeOverride). All fields optional.
public struct PaywallThemeOverride: Codable, Equatable, Sendable {
    public var primaryColor: String?
    public var background: String?
    public var textColor: String?
    public var ctaTextColor: String?
    public var cardBackground: String?
    public var backgroundType: PaywallBackgroundType?
    public var backgroundGradient: PaywallGradient?
    public var backgroundImage: PaywallBackgroundImage?
    public var backgroundVideo: PaywallBackgroundVideo?
    public var backgroundLottie: PaywallBackgroundLottie?
    public var cardBorderRadius: Double?
    public var buttonBorderRadius: Double?
    public var fontFamily: String?
    public var titleSize: Double?
    public var titleWeight: FlexibleString?
    public var subtitleSize: Double?
    public var bodySize: Double?
}

public struct PaywallHeader: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var logoUrl: String?
    public var heroImageUrl: String?
    /// Custom height for the hero image band. Defaults to 240 in the renderer.
    public var heroImageHeight: Double?
    public var align: String?  // "left" | "center"
}

public struct PaywallFeature: Codable, Equatable, Sendable {
    public var icon: String
    public var text: String
}

public struct PaywallProductVisibility: Codable, Equatable, Sendable {
    public var isNewUser: Bool?
    public var hasUsedTrial: Bool?
    public var countries: [String]?
    public var platforms: [String]?
    public var daysSinceInstallMin: Int?
    public var daysSinceInstallMax: Int?
}

public struct PaywallProduct: Codable, Equatable, Sendable {
    public var identifier: String
    public var label: String
    public var sublabel: String?
    public var badge: String?
    public var highlight: Bool?
    public var visibility: PaywallProductVisibility?
    /// Per-feature inclusion flags for comparison-table layout (indexed by feature position).
    public var featureMatches: [String: Bool]?
    /// Optional free-trial duration in days. The renderer shows a trial badge.
    public var trialDays: Int?
    /// Display price (e.g. "$9.99"). Filled by the host with the live store price; carried in the
    /// document so `{{product.price}}` resolves on the native renderer. Optional + additive.
    public var price: String?

    public init(
        identifier: String,
        label: String,
        sublabel: String? = nil,
        badge: String? = nil,
        highlight: Bool? = nil,
        visibility: PaywallProductVisibility? = nil,
        featureMatches: [String: Bool]? = nil,
        trialDays: Int? = nil,
        price: String? = nil
    ) {
        self.identifier = identifier
        self.label = label
        self.sublabel = sublabel
        self.badge = badge
        self.highlight = highlight
        self.visibility = visibility
        self.featureMatches = featureMatches
        self.trialDays = trialDays
        self.price = price
    }
}

/// Caller-supplied user state used to filter visibility-gated products.
public struct PaywallUserContext: Sendable {
    public var isNewUser: Bool?
    public var hasUsedTrial: Bool?
    public var country: String?
    public var platform: String?  // "ios" | "android" | "web"
    public var daysSinceInstall: Int?

    public init(
        isNewUser: Bool? = nil,
        hasUsedTrial: Bool? = nil,
        country: String? = nil,
        platform: String? = "ios",
        daysSinceInstall: Int? = nil
    ) {
        self.isNewUser = isNewUser
        self.hasUsedTrial = hasUsedTrial
        self.country = country
        self.platform = platform
        self.daysSinceInstall = daysSinceInstall
    }
}

public struct PaywallCta: Codable, Equatable, Sendable {
    public var text: String
    public var shape: String?  // "pill" | "rounded" | "square"
    public var microtext: String?
}

public struct PaywallFooter: Codable, Equatable, Sendable {
    public var restoreText: String?
    public var termsUrl: String?
    public var privacyUrl: String?
}

public struct PaywallVisibility: Codable, Equatable, Sendable {
    public var features: Bool?
    public var products: Bool?
    public var footer: Bool?
    public var subtitle: Bool?
    public var closeButton: Bool?
    public var socialProof: Bool?
}

public struct PaywallTestimonial: Codable, Equatable, Sendable {
    public var quote: String
    public var author: String?
    public var avatarUrl: String?
    public var rating: Double?
}

public struct PaywallRating: Codable, Equatable, Sendable {
    public var stars: Double
    public var count: Int?
    public var label: String?
}

public struct PaywallSocialProof: Codable, Equatable, Sendable {
    public var rating: PaywallRating?
    public var testimonials: [PaywallTestimonial]?
    public var userCountText: String?
}

public struct PaywallUrgency: Codable, Equatable, Sendable {
    public var bannerText: String?
    public var endsAt: String?
    public var tone: String?  // "limited" | "discount" | "trial" | "lastChance"

    public init(bannerText: String? = nil, endsAt: String? = nil, tone: String? = nil) {
        self.bannerText = bannerText
        self.endsAt = endsAt
        self.tone = tone
    }
}

// MARK: - Free-trial toggle (Superwall-style switch)
//
// A switch that flips the selected product between a paid product and a free-trial product.
// The renderer binds a Bool to it; flipping ON selects `trialProductId`, OFF selects `paidProductId`.
// When the ids are omitted the renderer infers them (a product with trialDays > 0 = trial product).

public struct PaywallTrialToggle: Codable, Equatable, Sendable {
    /// Switch label, e.g. "Enable free trial". Interpolated like other text.
    public var label: String?
    /// Smaller helper line under the label, e.g. "7 days free, cancel anytime".
    public var caption: String?
    /// Product selected when the switch is ON. If nil the renderer picks the first product
    /// whose `trialDays` > 0.
    public var trialProductId: String?
    /// Product selected when the switch is OFF. If nil the renderer picks the first product
    /// whose `trialDays` is 0 / nil (the paid plan).
    public var paidProductId: String?
    /// Whether the switch starts ON. Default true (trial pre-selected — the converting default).
    public var defaultOn: Bool?

    public init(
        label: String? = nil,
        caption: String? = nil,
        trialProductId: String? = nil,
        paidProductId: String? = nil,
        defaultOn: Bool? = nil
    ) {
        self.label = label
        self.caption = caption
        self.trialProductId = trialProductId
        self.paidProductId = paidProductId
        self.defaultOn = defaultOn
    }
}

// MARK: - Tabs (tier switching)
//
// A segmented control above the products that swaps which products are shown. Each tab declares the
// set of product identifiers it owns; selecting a tab filters the product list to that set. Lets a
// paywall present "Personal / Family / Business" tiers without three separate paywalls.

public struct PaywallTab: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    /// Product identifiers shown when this tab is active. Empty / nil = show all products.
    public var productIds: [String]?
    /// Optional small badge on the tab itself ("Popular").
    public var badge: String?

    public init(id: String, label: String, productIds: [String]? = nil, badge: String? = nil) {
        self.id = id
        self.label = label
        self.productIds = productIds
        self.badge = badge
    }
}

public struct PaywallTabs: Codable, Equatable, Sendable {
    public var tabs: [PaywallTab]
    /// Tab id selected initially. Defaults to the first tab.
    public var defaultTabId: String?

    public init(tabs: [PaywallTab], defaultTabId: String? = nil) {
        self.tabs = tabs
        self.defaultTabId = defaultTabId
    }
}

// MARK: - Timeline ("how it works")
//
// An ordered list of steps shown as a vertical timeline (numbered nodes + a connecting line).
// The canonical onboarding device: "Today: full access → Day 5: reminder → Day 7: billed".

public struct PaywallTimelineStep: Codable, Equatable, Sendable {
    /// Leading label on the node, e.g. "Today", "Day 5", "Day 7". Optional — falls back to "1./2.".
    public var label: String?
    public var title: String
    public var description: String?
    /// SF-Symbol-mappable icon name (same set as features). Optional — falls back to a numbered dot.
    public var icon: String?

    public init(label: String? = nil, title: String, description: String? = nil, icon: String? = nil) {
        self.label = label
        self.title = title
        self.description = description
        self.icon = icon
    }
}

public struct PaywallTimeline: Codable, Equatable, Sendable {
    public var heading: String?
    public var steps: [PaywallTimelineStep]

    public init(heading: String? = nil, steps: [PaywallTimelineStep]) {
        self.heading = heading
        self.steps = steps
    }
}

public struct PaywallAnimation: Codable, Equatable, Sendable {
    /// "fade" | "fade-up" | "fade-down" | "scale" | "slide-up" | "slide-down" | "slide-left" | "slide-right"
    public var type: String
    public var delay: Double?
    public var duration: Double?
}

public struct PaywallAnimations: Codable, Equatable, Sendable {
    public var header: PaywallAnimation?
    public var features: PaywallAnimation?
    public var featureStagger: Double?
    public var products: PaywallAnimation?
    public var productStagger: Double?
    public var cta: PaywallAnimation?
    public var footer: PaywallAnimation?
}

public struct PaywallTranslationHeader: Codable, Equatable, Sendable {
    public var title: String?
    public var subtitle: String?
}

public struct PaywallTranslationFeature: Codable, Equatable, Sendable {
    public var text: String?
}

public struct PaywallTranslationProduct: Codable, Equatable, Sendable {
    public var label: String?
    public var sublabel: String?
    public var badge: String?
}

public struct PaywallTranslationCta: Codable, Equatable, Sendable {
    public var text: String?
    public var microtext: String?
}

public struct PaywallTranslationFooter: Codable, Equatable, Sendable {
    public var restoreText: String?
}

public struct PaywallTranslation: Codable, Equatable, Sendable {
    public var header: PaywallTranslationHeader?
    public var features: [PaywallTranslationFeature]?
    public var products: [PaywallTranslationProduct]?
    public var cta: PaywallTranslationCta?
    public var footer: PaywallTranslationFooter?
}

public struct PaywallPage: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var header: PaywallHeader?
    public var features: [PaywallFeature]?
    public var products: [PaywallProduct]?
    public var cta: PaywallCta?
    public var visibility: PaywallVisibility?
    public var themeOverride: PaywallThemeOverride?
    /// Page-scoped timeline ("how it works" on a dedicated onboarding step).
    public var timeline: PaywallTimeline?
}

public struct PaywallDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var layout: PaywallLayout
    public var theme: PaywallTheme
    /// Override applied on top of `theme` when the host is in dark mode.
    public var darkTheme: PaywallThemeOverride?
    public var header: PaywallHeader
    public var features: [PaywallFeature]
    public var products: [PaywallProduct]
    public var cta: PaywallCta
    public var footer: PaywallFooter
    public var visibility: PaywallVisibility?
    public var socialProof: PaywallSocialProof?
    public var urgency: PaywallUrgency?
    public var animations: PaywallAnimations?
    /// Optional free-trial switch rendered above the products (selects trial vs paid product).
    public var trialToggle: PaywallTrialToggle?
    /// Optional tier tabs rendered above the products (filters the visible product set).
    public var tabs: PaywallTabs?
    /// Optional "how it works" timeline rendered between features and products.
    public var timeline: PaywallTimeline?
    /// When set + non-empty, render as a horizontal carousel. Each page is a partial slice.
    public var pages: [PaywallPage]?
    /// Locale-keyed text overrides. Keys are BCP-47 short codes ("it", "fr-CA").
    public var translations: [String: PaywallTranslation]?
}

public struct PaywallExperimentAssignment: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let variant: String
}

/// Response from `GET /v1/paywalls/by-identifier/{identifier}`.
public struct PaywallResponse: Codable, Equatable, Sendable {
    public let identifier: String
    public let versionId: String
    public let versionNumber: Int
    public let publishedAt: String
    public let document: PaywallDocument
    public let experiment: PaywallExperimentAssignment?
}

// MARK: - Placements

/// The backend's decision for a placement: whether to present a paywall and which one.
public struct CampaignDecision: Codable, Equatable, Sendable {
    public let present: Bool
    public let paywallId: String?
    public let paywallIdentifier: String?
    public let campaignId: String?
    public let ruleReason: String

    public init(present: Bool, paywallId: String?, paywallIdentifier: String?, campaignId: String?, ruleReason: String) {
        self.present = present
        self.paywallId = paywallId
        self.paywallIdentifier = paywallIdentifier
        self.campaignId = campaignId
        self.ruleReason = ruleReason
    }
}

// MARK: - Document transforms (mirror the RN helpers byte-for-byte)

public enum PaywallTransforms {

    /// Resolve `{{ path.dot.name }}` placeholders against a flat or nested variable map.
    /// Unknown placeholders are left as the original `{{…}}` text so a missing variable is visible.
    /// Mirrors `interpolate.ts`.
    public static func interpolate(_ value: String, _ variables: [String: String]?) -> String {
        guard let variables, !value.isEmpty, value.contains("{{") else { return value }
        var result = ""
        var rest = Substring(value)
        while let open = rest.range(of: "{{"), let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
            result += rest[rest.startIndex..<open.lowerBound]
            let keyRaw = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let resolved = variables[keyRaw] {
                result += resolved
            } else {
                result += "{{\(rest[open.upperBound..<close.lowerBound])}}"
            }
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    /// Apply a locale text override to the user-visible fields. Falls back from a region code
    /// ("fr-CA") to the language-only code ("fr"). Pure. Mirrors `translate.ts`.
    public static func applyTranslation(_ doc: PaywallDocument, locale: String?) -> PaywallDocument {
        guard let locale, let translations = doc.translations else { return doc }
        let base = String(locale.split(separator: "-").first ?? "")
        guard let t = translations[locale] ?? translations[base] else { return doc }

        var out = doc
        out.header.title = t.header?.title ?? doc.header.title
        out.header.subtitle = t.header?.subtitle ?? doc.header.subtitle
        out.features = doc.features.enumerated().map { i, f in
            var nf = f
            nf.text = t.features?[safe: i]?.text ?? f.text
            return nf
        }
        out.products = doc.products.enumerated().map { i, p in
            var np = p
            np.label = t.products?[safe: i]?.label ?? p.label
            np.sublabel = t.products?[safe: i]?.sublabel ?? p.sublabel
            np.badge = t.products?[safe: i]?.badge ?? p.badge
            return np
        }
        out.cta.text = t.cta?.text ?? doc.cta.text
        out.cta.microtext = t.cta?.microtext ?? doc.cta.microtext
        out.footer.restoreText = t.footer?.restoreText ?? doc.footer.restoreText
        return out
    }

    /// Project a single page into a standalone document the renderer can handle. Page fields take
    /// precedence; anything unset falls through to the parent. Mirrors `pages.ts`.
    public static func pageToDocument(_ doc: PaywallDocument, _ page: PaywallPage) -> PaywallDocument {
        var out = doc
        if let o = page.themeOverride { out.theme = doc.theme.merging(o) }
        out.header = page.header ?? doc.header
        out.features = page.features ?? doc.features
        out.products = page.products ?? doc.products
        out.cta = page.cta ?? doc.cta
        out.visibility = page.visibility ?? doc.visibility
        out.timeline = page.timeline ?? doc.timeline
        out.pages = nil
        return out
    }

    /// True when feature at `featureIndex` is included for `product` in the comparison table.
    /// Mirrors the web renderer: a missing entry = ✓ (included); only an explicit `false` = ×.
    public static func comparisonCellOn(_ product: PaywallProduct, featureIndex: Int) -> Bool {
        product.featureMatches?[String(featureIndex)] != false
    }

    /// Parse an ISO-8601 timestamp (with or without fractional seconds) into a Date. Pure; returns
    /// nil for malformed input so the countdown can simply not render.
    public static func parseISODate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Break a non-negative remaining interval (seconds) into day/hour/minute/second components.
    /// Negative input clamps to zero (the deal is over). Pure — easy to unit-test.
    public static func countdownComponents(remaining seconds: Int) -> (days: Int, hours: Int, minutes: Int, seconds: Int) {
        let total = max(0, seconds)
        return (total / 86400, (total % 86400) / 3600, (total % 3600) / 60, total % 60)
    }

    /// Format a remaining interval (seconds) the same way the web renderer does:
    /// "2d 03h 04m" when ≥ a day, otherwise "HH:MM:SS". Pure.
    public static func formatCountdown(remaining seconds: Int) -> String {
        let c = countdownComponents(remaining: seconds)
        func pad(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        if c.days > 0 {
            return "\(c.days)d \(pad(c.hours))h \(pad(c.minutes))m"
        }
        return "\(pad(c.hours)):\(pad(c.minutes)):\(pad(c.seconds))"
    }

    /// True when the product should be rendered for the given user context. Mirrors `visibility.ts`.
    public static func isProductVisible(_ product: PaywallProduct, _ ctx: PaywallUserContext?) -> Bool {
        guard let v = product.visibility, let ctx else { return true }
        if let want = v.isNewUser, let have = ctx.isNewUser, want != have { return false }
        if let want = v.hasUsedTrial, let have = ctx.hasUsedTrial, want != have { return false }
        if let countries = v.countries, !countries.isEmpty, let c = ctx.country {
            if !countries.contains(where: { $0.uppercased() == c.uppercased() }) { return false }
        }
        if let platforms = v.platforms, !platforms.isEmpty, let p = ctx.platform {
            if !platforms.contains(where: { $0.lowercased() == p.lowercased() }) { return false }
        }
        if let minD = v.daysSinceInstallMin, let d = ctx.daysSinceInstall, d < minD { return false }
        if let maxD = v.daysSinceInstallMax, let d = ctx.daysSinceInstall, d > maxD { return false }
        return true
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
