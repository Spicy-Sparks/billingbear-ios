import XCTest
import SwiftUI
@testable import BillingBear

// MARK: - Paywall v2 tree model + helper tests
//
// Covers the Codable mirror (PaywallTreeModels.swift) and the pure helpers (PaywallTreeTransforms):
//   • decoding a representative tree (stack + several element types + style variants + actions)
//   • tolerant decoding of an unknown node type (→ .unknown, no throw)
//   • size / edge / corner decoding of the number | string | object forms
//   • the isNodeVisible port (shared dims + v2 isSubscribed / locales)
//   • the v2 interpolation helper (var. / product. / theme. namespaces)
//   • action decoding (all variants + unknown), version detection, translation application
//
// Snapshot rendering is impractical headlessly, so these focus on the Codable models + pure helpers,
// which is where every renderer-driving decision is made.

final class PaywallTreeTests: XCTestCase {

    private func decodeTree(_ json: String) throws -> PaywallTree {
        try JSONDecoder().decode(PaywallTree.self, from: Data(json.utf8))
    }

    private func decodeNode(_ json: String) throws -> PaywallNode {
        try JSONDecoder().decode(PaywallNode.self, from: Data(json.utf8))
    }

    // MARK: - Representative tree decode

    func testDecodesRepresentativeTree() throws {
        let json = """
        {
          "version": 2,
          "theme": { "primaryColor": "#5b5bd6", "background": "#0a0a0a", "textColor": "#ffffff", "fontFamily": "Outfit" },
          "variables": { "appName": "Lyra", "accent": "#ff0066" },
          "products": [
            { "identifier": "yearly", "label": "Yearly", "highlight": true, "trialDays": 7 },
            { "identifier": "monthly", "label": "Monthly" }
          ],
          "root": {
            "id": "root",
            "type": "stack",
            "direction": "vertical",
            "crossAlign": "stretch",
            "mainAlign": "start",
            "spacing": 16,
            "scroll": { "mode": "normal", "indicator": true },
            "style": { "useThemeBackground": true, "padding": 20 },
            "children": [
              { "id": "title", "type": "text", "text": "Welcome to {{var.appName}}", "maxLines": 2,
                "style": { "fontSize": 28, "fontWeight": "700", "color": "{{theme.primaryColor}}", "textAlign": "center", "textTransform": "uppercase" } },
              { "id": "hero", "type": "image", "url": "https://x/hero.png", "posterUrl": "https://x/p.png", "contentMode": "cover",
                "style": { "height": 240, "width": "fill", "cornerRadius": 16 } },
              { "id": "stars", "type": "rating", "value": 4.5, "max": 5, "label": "4.5 (2k)" },
              { "id": "selector", "type": "productSelector", "layout": "list", "defaultProductId": "yearly",
                "productIds": ["yearly", "monthly"] },
              { "id": "timer", "type": "timer", "durationSec": 600, "format": "mm:ss", "hideOnExpiry": true },
              { "id": "cta", "type": "button", "text": "Continue", "microtext": "Cancel anytime",
                "onTap": { "type": "purchase" }, "haptic": "medium",
                "style": { "background": "{{var.accent}}", "cornerRadius": 999, "padding": { "top": 16, "bottom": 16 }, "width": "fill" } },
              { "id": "restore", "type": "text", "text": "Restore", "onTap": { "type": "restore" } },
              { "id": "divider", "type": "divider" },
              { "id": "spacer", "type": "spacer", "style": { "grow": 1 } },
              { "id": "testi", "type": "testimonial", "quote": "Best app", "author": "Marco", "rating": 5 }
            ]
          }
        }
        """
        let tree = try decodeTree(json)

        XCTAssertEqual(tree.version, 2)
        XCTAssertEqual(tree.theme.fontFamily, "Outfit")
        XCTAssertEqual(tree.variables?["appName"], "Lyra")
        XCTAssertEqual(tree.products.count, 2)
        XCTAssertEqual(tree.root.kind, .stack)
        XCTAssertEqual(tree.root.direction, .vertical)
        XCTAssertEqual(tree.root.crossAlign, .stretch)
        XCTAssertEqual(tree.root.spacing, 16)
        XCTAssertEqual(tree.root.scroll?.mode, .normal)
        XCTAssertEqual(tree.root.scroll?.indicator, true)
        XCTAssertEqual(tree.root.style?.useThemeBackground, true)
        XCTAssertEqual(tree.root.children.count, 10)

        let title = tree.root.children[0]
        XCTAssertEqual(title.kind, .text)
        XCTAssertEqual(title.text, "Welcome to {{var.appName}}")
        XCTAssertEqual(title.maxLines, 2)
        XCTAssertEqual(title.style?.fontSize, 28)
        XCTAssertEqual(title.style?.fontWeight?.value, "700")
        XCTAssertEqual(title.style?.textAlign, .center)
        XCTAssertEqual(title.style?.textTransform, .uppercase)

        let hero = tree.root.children[1]
        XCTAssertEqual(hero.kind, .image)
        XCTAssertEqual(hero.contentMode, .cover)
        XCTAssertEqual(hero.posterUrl, "https://x/p.png")
        XCTAssertEqual(hero.style?.height, .points(240))
        XCTAssertEqual(hero.style?.width, .fill)

        let rating = tree.root.children[2]
        XCTAssertEqual(rating.kind, .rating)
        XCTAssertEqual(rating.value, 4.5)
        XCTAssertEqual(rating.max, 5)

        let selector = tree.root.children[3]
        XCTAssertEqual(selector.kind, .productSelector)
        XCTAssertEqual(selector.layout, .list)
        XCTAssertEqual(selector.defaultProductId, "yearly")
        XCTAssertEqual(selector.productIds, ["yearly", "monthly"])

        let timer = tree.root.children[4]
        XCTAssertEqual(timer.kind, .timer)
        XCTAssertEqual(timer.durationSec, 600)
        XCTAssertEqual(timer.format, "mm:ss")
        XCTAssertEqual(timer.hideOnExpiry, true)

        let cta = tree.root.children[5]
        XCTAssertEqual(cta.kind, .button)
        XCTAssertEqual(cta.microtext, "Cancel anytime")
        XCTAssertEqual(cta.haptic, .medium)
        if case .purchase(let pid)? = cta.onTap { XCTAssertNil(pid) } else { XCTFail("expected purchase action") }
        XCTAssertEqual(cta.style?.width, .fill)
        XCTAssertEqual(cta.style?.cornerRadius?.topLeft, 999)
        XCTAssertEqual(cta.style?.padding?.top, 16)
        XCTAssertEqual(cta.style?.padding?.bottom, 16)
        XCTAssertEqual(cta.style?.padding?.left, 0)

        let restore = tree.root.children[6]
        if case .restore? = restore.onTap {} else { XCTFail("expected restore action") }

        XCTAssertEqual(tree.root.children[7].kind, .divider)
        XCTAssertEqual(tree.root.children[8].kind, .spacer)
        XCTAssertEqual(tree.root.children[8].style?.grow, 1)

        let testi = tree.root.children[9]
        XCTAssertEqual(testi.kind, .testimonial)
        XCTAssertEqual(testi.quote, "Best app")
        XCTAssertEqual(testi.author, "Marco")
        XCTAssertEqual(testi.rating, 5)
    }

    // MARK: - Tolerant decoding

    func testUnknownNodeTypeDecodesToUnknownAndNeverThrows() throws {
        let json = """
        { "id": "weird", "type": "futuristicWidget", "someFutureField": 42 }
        """
        let node = try decodeNode(json)
        XCTAssertEqual(node.kind, .unknown)
        XCTAssertEqual(node.id, "weird")
    }

    func testStackWithMalformedChildDropsItButKeepsValidSiblings() throws {
        // A child that is a JSON primitive (not an object) must be dropped, not fail the array.
        let json = """
        {
          "id": "s", "type": "stack", "direction": "vertical",
          "children": [
            { "id": "a", "type": "text", "text": "A" },
            "not-an-object",
            { "id": "b", "type": "text", "text": "B" }
          ]
        }
        """
        let node = try decodeNode(json)
        // The string child decodes to an .unknown node (FailableNode keeps a node when possible);
        // the two valid text nodes survive in order.
        let texts = node.children.filter { $0.kind == .text }
        XCTAssertEqual(texts.map { $0.text }, ["A", "B"])
    }

    func testMissingIdGetsAutoAssigned() throws {
        let node = try decodeNode(#"{ "type": "text", "text": "no id" }"#)
        XCTAssertFalse(node.id.isEmpty)
        XCTAssertTrue(node.id.hasPrefix("n"))
    }

    func testTopLevelNeverThrowsOnGarbageRoot() throws {
        // root is a primitive → degrades to the empty stack root.
        let json = ##"{ "version": 2, "theme": { "primaryColor": "#fff", "background": "#000", "textColor": "#fff" }, "root": 5, "products": [] }"##
        let tree = try decodeTree(json)
        XCTAssertEqual(tree.root.kind, .stack)
        XCTAssertTrue(tree.root.children.isEmpty)
    }

    func testUnknownEnumValuesFallBackInsteadOfThrowing() throws {
        let json = """
        { "id": "s", "type": "stack", "direction": "diagonal", "mainAlign": "wat", "crossAlign": "nope",
          "scroll": { "mode": "teleport" },
          "children": [ { "id": "t", "type": "text", "text": "x", "style": { "textAlign": "justify", "position": "orbital" } } ] }
        """
        let node = try decodeNode(json)
        XCTAssertEqual(node.direction, .vertical)        // unknown direction → vertical
        XCTAssertEqual(node.mainAlign, .start)           // unknown mainAlign → start
        XCTAssertEqual(node.crossAlign, .start)          // unknown crossAlign → start
        XCTAssertEqual(node.scroll?.mode, PaywallScroll.Mode.none) // unknown scroll mode → none
        XCTAssertEqual(node.children.first?.style?.textAlign, .left)   // unknown textAlign → left
        XCTAssertEqual(node.children.first?.style?.position, .normal)  // unknown position → normal
    }

    // MARK: - Size decoding (number | string | object)

    func testSizeDecodesAllForms() throws {
        struct Box: Decodable { let s: PaywallSize }
        func size(_ raw: String) throws -> PaywallSize {
            try JSONDecoder().decode(Box.self, from: Data("{\"s\": \(raw)}".utf8)).s
        }
        XCTAssertEqual(try size("120"), .points(120))
        XCTAssertEqual(try size("120.5"), .points(120.5))
        XCTAssertEqual(try size("\"fill\""), .fill)
        XCTAssertEqual(try size("\"hug\""), .hug)
        XCTAssertEqual(try size("{ \"percent\": 50 }"), .percent(50))
        XCTAssertEqual(try size("\"75%\""), .percent(75))   // CSS-ish string tolerated
        XCTAssertEqual(try size("\"bananas\""), .hug)       // unknown string → hug
        XCTAssertEqual(try size("{ \"weird\": 1 }"), .hug)  // unknown object → hug
    }

    // MARK: - Edges decoding (number | object)

    func testEdgesDecodesNumberAndObject() throws {
        struct Box: Decodable { let e: PaywallEdges }
        func edges(_ raw: String) throws -> PaywallEdges {
            try JSONDecoder().decode(Box.self, from: Data("{\"e\": \(raw)}".utf8)).e
        }
        let uniform = try edges("12")
        XCTAssertEqual(uniform, PaywallEdges.all(12))

        let perSide = try edges("{ \"top\": 4, \"left\": 8 }")
        XCTAssertEqual(perSide.top, 4)
        XCTAssertEqual(perSide.left, 8)
        XCTAssertEqual(perSide.right, 0)   // omitted → 0
        XCTAssertEqual(perSide.bottom, 0)
    }

    // MARK: - Corner decoding (number | object)

    func testCornerRadiusDecodesNumberAndObject() throws {
        struct Box: Decodable { let c: PaywallCornerRadius }
        func corners(_ raw: String) throws -> PaywallCornerRadius {
            try JSONDecoder().decode(Box.self, from: Data("{\"c\": \(raw)}".utf8)).c
        }
        let uniform = try corners("20")
        XCTAssertEqual(uniform, PaywallCornerRadius.all(20))
        XCTAssertTrue(uniform.isUniform)

        let perCorner = try corners("{ \"topLeft\": 8, \"topRight\": 8, \"bottomRight\": 0, \"bottomLeft\": 0 }")
        XCTAssertEqual(perCorner.topLeft, 8)
        XCTAssertEqual(perCorner.bottomRight, 0)
        XCTAssertFalse(perCorner.isUniform)
    }

    // MARK: - FlexibleString fontWeight (number | string)

    func testFontWeightDecodesNumberOrString() throws {
        let n = try decodeNode(#"{ "id": "t", "type": "text", "text": "x", "style": { "fontWeight": 600 } }"#)
        XCTAssertEqual(n.style?.fontWeight?.value, "600")
        let s = try decodeNode(#"{ "id": "t", "type": "text", "text": "x", "style": { "fontWeight": "bold" } }"#)
        XCTAssertEqual(s.style?.fontWeight?.value, "bold")
    }

    // MARK: - Action decoding

    func testAllActionVariantsDecode() throws {
        func action(_ raw: String) throws -> PaywallAction {
            try JSONDecoder().decode(PaywallAction.self, from: Data(raw.utf8))
        }
        if case .purchase(let pid) = try action(#"{ "type": "purchase", "productId": "yearly" }"#) {
            XCTAssertEqual(pid, "yearly")
        } else { XCTFail() }
        if case .restore = try action(#"{ "type": "restore" }"#) {} else { XCTFail() }
        if case .dismiss = try action(#"{ "type": "dismiss" }"#) {} else { XCTFail() }
        if case .url(let u) = try action(#"{ "type": "url", "url": "https://x" }"#) {
            XCTAssertEqual(u, "https://x")
        } else { XCTFail() }
        if case .selectProduct(let pid) = try action(#"{ "type": "selectProduct", "productId": "m" }"#) {
            XCTAssertEqual(pid, "m")
        } else { XCTFail() }
        if case .nextPage = try action(#"{ "type": "nextPage" }"#) {} else { XCTFail() }
        if case .prevPage = try action(#"{ "type": "prevPage" }"#) {} else { XCTFail() }
        if case .goToPage(let id) = try action(#"{ "type": "goToPage", "pageId": "p2" }"#) {
            XCTAssertEqual(id, "p2")
        } else { XCTFail() }
        if case .event(let name) = try action(#"{ "type": "event", "name": "cta_tap" }"#) {
            XCTAssertEqual(name, "cta_tap")
        } else { XCTFail() }
        if case .unknown = try action(#"{ "type": "warpDrive" }"#) {} else { XCTFail("unknown action should decode to .unknown") }
    }

    // MARK: - isNodeVisible port

    private func ruleNode(_ rule: PaywallVisibilityRule) -> PaywallNode {
        PaywallNode(id: "n", kind: .text, visibleIf: rule, text: "x")
    }

    func testNoRuleAlwaysVisible() {
        let node = PaywallNode(id: "n", kind: .text, text: "x")
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: nil))
    }

    func testVisibilityFiltersByPlatform() {
        let node = ruleNode(PaywallVisibilityRule(platforms: ["android"]))
        let ctx = PaywallUserContext(platform: "ios")
        XCTAssertFalse(PaywallTreeTransforms.isNodeVisible(node, context: ctx))
        let ctxA = PaywallUserContext(platform: "android")
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: ctxA))
    }

    func testVisibilityFiltersByNewUserAndTrial() {
        let node = ruleNode(PaywallVisibilityRule(isNewUser: true, hasUsedTrial: false))
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: PaywallUserContext(isNewUser: true, hasUsedTrial: false)))
        XCTAssertFalse(PaywallTreeTransforms.isNodeVisible(node, context: PaywallUserContext(isNewUser: false, hasUsedTrial: false)))
        // Missing context field skips its rule (over-show), so an unset isNewUser still passes.
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: PaywallUserContext(hasUsedTrial: false)))
    }

    func testVisibilityIsSubscribedExtra() {
        let node = ruleNode(PaywallVisibilityRule(isSubscribed: false))
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: nil, isSubscribed: false))
        XCTAssertFalse(PaywallTreeTransforms.isNodeVisible(node, context: nil, isSubscribed: true))
        // Unknown subscription state → skip the rule (over-show).
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: nil, isSubscribed: nil))
    }

    func testVisibilityLocalesExtra() {
        let node = ruleNode(PaywallVisibilityRule(locales: ["it", "fr"]))
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: nil, locale: "IT"))
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: nil, locale: "fr"))
        XCTAssertFalse(PaywallTreeTransforms.isNodeVisible(node, context: nil, locale: "de"))
        // No locale provided → skip the rule.
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: nil, locale: nil))
    }

    func testVisibilityCountriesAndDaysSinceInstall() {
        let node = ruleNode(PaywallVisibilityRule(countries: ["US", "CA"], daysSinceInstallMin: 3, daysSinceInstallMax: 30))
        XCTAssertTrue(PaywallTreeTransforms.isNodeVisible(node, context: PaywallUserContext(country: "us", daysSinceInstall: 10)))
        XCTAssertFalse(PaywallTreeTransforms.isNodeVisible(node, context: PaywallUserContext(country: "DE", daysSinceInstall: 10)))
        XCTAssertFalse(PaywallTreeTransforms.isNodeVisible(node, context: PaywallUserContext(country: "US", daysSinceInstall: 1)))
        XCTAssertFalse(PaywallTreeTransforms.isNodeVisible(node, context: PaywallUserContext(country: "US", daysSinceInstall: 60)))
    }

    // MARK: - Interpolation helper (var / product / theme)

    func testInterpolateNamespaces() {
        let theme = PaywallTree.fallbackTheme
        let out = PaywallTreeTransforms.interpolate(
            "{{var.appName}} • {{product.price}} • {{theme.primaryColor}}",
            variables: ["appName": "Lyra"],
            product: ["price": "$9.99"],
            theme: theme
        )
        XCTAssertEqual(out, "Lyra • $9.99 • \(theme.primaryColor)")
    }

    func testInterpolateStripsUnknownTokens() {
        // Unresolved tokens must render EMPTY — a paywall must never leak raw {{...}} to users
        // (mirrors the web interpolate() contract).
        let out = PaywallTreeTransforms.interpolate(
            "Hello {{var.missing}} {{bogus.x}} {{noNamespace}}",
            variables: ["other": "y"],
            product: nil,
            theme: nil
        )
        XCTAssertEqual(out, "Hello   ")
    }

    func testInterpolateNoTokensIsIdentity() {
        XCTAssertEqual(
            PaywallTreeTransforms.interpolate("plain text", variables: nil, product: nil, theme: nil),
            "plain text"
        )
    }

    func testInterpolateThemeTokenAliases() {
        let theme = PaywallTree.fallbackTheme
        let out = PaywallTreeTransforms.interpolate(
            "{{theme.primary}}/{{theme.text}}/{{theme.background}}",
            variables: nil, product: nil, theme: theme
        )
        XCTAssertEqual(out, "\(theme.primaryColor)/\(theme.textColor)/\(theme.background)")
    }

    // MARK: - textTransform application

    func testTextTransformApply() {
        XCTAssertEqual(PaywallTextTransform.uppercase.apply("hello"), "HELLO")
        XCTAssertEqual(PaywallTextTransform.lowercase.apply("HELLO"), "hello")
        XCTAssertEqual(PaywallTextTransform.capitalize.apply("hello world"), "Hello World")
        XCTAssertEqual(PaywallTextTransform.none.apply("Hello"), "Hello")
    }

    // MARK: - Translation application

    func testApplyTranslationOverridesTextAndUrlByNodeId() throws {
        let json = """
        {
          "version": 2,
          "theme": { "primaryColor": "#fff", "background": "#000", "textColor": "#fff" },
          "products": [],
          "root": {
            "id": "root", "type": "stack", "direction": "vertical",
            "children": [
              { "id": "title", "type": "text", "text": "Welcome" },
              { "id": "logo", "type": "image", "url": "https://x/en.png" }
            ]
          },
          "translations": {
            "it": {
              "title": { "text": "Benvenuto" },
              "logo": { "url": "https://x/it.png" }
            }
          }
        }
        """
        let tree = try decodeTree(json)
        let translated = PaywallTreeTransforms.applyTranslation(tree, locale: "it")
        XCTAssertEqual(translated.root.children[0].text, "Benvenuto")
        XCTAssertEqual(translated.root.children[1].url, "https://x/it.png")

        // Region fallback: "it-CH" → "it".
        let regionFallback = PaywallTreeTransforms.applyTranslation(tree, locale: "it-CH")
        XCTAssertEqual(regionFallback.root.children[0].text, "Benvenuto")

        // Unknown locale → untouched.
        let untouched = PaywallTreeTransforms.applyTranslation(tree, locale: "de")
        XCTAssertEqual(untouched.root.children[0].text, "Welcome")
    }

    // MARK: - findNode

    func testFindNodeAcrossTreeAndPages() throws {
        let json = """
        {
          "version": 2,
          "theme": { "primaryColor": "#fff", "background": "#000", "textColor": "#fff" },
          "products": [],
          "root": { "id": "root", "type": "stack", "direction": "vertical",
            "children": [ { "id": "deep", "type": "text", "text": "x" } ] },
          "pages": [
            { "id": "p1", "root": { "id": "pr1", "type": "stack", "direction": "vertical",
              "children": [ { "id": "onPage", "type": "button", "text": "Go" } ] } }
          ]
        }
        """
        let tree = try decodeTree(json)
        XCTAssertEqual(PaywallTreeTransforms.findNode(tree, id: "deep")?.kind, .text)
        XCTAssertEqual(PaywallTreeTransforms.findNode(tree, id: "onPage")?.kind, .button)
        XCTAssertNil(PaywallTreeTransforms.findNode(tree, id: "nope"))
    }

    // MARK: - Multi-page decode

    func testDecodesPages() throws {
        let json = """
        {
          "version": 2,
          "theme": { "primaryColor": "#fff", "background": "#000", "textColor": "#fff" },
          "products": [],
          "root": { "id": "root", "type": "stack", "direction": "vertical", "children": [] },
          "pages": [
            { "id": "intro", "name": "Intro", "root": { "id": "ri", "type": "stack", "direction": "vertical", "children": [] },
              "themeOverride": { "primaryColor": "#ff0000" } },
            { "id": "pricing", "root": { "id": "rp", "type": "stack", "direction": "vertical", "children": [] } }
          ]
        }
        """
        let tree = try decodeTree(json)
        XCTAssertEqual(tree.pages?.count, 2)
        XCTAssertEqual(tree.pages?[0].id, "intro")
        XCTAssertEqual(tree.pages?[0].name, "Intro")
        XCTAssertEqual(tree.pages?[0].themeOverride?.primaryColor, "#ff0000")
        XCTAssertEqual(tree.pages?[1].id, "pricing")
    }

    // MARK: - itemTemplate (recursive node)

    func testProductSelectorItemTemplateDecodes() throws {
        let json = """
        {
          "id": "sel", "type": "productSelector", "layout": "grid",
          "itemTemplate": {
            "id": "tpl", "type": "stack", "direction": "vertical",
            "children": [ { "id": "lbl", "type": "text", "text": "{{product.label}}" } ]
          }
        }
        """
        let node = try decodeNode(json)
        XCTAssertEqual(node.layout, .grid)
        let tpl = node.itemTemplate?.node
        XCTAssertEqual(tpl?.kind, .stack)
        XCTAssertEqual(tpl?.children.first?.text, "{{product.label}}")
    }

    // MARK: - Border / shadow / background style decode

    func testBorderShadowBackgroundDecode() throws {
        let json = """
        {
          "id": "card", "type": "stack", "direction": "vertical", "children": [],
          "style": {
            "background": "#101010",
            "border": { "width": 2, "color": "#5b5bd6", "style": "dashed" },
            "shadow": { "color": "#000000", "radius": 12, "x": 0, "y": 4, "opacity": 0.4 },
            "backgroundGradient": { "from": "#000", "to": "#333", "angle": 180 }
          }
        }
        """
        let node = try decodeNode(json)
        XCTAssertEqual(node.style?.background, "#101010")
        XCTAssertEqual(node.style?.border?.width, 2)
        XCTAssertEqual(node.style?.border?.style, .dashed)
        XCTAssertEqual(node.style?.shadow?.radius, 12)
        XCTAssertEqual(node.style?.shadow?.opacity, 0.4)
        XCTAssertEqual(node.style?.backgroundGradient?.angle, 180)
    }

    // MARK: - Version detection

    func testVersionDetection() {
        func detect(_ json: String) -> PaywallDocumentVersion {
            PaywallDocumentVersion.detect(from: Data(json.utf8))
        }
        XCTAssertEqual(detect(#"{ "version": 2, "root": {} }"#), .v2)
        XCTAssertEqual(detect(#"{ "version": 1, "layout": "minimal" }"#), .v1)
        // Response envelope around a v2 document.
        XCTAssertEqual(detect(#"{ "identifier": "main", "document": { "version": 2 } }"#), .v2)
        XCTAssertEqual(detect(#"{ "identifier": "main", "document": { "version": 1 } }"#), .v1)
        // No version → treated as v1 (the established format).
        XCTAssertEqual(detect(#"{ "layout": "hero-image" }"#), .v1)
        // Garbage → v1 (never crashes).
        XCTAssertEqual(detect("not json at all"), .v1)
    }

    // MARK: - Font weight resolution helper

    func testFontWeightResolution() {
        XCTAssertEqual(PaywallFontResolver.weight("700"), .bold)
        XCTAssertEqual(PaywallFontResolver.weight("400"), .regular)
        XCTAssertEqual(PaywallFontResolver.weight("900"), .black)
        XCTAssertEqual(PaywallFontResolver.weight("semibold"), .semibold)
        XCTAssertEqual(PaywallFontResolver.weight("bold"), .bold)
        XCTAssertNil(PaywallFontResolver.weight(nil))
        XCTAssertNil(PaywallFontResolver.weight("nonsense"))
    }

    // MARK: - Timer formatter (DD HH mm ss tokens)

    func testTimerFormatterTokens() {
        let total = 2 * 86400 + 3 * 3600 + 4 * 60 + 5
        XCTAssertEqual(PaywallTimerFormatter.format(remaining: total, pattern: "DD HH mm ss"), "02 03 04 05")
        XCTAssertEqual(PaywallTimerFormatter.format(remaining: 3 * 3600 + 4 * 60 + 5, pattern: "HH:mm:ss"), "03:04:05")
        XCTAssertEqual(PaywallTimerFormatter.format(remaining: 65, pattern: "mm:ss"), "01:05")
        // Default pattern when nil.
        XCTAssertEqual(PaywallTimerFormatter.format(remaining: 0, pattern: nil), "00:00:00")
        // Negative clamps to zero.
        XCTAssertEqual(PaywallTimerFormatter.format(remaining: -10, pattern: "ss"), "00")
        // Literal separators survive.
        XCTAssertEqual(PaywallTimerFormatter.format(remaining: 90, pattern: "mm min ss sec"), "01 min 30 sec")
    }

    // MARK: - Round-trip encode/decode keeps the discriminant

    func testNodeRoundTripsThroughEncoding() throws {
        let original = try decodeNode(#"{ "id": "cta", "type": "button", "text": "Buy", "haptic": "success", "onTap": { "type": "dismiss" } }"#)
        let data = try JSONEncoder().encode(original)
        let again = try JSONDecoder().decode(PaywallNode.self, from: data)
        XCTAssertEqual(again.kind, .button)
        XCTAssertEqual(again.text, "Buy")
        XCTAssertEqual(again.haptic, .success)
        if case .dismiss? = again.onTap {} else { XCTFail("dismiss action lost in round-trip") }
    }

    // MARK: - Icon classifier

    func testIconClassifierEmojiVsSymbol() {
        XCTAssertTrue(PaywallIconClassifier.isEmoji("🚀"))
        XCTAssertTrue(PaywallIconClassifier.isEmoji("✨"))
        XCTAssertFalse(PaywallIconClassifier.isEmoji("star.fill"))
        XCTAssertFalse(PaywallIconClassifier.isEmoji("checkmark"))
        // Known alias maps through the v1 table.
        XCTAssertEqual(PaywallIconClassifier.symbolName("star"), "star.fill")
        // Unknown name passes through verbatim (may be a raw SF Symbol).
        XCTAssertEqual(PaywallIconClassifier.symbolName("bolt.horizontal.fill"), "bolt.horizontal.fill")
        // "check" alias still resolves to checkmark.
        XCTAssertEqual(PaywallIconClassifier.symbolName("check"), "checkmark")
    }

    // MARK: - Icon safe fallback (NEVER leak the raw name as a glyph)

    func testIconUnresolvableNameFallsBackToASafeSymbolNotTheRawName() {
        // A garbage name that is neither a known alias nor a real SF Symbol must resolve to the
        // neutral fallback glyph — never the raw token (which would draw a blank Image on iOS).
        let resolved = PaywallIconClassifier.symbolName("totally_not_a_symbol_zzz")
        #if canImport(UIKit)
        XCTAssertEqual(resolved, PaywallIconClassifier.fallbackSymbol)
        XCTAssertNotEqual(resolved, "totally_not_a_symbol_zzz")
        // The fallback itself is guaranteed to be a real, paintable SF Symbol.
        XCTAssertTrue(PaywallIconClassifier.isValidSymbol(PaywallIconClassifier.fallbackSymbol))
        #else
        // Without UIKit we can't introspect the catalog, so the raw name passes through optimistically.
        XCTAssertEqual(resolved, "totally_not_a_symbol_zzz")
        #endif
    }

    func testIconValidRawSymbolPassesThrough() {
        // A real SF Symbol the alias table doesn't list must pass through verbatim.
        XCTAssertEqual(PaywallIconClassifier.symbolName("bolt.horizontal.fill"), "bolt.horizontal.fill")
        #if canImport(UIKit)
        XCTAssertTrue(PaywallIconClassifier.isValidSymbol("star.fill"))
        XCTAssertFalse(PaywallIconClassifier.isValidSymbol("definitely.not.a.symbol.9000"))
        #endif
    }

    func testIconUnderscoreNameNormalisesToDottedSymbol() {
        #if canImport(UIKit)
        // Material-style "lock_open" → SF "lock.open" (a real symbol) rather than the fallback.
        let resolved = PaywallIconClassifier.symbolName("lock_open")
        XCTAssertTrue(PaywallIconClassifier.isValidSymbol(resolved))
        XCTAssertNotEqual(resolved, PaywallIconClassifier.fallbackSymbol)
        #endif
    }

    // MARK: - Animation timing (schema ms → SwiftUI seconds)

    func testAnimationTimingConvertsMillisecondsToSeconds() {
        let a = PaywallAnimation(type: "fade-up", delay: 250, duration: 600)
        XCTAssertEqual(a.durationSeconds, 0.6, accuracy: 1e-9)
        XCTAssertEqual(a.delaySeconds, 0.25, accuracy: 1e-9)
    }

    func testAnimationTimingDefaultsMatchWebRenderer() {
        // Web defaults: duration 400 ms, delay 0.
        let a = PaywallAnimation(type: "scale", delay: nil, duration: nil)
        XCTAssertEqual(a.durationSeconds, 0.4, accuracy: 1e-9)
        XCTAssertEqual(a.delaySeconds, 0.0, accuracy: 1e-9)
    }

    // MARK: - Star row (half-star aware, shared by rating + testimonial)

    func testStarRowSymbols() {
        // value 3.5 over 5 stars: 3 full, 1 half, 1 empty.
        XCTAssertEqual(PaywallStarRow.symbol(index: 0, value: 3.5), "star.fill")
        XCTAssertEqual(PaywallStarRow.symbol(index: 1, value: 3.5), "star.fill")
        XCTAssertEqual(PaywallStarRow.symbol(index: 2, value: 3.5), "star.fill")
        XCTAssertEqual(PaywallStarRow.symbol(index: 3, value: 3.5), "star.leadinghalf.filled")
        XCTAssertEqual(PaywallStarRow.symbol(index: 4, value: 3.5), "star")
        // Exact integer: no half.
        XCTAssertEqual(PaywallStarRow.symbol(index: 4, value: 5), "star.fill")
        XCTAssertEqual(PaywallStarRow.symbol(index: 0, value: 0), "star")
        // Just-below-half rounds down to empty; at-half shows half.
        XCTAssertEqual(PaywallStarRow.symbol(index: 0, value: 0.49), "star")
        XCTAssertEqual(PaywallStarRow.symbol(index: 0, value: 0.5), "star.leadinghalf.filled")
    }

    // MARK: - Gradient angle math (CSS angle → SwiftUI unit points, y-down)

    func testGradientAngleUnitPoints() {
        func approx(_ a: UnitPoint, _ b: UnitPoint, _ msg: String) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6, msg + " x")
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6, msg + " y")
        }
        // 0° = to top: start bottom-center, end top-center.
        let top = PaywallGradientMath.unitPoints(angleDegrees: 0)
        approx(top.start, UnitPoint(x: 0.5, y: 1), "0deg start")
        approx(top.end, UnitPoint(x: 0.5, y: 0), "0deg end")
        // 90° = to right: start left-center, end right-center.
        let right = PaywallGradientMath.unitPoints(angleDegrees: 90)
        approx(right.start, UnitPoint(x: 0, y: 0.5), "90deg start")
        approx(right.end, UnitPoint(x: 1, y: 0.5), "90deg end")
        // 180° = to bottom: start top-center, end bottom-center.
        let bottom = PaywallGradientMath.unitPoints(angleDegrees: 180)
        approx(bottom.start, UnitPoint(x: 0.5, y: 0), "180deg start")
        approx(bottom.end, UnitPoint(x: 0.5, y: 1), "180deg end")
        // 270° = to left.
        let left = PaywallGradientMath.unitPoints(angleDegrees: 270)
        approx(left.start, UnitPoint(x: 1, y: 0.5), "270deg start")
        approx(left.end, UnitPoint(x: 0, y: 0.5), "270deg end")
    }

    // MARK: - Position math (CSS absolute/relative offset + anchor)

    func testPositionOffsetNearInsetWins() {
        // left/top win when both near + far insets are present.
        let o = PaywallPositionMath.offset(top: 10, right: 5, bottom: 8, left: 12)
        XCTAssertEqual(o.width, 12)
        XCTAssertEqual(o.height, 10)
    }

    func testPositionOffsetFarInsetInverts() {
        // Only far insets set → negative offset (anchored to the far edge).
        let o = PaywallPositionMath.offset(top: nil, right: 16, bottom: 24, left: nil)
        XCTAssertEqual(o.width, -16)
        XCTAssertEqual(o.height, -24)
    }

    func testPositionAnchorAlignment() {
        XCTAssertEqual(PaywallPositionMath.horizontal(left: nil, right: 8), .trailing)
        XCTAssertEqual(PaywallPositionMath.horizontal(left: 8, right: nil), .leading)
        XCTAssertEqual(PaywallPositionMath.horizontal(left: 4, right: 8), .leading) // near wins
        XCTAssertEqual(PaywallPositionMath.vertical(top: nil, bottom: 8), .bottom)
        XCTAssertEqual(PaywallPositionMath.vertical(top: 8, bottom: nil), .top)
        XCTAssertEqual(PaywallPositionMath.vertical(top: 0, bottom: 8), .top)
    }

    func testStyleIsOutOfFlowAndAnchor() {
        let abs = PaywallStyle(position: .absolute, top: 4, right: 8)
        XCTAssertTrue(abs.isOutOfFlow)
        XCTAssertEqual(abs.outOfFlowAlignment, Alignment(horizontal: .trailing, vertical: .top))
        XCTAssertEqual(abs.positionOffset.width, -8)
        XCTAssertEqual(abs.positionOffset.height, 4)

        XCTAssertFalse(PaywallStyle(position: .relative).isOutOfFlow)
        XCTAssertFalse(PaywallStyle(position: .normal).isOutOfFlow)
        XCTAssertFalse(PaywallStyle().isOutOfFlow) // nil → normal
        XCTAssertTrue(PaywallStyle(position: .sticky).isOutOfFlow)
        XCTAssertTrue(PaywallStyle(position: .fixed).isOutOfFlow)
    }

    // MARK: - Initial product selection seed (matches web firstDefaultProductId)

    private func tree(root: PaywallNode, products: [PaywallProduct], pages: [PaywallPageNode]? = nil) -> PaywallTree {
        PaywallTree(theme: PaywallTree.fallbackTheme, root: root, products: products, pages: pages)
    }

    func testFirstDefaultProductIdHonoursSelectorDefault() {
        let sel = PaywallNode(id: "s", kind: .productSelector, productIds: ["yearly", "monthly"], defaultProductId: "monthly")
        let root = PaywallNode(id: "r", kind: .stack, direction: .vertical, children: [sel])
        let t = tree(root: root, products: [PaywallProduct(identifier: "yearly", label: "Y"),
                                            PaywallProduct(identifier: "monthly", label: "M")])
        XCTAssertEqual(PaywallTreeView.firstDefaultProductId(t), "monthly")
    }

    func testFirstDefaultProductIdFallsBackToHighlightedThenFirst() {
        // No defaultProductId → highlighted product among the selector's ids.
        let sel = PaywallNode(id: "s", kind: .productSelector, productIds: ["a", "b"])
        let root = PaywallNode(id: "r", kind: .stack, direction: .vertical, children: [sel])
        let t = tree(root: root, products: [PaywallProduct(identifier: "a", label: "A"),
                                            PaywallProduct(identifier: "b", label: "B", highlight: true)])
        XCTAssertEqual(PaywallTreeView.firstDefaultProductId(t), "b")

        // No highlight → first id in the selector.
        let t2 = tree(root: root, products: [PaywallProduct(identifier: "a", label: "A"),
                                             PaywallProduct(identifier: "b", label: "B")])
        XCTAssertEqual(PaywallTreeView.firstDefaultProductId(t2), "a")
    }

    func testFirstDefaultProductIdFindsBareProductNode() {
        let card = PaywallNode(id: "p", kind: .product, productId: "lifetime")
        let root = PaywallNode(id: "r", kind: .stack, direction: .vertical, children: [card])
        let t = tree(root: root, products: [PaywallProduct(identifier: "lifetime", label: "L")])
        XCTAssertEqual(PaywallTreeView.firstDefaultProductId(t), "lifetime")
    }

    func testFirstDefaultProductIdWalksPagesWhenRootHasNoneSelector() {
        let root = PaywallNode(id: "r", kind: .stack, direction: .vertical, children: [
            PaywallNode(id: "t", kind: .text, text: "hi")
        ])
        let pageSel = PaywallNode(id: "ps", kind: .productSelector, productIds: ["weekly"], defaultProductId: "weekly")
        let page = PaywallPageNode(id: "pg", root: PaywallNode(id: "pr", kind: .stack, direction: .vertical, children: [pageSel]))
        let t = tree(root: root, products: [PaywallProduct(identifier: "weekly", label: "W")], pages: [page])
        XCTAssertEqual(PaywallTreeView.firstDefaultProductId(t), "weekly")
    }

    func testFirstDefaultProductIdNilWhenNoProductsAnywhere() {
        let root = PaywallNode(id: "r", kind: .stack, direction: .vertical, children: [
            PaywallNode(id: "t", kind: .text, text: "hi")
        ])
        XCTAssertNil(PaywallTreeView.firstDefaultProductId(tree(root: root, products: [])))
    }

    // MARK: - Selector with empty productIds falls back to all visible (selection seed)

    func testFirstDefaultProductIdEmptyProductIdsUsesAllProducts() {
        let sel = PaywallNode(id: "s", kind: .productSelector, productIds: [])
        let root = PaywallNode(id: "r", kind: .stack, direction: .vertical, children: [sel])
        let t = tree(root: root, products: [PaywallProduct(identifier: "x", label: "X", highlight: true),
                                            PaywallProduct(identifier: "y", label: "Y")])
        // Empty ids → consider all products; highlighted "x" wins.
        XCTAssertEqual(PaywallTreeView.firstDefaultProductId(t), "x")
    }
}
