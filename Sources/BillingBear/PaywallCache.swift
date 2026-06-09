import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Speed layer: persistent on-device paywall + offerings cache
//
// The differentiator over webview paywalls (Superwall) is that ours paint in < 1 frame: we
// prefetch the project's paywall documents + offerings right after configure() and on every
// app-foreground, persist them on-device, and the present path reads SYNCHRONOUSLY from that cache
// (zero network on the hot path) then background-revalidates (stale-while-revalidate). When offline,
// the last cached paywall still renders.
//
// This file owns the persistence + freshness model:
//   • `CachedPaywall` / `CachedOfferings` — Codable envelopes carrying the payload + `fetchedAt`.
//   • `PaywallCacheStore` — a tiny protocol so tests inject a temp directory + a deterministic clock,
//     and `FilePaywallCacheStore` — the production FileManager-backed implementation that writes one
//     JSON file per (project, identifier) under the app's Caches directory.
//
// Cache misses are a NORMAL path (return nil). Read/parse errors are NOT swallowed silently into a
// miss where it would hide corruption from us: a corrupt entry is removed and surfaced via the
// store's error channel so the caller can log it, while still degrading to a miss so the UI keeps
// working. Write errors propagate to the caller (prefetch logs them) rather than being hidden.

// MARK: - Small concurrency utility

/// A minimal lock-protected box so an actor can expose a thread-safe, nonisolated synchronous mirror
/// of a reference (used to read the paywall cache from `Purchases.cachedPaywall(_:)` without hopping
/// onto the actor — the instant-present hot path must not await).
final class LockedBox<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSLock()

    init(_ value: Value) { self._value = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

// MARK: - Codable envelopes

/// A persisted paywall response plus the wall-clock instant it was fetched. Freshness is computed
/// against this timestamp + the configured TTL.
public struct CachedPaywall: Codable, Equatable, Sendable {
    public let identifier: String
    public let response: PaywallResponse
    /// When the underlying network fetch completed (epoch seconds, UTC).
    public let fetchedAt: Date

    public init(identifier: String, response: PaywallResponse, fetchedAt: Date) {
        self.identifier = identifier
        self.response = response
        self.fetchedAt = fetchedAt
    }

    /// Age in seconds relative to `now`. Negative clock skew clamps to 0 (treat as just-fetched).
    public func age(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(fetchedAt))
    }

    /// Fresh when its age is within `ttl`. A non-positive TTL means "always stale" (force revalidate).
    public func isFresh(now: Date, ttl: TimeInterval) -> Bool {
        ttl > 0 && age(now: now) <= ttl
    }
}

/// A persisted offerings payload plus the instant it was fetched. Offerings carry the live product
/// metadata + attached paywalls the app can present, so they are prefetched alongside paywalls.
public struct CachedOfferings: Codable, Equatable, Sendable {
    public let offerings: Offerings
    public let fetchedAt: Date

    public init(offerings: Offerings, fetchedAt: Date) {
        self.offerings = offerings
        self.fetchedAt = fetchedAt
    }

    public func age(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(fetchedAt))
    }

    public func isFresh(now: Date, ttl: TimeInterval) -> Bool {
        ttl > 0 && age(now: now) <= ttl
    }
}

// MARK: - Store protocol (test seam)

/// Errors surfaced by the cache store. A cache MISS is not an error (returns nil); these represent
/// real I/O / corruption problems that must not be swallowed silently.
public enum PaywallCacheError: Error, Equatable {
    /// The on-disk entry could not be decoded (corrupt / incompatible). The store removes the file
    /// and reports this so the caller can log it; reads still degrade to a miss.
    case corruptEntry(key: String)
    /// A write failed (full disk, sandbox restriction, encode failure).
    case writeFailed(key: String, underlying: String)
    /// The store directory could not be created.
    case directoryUnavailable(String)
}

/// Persistence seam for the paywall/offerings cache. The production store writes JSON files under
/// Caches; tests inject an in-memory or temp-dir store + a fixed clock so they are deterministic and
/// headless. All keys are caller-namespaced (project + identifier) before reaching the store.
public protocol PaywallCacheStore: AnyObject, Sendable {
    /// Read the raw bytes for `key`, or nil on a miss. Throws `PaywallCacheError.corruptEntry` only
    /// when an entry exists but is unreadable.
    func readData(forKey key: String) throws -> Data?
    /// Persist `data` under `key`. Throws `PaywallCacheError.writeFailed` on failure.
    func writeData(_ data: Data, forKey key: String) throws
    /// Remove a single entry. No-op on a miss.
    func remove(forKey key: String)
    /// Remove every entry this store owns.
    func removeAll()
}

// MARK: - FileManager-backed store (production)

/// Writes one JSON file per key under `<base>/BillingBearPaywallCache/`. `base` defaults to the app's
/// Caches directory (eviction-tolerant: the OS may purge it under disk pressure, which is fine —
/// the next fetch repopulates it). Tests pass a temp directory.
public final class FilePaywallCacheStore: PaywallCacheStore, @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager
    /// Serialises file access so concurrent prefetch + present don't race a half-written file.
    private let lock = NSLock()

    /// - Parameter baseDirectory: the parent directory. Defaults to `Caches`. Application Support is
    ///   a valid alternative for callers that want the cache to survive OS purges.
    public init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = baseDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = base.appendingPathComponent("BillingBearPaywallCache", isDirectory: true)
    }

    /// Map a logical key to a filesystem-safe file name. Keys are already namespaced; we additionally
    /// percent-encode anything outside a conservative allowlist so identifiers with slashes/colons
    /// can't escape the directory.
    private func fileURL(forKey key: String) -> URL {
        let safe = key.addingPercentEncoding(withAllowedCharacters: Self.fileNameAllowed) ?? key
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }

    private static let fileNameAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.")
        return set
    }()

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PaywallCacheError.directoryUnavailable(error.localizedDescription)
        }
    }

    public func readData(forKey key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(forKey: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            // The file exists but can't be read — treat as corrupt: drop it and surface the error.
            try? fileManager.removeItem(at: url)
            throw PaywallCacheError.corruptEntry(key: key)
        }
    }

    public func writeData(_ data: Data, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        do {
            try ensureDirectory()
            try data.write(to: fileURL(forKey: key), options: .atomic)
        } catch let e as PaywallCacheError {
            throw e
        } catch {
            throw PaywallCacheError.writeFailed(key: key, underlying: error.localizedDescription)
        }
    }

    public func remove(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL(forKey: key))
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: directory)
    }
}

// MARK: - In-memory store (tests / ephemeral)

/// A non-persistent store backed by a dictionary. Useful for unit tests that want to exercise the
/// cache logic without touching the filesystem, and as an explicit opt-in for hosts that want the
/// speed layer's memory tier only.
public final class InMemoryPaywallCacheStore: PaywallCacheStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()
    /// When set, the next `writeData` throws this instead of writing — lets tests simulate disk-full.
    public var failNextWriteWith: PaywallCacheError?

    public init() {}

    public func readData(forKey key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func writeData(_ data: Data, forKey key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let failure = failNextWriteWith {
            failNextWriteWith = nil
            throw failure
        }
        storage[key] = data
    }

    public func remove(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - Cache facade

/// Front door to the persistent paywall/offerings cache. Owns key namespacing (project + identifier),
/// JSON (de)serialisation, freshness against an injectable clock, and a tiny in-process memory tier
/// so the synchronous hot path never blocks on disk twice in a row.
///
/// Thread-safe: serialises its own memory tier; the underlying store is independently locked.
public final class PaywallCache: @unchecked Sendable {

    // MARK: Dependencies (all injectable for tests)

    private let store: PaywallCacheStore
    /// Stable per-project namespace so two API keys / projects can't collide on the same device.
    private let project: String
    /// Injectable clock — tests freeze/advance it to exercise TTL/expiry deterministically.
    private let now: @Sendable () -> Date

    // In-process memory tier: warmed on read/write so the synchronous getter avoids re-hitting disk.
    private var paywallMemory: [String: CachedPaywall] = [:]
    private var offeringsMemory: CachedOfferings?
    private let memLock = NSLock()

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - store: persistence backend (FileManager in production, injected in tests).
    ///   - project: a stable namespace (e.g. derived from the API key) so entries don't collide
    ///     across projects/keys on the same device.
    ///   - now: clock provider. Defaults to `Date()`.
    public init(
        store: PaywallCacheStore,
        project: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.project = PaywallCache.sanitize(project)
        self.now = now
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        self.decoder = dec
    }

    // MARK: Keying

    /// Namespace a paywall identifier under the project. Format: `paywall.<project>.<identifier>`.
    private func paywallKey(_ identifier: String) -> String {
        "paywall.\(project).\(identifier)"
    }

    private var offeringsKey: String { "offerings.\(project)" }

    private static func sanitize(_ s: String) -> String {
        // Collapse to a short stable token so file names stay sane even for long API keys.
        Self.shortHash(s)
    }

    /// A short, stable, dependency-light hash for namespacing. Uses SHA-256 when CryptoKit is
    /// available, else a deterministic FNV-1a fallback. NOT security-sensitive — only for keying.
    static func shortHash(_ s: String) -> String {
        let bytes = Array(s.utf8)
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(bytes))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        #else
        var hash: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            hash ^= UInt64(b)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
        #endif
    }

    // MARK: Paywall read

    /// Synchronous read of a cached paywall, memory tier first then disk (warming memory). Returns
    /// nil on a miss. Throws only on a real corruption/read error (never to signal a miss).
    public func readPaywall(_ identifier: String) throws -> CachedPaywall? {
        memLock.lock()
        if let mem = paywallMemory[identifier] {
            memLock.unlock()
            return mem
        }
        memLock.unlock()

        guard let data = try store.readData(forKey: paywallKey(identifier)) else { return nil }
        do {
            let entry = try decoder.decode(CachedPaywall.self, from: data)
            memLock.lock(); paywallMemory[identifier] = entry; memLock.unlock()
            return entry
        } catch {
            // Corrupt on-disk entry: drop it and surface, but still report a miss.
            store.remove(forKey: paywallKey(identifier))
            throw PaywallCacheError.corruptEntry(key: identifier)
        }
    }

    /// Convenience: the cached `PaywallResponse` if present and fresh enough for `ttl`. Returns nil on
    /// a miss OR when the entry is stale. Never throws — corrupt entries are reported via `readPaywall`;
    /// this caller-facing helper treats any read failure as a miss (the present path then revalidates).
    public func freshPaywall(_ identifier: String, ttl: TimeInterval) -> PaywallResponse? {
        guard let entry = try? readPaywall(identifier), entry.isFresh(now: now(), ttl: ttl) else { return nil }
        return entry.response
    }

    /// The cached `PaywallResponse` regardless of freshness (offline / stale-while-revalidate render).
    /// Returns nil only on a true miss.
    public func anyPaywall(_ identifier: String) -> PaywallResponse? {
        (try? readPaywall(identifier))?.response
    }

    // MARK: Paywall write

    /// Persist a fresh paywall response, stamping `fetchedAt` from the clock. Throws on a write error
    /// (surfaced to prefetch so a full disk / sandbox issue isn't hidden). The memory tier is updated
    /// even when the disk write fails, so the current session still benefits from the value.
    @discardableResult
    public func writePaywall(_ identifier: String, response: PaywallResponse) throws -> CachedPaywall {
        let entry = CachedPaywall(identifier: identifier, response: response, fetchedAt: now())
        memLock.lock(); paywallMemory[identifier] = entry; memLock.unlock()
        let data = try encoder.encode(entry)
        try store.writeData(data, forKey: paywallKey(identifier))
        return entry
    }

    // MARK: Offerings

    public func readOfferings() throws -> CachedOfferings? {
        memLock.lock()
        if let mem = offeringsMemory { memLock.unlock(); return mem }
        memLock.unlock()

        guard let data = try store.readData(forKey: offeringsKey) else { return nil }
        do {
            let entry = try decoder.decode(CachedOfferings.self, from: data)
            memLock.lock(); offeringsMemory = entry; memLock.unlock()
            return entry
        } catch {
            store.remove(forKey: offeringsKey)
            throw PaywallCacheError.corruptEntry(key: "offerings")
        }
    }

    public func freshOfferings(ttl: TimeInterval) -> Offerings? {
        guard let entry = try? readOfferings(), entry.isFresh(now: now(), ttl: ttl) else { return nil }
        return entry.offerings
    }

    public func anyOfferings() -> Offerings? {
        (try? readOfferings())?.offerings
    }

    @discardableResult
    public func writeOfferings(_ offerings: Offerings) throws -> CachedOfferings {
        let entry = CachedOfferings(offerings: offerings, fetchedAt: now())
        memLock.lock(); offeringsMemory = entry; memLock.unlock()
        let data = try encoder.encode(entry)
        try store.writeData(data, forKey: offeringsKey)
        return entry
    }

    // MARK: Invalidation

    /// Drop a single paywall (memory + disk). The next read is a miss → forces a network revalidate.
    public func invalidatePaywall(_ identifier: String) {
        memLock.lock(); paywallMemory[identifier] = nil; memLock.unlock()
        store.remove(forKey: paywallKey(identifier))
    }

    /// Drop the cached offerings.
    public func invalidateOfferings() {
        memLock.lock(); offeringsMemory = nil; memLock.unlock()
        store.remove(forKey: offeringsKey)
    }

    /// Drop everything this cache owns (paywalls + offerings) for the configured project.
    public func invalidateAll() {
        memLock.lock(); paywallMemory.removeAll(); offeringsMemory = nil; memLock.unlock()
        store.removeAll()
    }
}
