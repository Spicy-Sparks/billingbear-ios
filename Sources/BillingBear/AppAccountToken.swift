import Foundation
import CryptoKit

/// Deterministic StoreKit `appAccountToken` for an appUserId — byte-for-byte the React Native SDK's
/// `appAccountTokenFor` (`sdk/react-native/src/appAccountToken.ts`).
///
/// StoreKit needs a UUID, and anonymous ids (`$BillingBearAnonymousID:…`) are not one, so the token
/// is a UUIDv5 (RFC 4122 §4.3, SHA-1) of the appUserId under a fixed BillingBear namespace: always a
/// valid UUID, stable for the same appUserId on every device and platform, and it never puts the raw
/// appUserId on the wire. It is an audit/attribution signal; the server's restore-transfer policy,
/// not this token, decides who owns a purchase.
enum AppAccountToken {
    /// Fixed namespace, shared with the React Native and Android SDKs.
    static let namespace = UUID(uuidString: "a1f0c3d2-7b64-4e2a-9c1f-2d3e4f5a6b7c")!

    static func token(for appUserId: String) -> UUID {
        uuidV5(namespace: namespace, name: appUserId)
    }

    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var data = Data()
        withUnsafeBytes(of: namespace.uuid) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(name.utf8))
        var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
