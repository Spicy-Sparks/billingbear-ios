import Foundation

// MARK: - Customer Center
//
// Mirrors the shape served by `GET /v1/customer-center/{appUserId}`, ported from the React Native
// SDK's `types.ts`. This is the end-user, in-app subscription-management surface (RevenueCat
// Customer Center parity): the server returns the user's subscriptions, the actions allowed on
// each, support links, and the themeable appearance config. `BillingBearCustomerCenter` renders it;
// the dashboard owns the canonical schema and the SDK consumes it forward-compatibly.

/// What kind of action a customer can take on a subscription.
public enum CustomerCenterActionType: String, Codable, Sendable {
    case manageInStore = "manage_in_store"
    case cancel
    case cancelAtPeriodEnd = "cancel_at_period_end"
    case reactivate
    case changePlan = "change_plan"
    case requestRefund = "request_refund"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CustomerCenterActionType(rawValue: raw) ?? .unknown
    }
}

/// A single action button rendered under a subscription.
public struct CustomerCenterAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(type.rawValue):\(label):\(newProductId ?? "")" }
    public let type: CustomerCenterActionType
    public let label: String
    /// Present for `manage_in_store` (and any URL-driven action).
    public let url: String?
    /// For `change_plan`: a concrete target product to switch to.
    public let newProductId: String?

    private enum CodingKeys: String, CodingKey { case type, label, url, newProductId }
}

/// One of the user's subscriptions as shown in the Customer Center.
public struct CustomerCenterSubscription: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: String
    public let productId: String
    public let displayName: String
    public let status: String
    public let expiresAt: String?
    public let willRenew: Bool
    public let priceText: String?
    public let actions: [CustomerCenterAction]
}

/// A custom navigation link surfaced in the Customer Center.
public struct CustomerCenterDeepLink: Codable, Equatable, Sendable, Identifiable {
    public var id: String { title + url }
    public let title: String
    public let url: String
    public let icon: String?
}

/// Themeable appearance for the Customer Center.
public struct CustomerCenterAppearance: Codable, Equatable, Sendable {
    public var mode: String  // "light" | "dark" | "system"
    public var accentColor: String?
    public var backgroundColor: String?
    public var cardColor: String?
    public var textColor: String?
    public var logoUrl: String?
    public var cornerRadius: Double?

    public init(
        mode: String = "system",
        accentColor: String? = nil,
        backgroundColor: String? = nil,
        cardColor: String? = nil,
        textColor: String? = nil,
        logoUrl: String? = nil,
        cornerRadius: Double? = nil
    ) {
        self.mode = mode
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        self.cardColor = cardColor
        self.textColor = textColor
        self.logoUrl = logoUrl
        self.cornerRadius = cornerRadius
    }
}

public struct CustomerCenterSupport: Codable, Equatable, Sendable {
    public let contactEmail: String?
    public let supportUrl: String?
    public let faqUrl: String?
}

public struct CustomerCenterSection: Codable, Equatable, Sendable, Identifiable {
    public var id: String { title + url }
    public let title: String
    public let url: String
    public let icon: String?
}

/// Cancellation survey config.
public struct CustomerCenterSurvey: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let reasons: [String]
    public let commentEnabled: Bool
    public let prompt: String?
}

/// How a retention offer's discount is expressed.
public enum CustomerCenterOfferDiscountType: String, Codable, Sendable {
    case percent
    case amount
    case freeMonths = "free_months"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CustomerCenterOfferDiscountType(rawValue: raw) ?? .unknown
    }
}

/// A concrete win-back offer presented on cancel intent for a managed (Stripe/Paddle) subscription.
public struct CustomerCenterOffer: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let discountType: CustomerCenterOfferDiscountType
    public let value: Double
    public let durationMonths: Int?
    public let stripeCouponId: String?
}

/// Retention offer shown before a cancel completes ("are you sure?" + offer).
public struct CustomerCenterRetention: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let message: String?
    public let offerText: String?
    public let offers: [CustomerCenterOffer]?
}

public struct CustomerCenterConfig: Codable, Equatable, Sendable {
    public var appearance: CustomerCenterAppearance
    public let support: CustomerCenterSupport?
    public let sections: [CustomerCenterSection]?
    public let survey: CustomerCenterSurvey?
    public let retention: CustomerCenterRetention?
    /// Device-locale string translations: localizations[locale][key] -> translated string.
    public let localizations: [String: [String: String]]?
    /// Server-side feature flags toggling which actions the app may surface.
    public let enabledActions: [String: Bool]?
}

/// Response of `POST .../subscriptions/{id}/accept-offer`.
public struct CustomerCenterAcceptOfferResult: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let message: String?
}

/// Full response of `GET /v1/customer-center/{appUserId}`.
public struct CustomerCenterData: Codable, Equatable, Sendable {
    public let appUserId: String
    public let subscriptions: [CustomerCenterSubscription]
    public let deepLinks: [CustomerCenterDeepLink]?
    public let config: CustomerCenterConfig
}

/// Cancellation mode: revoke now, or let it lapse at the end of the period.
public enum CustomerCenterCancelMode: String, Codable, Sendable {
    case immediate
    case periodEnd = "period_end"
}
