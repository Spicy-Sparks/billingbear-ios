#if canImport(SwiftUI)
import SwiftUI

// MARK: - Color parsing
//
// The dashboard serves colours as CSS strings: #RGB / #RRGGBB / #RRGGBBAA and rgba(r,g,b,a).
// Parse them into SwiftUI Color so the document drives the palette directly.

@available(iOS 15.0, macOS 12.0, *)
extension Color {
    /// Parse a CSS colour string. Returns nil if it can't be parsed so callers can fall back.
    init?(css raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") {
            guard let rgba = Color.parseHex(raw) else { return nil }
            self = Color(.sRGB, red: rgba.0, green: rgba.1, blue: rgba.2, opacity: rgba.3)
            return
        }
        let lower = raw.lowercased()
        if lower.hasPrefix("rgb") {
            guard let rgba = Color.parseRGBA(lower) else { return nil }
            self = Color(.sRGB, red: rgba.0, green: rgba.1, blue: rgba.2, opacity: rgba.3)
            return
        }
        return nil
    }

    /// Parse a CSS colour with a guaranteed fallback.
    static func css(_ raw: String?, fallback: Color) -> Color {
        Color(css: raw) ?? fallback
    }

    private static func parseHex(_ s: String) -> (Double, Double, Double, Double)? {
        var hex = s
        hex.removeFirst()
        if hex.count == 3 || hex.count == 4 {
            // Expand shorthand (#abc -> #aabbcc).
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            let r = Double((value & 0xFF0000) >> 16) / 255
            let g = Double((value & 0x00FF00) >> 8) / 255
            let b = Double(value & 0x0000FF) / 255
            return (r, g, b, 1)
        } else {
            let r = Double((value & 0xFF000000) >> 24) / 255
            let g = Double((value & 0x00FF0000) >> 16) / 255
            let b = Double((value & 0x0000FF00) >> 8) / 255
            let a = Double(value & 0x000000FF) / 255
            return (r, g, b, a)
        }
    }

    private static func parseRGBA(_ s: String) -> (Double, Double, Double, Double)? {
        guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") else { return nil }
        let inner = s[s.index(after: open)..<close]
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3,
              let r = Double(parts[0]), let g = Double(parts[1]), let b = Double(parts[2]) else { return nil }
        let a = parts.count >= 4 ? (Double(parts[3]) ?? 1) : 1
        return (r / 255, g / 255, b / 255, a)
    }
}

// MARK: - Feature icon mapping
//
// The paywall builder's icon picker exposes a fixed name set. Each maps to an SF Symbol so the SDK
// has zero icon-library dependencies. Mirrors the RN SDK's DefaultFeatureIcon glyph set.

@available(iOS 15.0, macOS 12.0, *)
enum PaywallIcon {
    static func symbol(for name: String) -> String {
        switch name.lowercased() {
        case "check", "checkmark": return "checkmark"
        case "star": return "star.fill"
        case "lightning", "bolt": return "bolt.fill"
        case "shield": return "shield.fill"
        case "heart": return "heart.fill"
        case "sparkles": return "sparkles"
        case "music": return "music.note"
        case "headphones": return "headphones"
        case "lock": return "lock.fill"
        case "cloud": return "cloud.fill"
        case "infinity": return "infinity"
        case "crown": return "crown.fill"
        case "gift": return "gift.fill"
        case "rocket": return "airplane"
        case "download": return "arrow.down.circle.fill"
        case "globe": return "globe"
        default: return "checkmark"
        }
    }
}

// MARK: - Remote image
//
// A dependency-free async image loader. `AsyncImage` exists on iOS 15, but we wrap it so callers
// get a graceful empty placeholder (the paywall never shows a broken-image glyph).

@available(iOS 15.0, macOS 12.0, *)
struct RemoteImage: View {
    let url: String
    var contentMode: ContentMode = .fill
    /// CSS `object-fit: fill` — stretch to the frame ignoring aspect ratio (no `aspectRatio` lock).
    /// Used for image nodes with `contentMode: "fill"`; `.fit`/`.fill` keep aspect.
    var stretch: Bool = false

    var body: some View {
        if let u = URL(string: url) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let image):
                    if stretch {
                        image.resizable()
                    } else {
                        image.resizable().aspectRatio(contentMode: contentMode)
                    }
                default:
                    Color.clear
                }
            }
        } else {
            Color.clear
        }
    }
}
#endif
