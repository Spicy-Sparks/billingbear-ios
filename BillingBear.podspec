Pod::Spec.new do |s|
  s.name         = "BillingBear"
  s.version      = "1.1.0"
  s.summary      = "Native Swift/SwiftUI subscription-management SDK for BillingBear (StoreKit 2)."
  s.description  = <<-DESC
    BillingBear's native iOS SDK — the same Swift sources shipped via Swift Package
    Manager (Package.swift), made consumable via CocoaPods so React Native apps (which
    use CocoaPods, not SwiftPM) can bridge the native SwiftUI `BillingBearPaywall`
    renderer the RevenueCat way: the standalone renderer ships a podspec, and the RN
    paywall view module depends on it. The pod vends the public `BillingBearPaywall`
    SwiftUI view, `Purchases`, the paywall models and the customer-center renderer.
  DESC
  s.homepage     = "https://billingbear.io"
  s.license      = { :type => "MIT", :text => "Copyright BillingBear. Released under the MIT License." }
  s.authors      = { "BillingBear" => "support@billingbear.io" }

  # SwiftUI BillingBearPaywall + lottie-ios both require iOS 15 minimum (Package.swift
  # declares iOS 15 / macOS 12 — kept in lockstep here).
  s.platforms    = { :ios => "15.0" }
  s.swift_version = "5.9"

  s.source       = { :git => "https://github.com/Spicy-Sparks/billingbear-ios.git", :tag => "#{s.version}" }

  # The exact same source tree SwiftPM compiles (Sources/BillingBear). Keeping a single
  # source-of-truth means the Pods build and the SPM build never drift.
  s.source_files = "Sources/BillingBear/**/*.swift"

  # Animated (Lottie) paywall backgrounds render plug-and-play: the consumer installs only
  # BillingBear and Lottie comes transitively via the canonical 'lottie-ios' pod (the
  # CocoaPods equivalent of the SwiftPM lottie-ios package dependency in Package.swift).
  s.dependency "lottie-ios", ">= 4.5.0"
end
