// Written by AI on 2026.11.26 by model gemini-4-neon.
//
// On-device background website classifier backed by Apple Intelligence
// (FoundationModels). Only runs on the small minority of domains absent from
// the bundled 500k offline catalogue. Uses one site per call with single-letter
// constrained output (concurrency = 2), fresh sessions per call, permissive
// guardrails, greedy decoding, and a persistent per-host disk cache so each
// unlisted site is sorted once.

import AgentKeyringProtocol
import Foundation
import os
#if canImport(FoundationModels) && !os(watchOS)
import AgentKeyringApprovalCore
import FoundationModels
#endif

/// Input item for background on-device classification.
struct OnDeviceClassificationItem: Sendable, Hashable {
    let id: UUID
    let host: String
    let title: String

    init(id: UUID, host: String, title: String) {
        self.id = id
        self.host = host
        self.title = title
    }

    var cacheKey: String {
        DomainClassifier.cacheKey(origins: host.isEmpty ? [] : [host], title: title)
    }
}

/// One streamed result covering every item that shared the same normalised host.
struct OnDeviceClassificationResult: Sendable, Equatable {
    let ids: [UUID]
    let cacheKey: String
    let category: ImportCategory
    let fromCache: Bool
    let guardrailTriggered: Bool

    init(
        ids: [UUID],
        cacheKey: String,
        category: ImportCategory,
        fromCache: Bool = false,
        guardrailTriggered: Bool = false
    ) {
        self.ids = ids
        self.cacheKey = cacheKey
        self.category = category
        self.fromCache = fromCache
        self.guardrailTriggered = guardrailTriggered
    }
}

/// On-device Apple Intelligence category classifier with persistent per-host caching.
public final class OnDeviceCategoryClassifier: Sendable {
    public static let shared = OnDeviceCategoryClassifier()

    private struct CacheState: Sendable {
        var entries: [String: ImportCategory] = [:]
        var loaded = false
        var prewarmed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: CacheState())
    private let cacheURL: URL?

    public init(cacheURL: URL? = OnDeviceCategoryClassifier.defaultCacheURL()) {
        self.cacheURL = cacheURL
    }

    /// True when Apple Intelligence is enabled and the on-device language model is ready.
    public var isAvailable: Bool {
        #if canImport(FoundationModels) && !os(watchOS)
        if #available(macOS 26.0, iOS 26.0, *) {
            return makeModel().availability == .available
        }
        #endif
        return false
    }

    /// Synchronous cache lookup for a `StoredVaultLogin`. Returns nil if never sorted on device.
    public func cachedCategory(for item: StoredVaultLogin) -> ImportCategory? {
        let key = DomainClassifier.cacheKey(origins: item.origins, title: item.title)
        return cachedCategory(forKey: key)
    }

    /// Synchronous cache lookup for a single URL or hostname string.
    public func cachedCategory(forSite site: String) -> ImportCategory? {
        let key = DomainClassifier.cacheKey(site: site)
        return cachedCategory(forKey: key)
    }

    /// Synchronous cache lookup for a normalised host key.
    public func cachedCategory(forKey key: String) -> ImportCategory? {
        guard !key.isEmpty else { return nil }
        ensureCacheLoaded()
        return state.withLock { $0.entries[key] }
    }

    /// Warms the on-device model and offline catalogue in the background ahead of export.
    func prewarm() {
        Task.detached(priority: .utility) { [self] in
            DomainClassifier.warmCatalogue()
            self.ensureCacheLoaded()
            #if canImport(FoundationModels) && !os(watchOS)
            if #available(macOS 26.0, iOS 26.0, *) {
                let alreadyPrewarmed = self.state.withLock { s -> Bool in
                    if s.prewarmed { return true }
                    s.prewarmed = true
                    return false
                }
                guard !alreadyPrewarmed else { return }
                let model = self.makeModel()
                guard model.availability == .available else {
                    self.state.withLock { $0.prewarmed = false }
                    return
                }
                let session = LanguageModelSession(model: model, instructions: Self.instructions)
                session.prewarm()
            }
            #endif
        }
    }

    /// Classifies a single unlisted site on device (1 site per call, single-letter schema).
    func classifyOne(host: String, title: String) async -> (category: ImportCategory, guardrailTriggered: Bool) {
        #if canImport(FoundationModels) && !os(watchOS)
        if #available(macOS 26.0, iOS 26.0, *) {
            let model = makeModel()
            guard model.availability == .available else {
                return (.other, false)
            }
            return await runSingleCall(host: host, title: title, model: model)
        }
        #endif
        return (.other, false)
    }

    /// Streams classifications for unlisted items as each site finishes on device.
    /// Deduplicates identical hosts and runs up to `maxConcurrency` (default 2) calls in parallel.
    /// Pass `persistCache: false` during uncommitted staging so discarded sites are never written to disk or cache.
    func classifyStreaming(
        _ items: [OnDeviceClassificationItem],
        maxConcurrency: Int = 2,
        bypassCache: Bool = false,
        persistCache: Bool = true
    ) -> AsyncStream<OnDeviceClassificationResult> {
        AsyncStream { continuation in
            let worker = Task.detached(priority: .userInitiated) { [self] in
                guard !items.isEmpty else {
                    continuation.finish()
                    return
                }
                self.ensureCacheLoaded()
                let uncached = self.yieldCachedClassifications(items, bypassCache: bypassCache, to: continuation)
                guard !uncached.isEmpty, self.isAvailable else {
                    continuation.finish()
                    return
                }

                #if canImport(FoundationModels) && !os(watchOS)
                if #available(macOS 26.0, iOS 26.0, *) {
                    let policy = OnDeviceCachePolicy(bypassCache: bypassCache, persistCache: persistCache)
                    await self.classifyUncachedOnDevice(uncached, maxConcurrency: maxConcurrency, cachePolicy: policy, to: continuation)
                }
                #endif

                continuation.finish()
            }

            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }

    /// One host still to sort on device, standing for every item that shares it.
    private struct UnsortedHost: Sendable {
        let key: String
        let item: OnDeviceClassificationItem
        let ids: [UUID]
    }

    /// Whether streamed results may come from, and be written to, the per-host cache.
    private struct OnDeviceCachePolicy: Sendable {
        let bypassCache: Bool
        let persistCache: Bool
        var writesCache: Bool { !bypassCache && persistCache }
    }

    /// Deduplicates identical hosts so multi-account sites only run one model call, yields cached
    /// entries immediately, and returns the uncached hosts to queue for Apple Intelligence.
    private func yieldCachedClassifications(
        _ items: [OnDeviceClassificationItem],
        bypassCache: Bool,
        to continuation: AsyncStream<OnDeviceClassificationResult>.Continuation
    ) -> [UnsortedHost] {
        var orderedKeys: [String] = []
        var keyToIDs: [String: [UUID]] = [:]
        var keyToSample: [String: OnDeviceClassificationItem] = [:]
        for item in items {
            let key = item.cacheKey
            if keyToIDs[key] == nil {
                orderedKeys.append(key)
                keyToSample[key] = item
            }
            keyToIDs[key, default: []].append(item.id)
        }
        var uncached: [UnsortedHost] = []
        for key in orderedKeys {
            let ids = keyToIDs[key] ?? []
            if !bypassCache, let cached = cachedCategory(forKey: key) {
                continuation.yield(OnDeviceClassificationResult(
                    ids: ids,
                    cacheKey: key,
                    category: cached,
                    fromCache: true
                ))
            } else if let sample = keyToSample[key] {
                uncached.append(UnsortedHost(key: key, item: sample, ids: ids))
            }
        }
        return uncached
    }

    /// Persists on-device classifications only for logins the user actually saved.
    func remember(_ entries: [(host: String, title: String, category: ImportCategory)]) {
        guard !entries.isEmpty else { return }
        ensureCacheLoaded()
        let changed: Bool = state.withLock { s in
            var didChange = false
            for entry in entries {
                let key = DomainClassifier.cacheKey(origins: entry.host.isEmpty ? [] : [entry.host], title: entry.title)
                if s.entries[key] != entry.category {
                    s.entries[key] = entry.category
                    didChange = true
                }
            }
            return didChange
        }
        if changed {
            persistCacheToDisk()
        }
    }

    // MARK: FoundationModels execution

    #if canImport(FoundationModels) && !os(watchOS)
    @available(macOS 26.0, iOS 26.0, *)
    private func makeModel() -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    /// Runs up to `maxConcurrency` single-site calls at once over the uncached hosts, yielding each as it finishes.
    @available(macOS 26.0, iOS 26.0, *)
    private func classifyUncachedOnDevice(
        _ uncached: [UnsortedHost],
        maxConcurrency: Int,
        cachePolicy: OnDeviceCachePolicy,
        to continuation: AsyncStream<OnDeviceClassificationResult>.Continuation
    ) async {
        let model = makeModel()
        let limit = max(1, maxConcurrency)
        var newlyCached: [String: ImportCategory] = [:]

        await withTaskGroup(of: (String, [UUID], ImportCategory, Bool)?.self) { group in
            var nextIndex = 0
            func addNextCall() {
                let work = uncached[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let outcome = await self.runSingleCall(host: work.item.host, title: work.item.title, model: model)
                    return (work.key, work.ids, outcome.category, outcome.guardrailTriggered)
                }
            }
            for _ in 0..<min(limit, uncached.count) { addNextCall() }

            while let finished = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let (key, ids, category, guardrail) = finished {
                    if cachePolicy.writesCache {
                        newlyCached[key] = category
                        state.withLock { $0.entries[key] = category }
                    }
                    continuation.yield(OnDeviceClassificationResult(
                        ids: ids,
                        cacheKey: key,
                        category: category,
                        fromCache: false,
                        guardrailTriggered: guardrail
                    ))
                }
                if nextIndex < uncached.count, !Task.isCancelled { addNextCall() }
            }
        }

        if cachePolicy.writesCache, !newlyCached.isEmpty {
            persistCacheToDisk()
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func runSingleCall(
        host: String,
        title: String,
        model: SystemLanguageModel
    ) async -> (category: ImportCategory, guardrailTriggered: Bool) {
        let promptLine = Self.promptLine(host: host, title: title)
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        do {
            let schema = try Self.makeSingleCodeSchema()
            let response = try await session.respond(
                to: promptLine,
                schema: schema,
                includeSchemaInPrompt: false,
                options: GenerationOptions(samplingMode: .greedy)
            )
            let raw = try response.content.value(String.self, forProperty: "category")
            return (Self.category(fromWireLabel: raw) ?? .other, false)
        } catch {
            if Self.isGuardrailError(error) {
                // Fail safe on isolated guardrail refusal so private sites never auto-select.
                return (.sensitive, true)
            }
            return (.other, false)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func makeSingleCodeSchema() throws -> GenerationSchema {
        let labelSchema = DynamicGenerationSchema(
            name: "Category",
            anyOf: [
                "coding", "ai", "work", "shopping", "travel",
                "media", "social", "home", "finance", "other",
            ]
        )
        let root = DynamicGenerationSchema(
            name: "Result",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "category",
                    schema: DynamicGenerationSchema(referenceTo: "Category")
                )
            ]
        )
        return try GenerationSchema(root: root, dependencies: [labelSchema])
    }

    private static func category(fromWireLabel raw: String) -> ImportCategory? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "coding": .codingCloud
        case "ai": .aiTools
        case "work": .emailWork
        case "shopping": .shopping
        case "travel": .travelTransit
        case "media": .mediaGaming
        case "social": .socialMedia
        case "home": .homeDevices
        case "finance": .sensitive
        case "other": .other
        default: ImportCategory.fromCode(raw)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func isGuardrailError(_ error: any Error) -> Bool {
        if #available(macOS 27.0, iOS 27.0, *) {
            if let lmErr = error as? LanguageModelError {
                switch lmErr {
                case .guardrailViolation, .refusal: return true
                default: return false
                }
            }
        }
        if let genErr = error as? LanguageModelSession.GenerationError {
            switch genErr {
            case .guardrailViolation, .refusal: return true
            default: return false
            }
        }
        let desc = String(describing: error)
        return desc.localizedCaseInsensitiveContains("guardrail")
            || desc.localizedCaseInsensitiveContains("refusal")
    }
    #endif

    // Single-token semantic labels give Apple's 3B model strong semantic priors at minimal latency.
    private static let instructions = """
    Classify one website by domain/title into one category:
    - coding: dev tools, git, cloud consoles (AWS, GCP, Azure), hosting, servers, DNS, APIs, developer docs
    - ai: AI assistants, LLM APIs, AI coding IDEs, AI image/video/audio generators, ML platforms
    - work: email, calendar, work chat/video (Zoom, Slack), productivity, docs, design, project tools, business SaaS
    - shopping: retail stores, supermarkets, groceries, food delivery, marketplaces, parcel tracking
    - travel: airlines, trains, transit, hotels, Airbnb, rideshare, car rental
    - media: video/music streaming, podcasts, news, books, video games, Steam, consoles, tickets, events
    - social: social networks (X, Reddit, Instagram), forums, blogs/newsletters, messaging, communities
    - home: smart home, IoT devices, routers, NAS, printers, LAN hosts, consumer hardware
    - finance: banks, cards, payments, crypto, brokerages, payroll, tax, government, eID, insurance, medical/pharmacy, utilities, telecoms, vault managers
    - other: general brochure site, education, charity, or unclear
    """

    private static func promptLine(host: String, title: String) -> String {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.isEmpty {
            return cleanTitle.isEmpty ? "unknown" : cleanTitle
        }
        if cleanTitle.isEmpty || cleanTitle.caseInsensitiveCompare(cleanHost) == .orderedSame {
            return cleanHost
        }
        return "\(cleanHost) (\(cleanTitle))"
    }

    // MARK: Disk cache

    private func ensureCacheLoaded() {
        let needsLoad = state.withLock { !$0.loaded }
        guard needsLoad else { return }
        var loadedEntries: [String: ImportCategory] = [:]
        if let url = cacheURL,
           let data = try? Data(contentsOf: url),
           let cache = try? Agentkeyring_V2_StoredCategoryCache(serializedBytes: data) {
            for (k, v) in cache.categories {
                if let cat = ImportCategory(rawValue: v) {
                    loadedEntries[k] = cat
                }
            }
        }
        let immutableLoaded = loadedEntries
        state.withLock { s in
            if !s.loaded {
                for (k, v) in immutableLoaded where s.entries[k] == nil {
                    s.entries[k] = v
                }
                s.loaded = true
            }
        }
    }

    private func persistCacheToDisk() {
        guard let url = cacheURL else { return }
        var cache = Agentkeyring_V2_StoredCategoryCache()
        cache.categories = state.withLock { s in
            s.entries.mapValues(\.rawValue)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try cache.serializedData()
            try data.write(to: url, options: .atomic)
        } catch {
            // Cache persistence is best-effort; never fail classification on disk errors.
        }
    }

    public static func defaultCacheURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appending(path: "AgentKeyring", directoryHint: .isDirectory)
            .appending(path: "domain-category-cache.pb", directoryHint: .notDirectory)
    }
}
