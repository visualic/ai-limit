import Foundation
import Combine

struct CacheBlob: Codable {
    var snapshots: [ProviderSnapshot]
    var lastUpdated: Date?
}

@MainActor
final class AppStore: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = []
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var refreshInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: Keys.refreshInterval)
            scheduleTimer()
        }
    }
    @Published var showPercent: Bool {
        didSet { UserDefaults.standard.set(showPercent, forKey: Keys.showPercent) }
    }
    /// `""` follows the system. Published so the UI redraws, and a refresh
    /// follows because provider messages are built at fetch time — without it
    /// the cards would keep the previous language until the next poll.
    @Published var language: String {
        didSet {
            if language.isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.language)
            } else {
                UserDefaults.standard.set(language, forKey: Keys.language)
            }
            refresh(userInitiated: true)
        }
    }

    /// Services switched off in Settings. Published so a toggle reaches the
    /// popover and the menu bar at once instead of at the next poll.
    @Published var disabledProviderIDs: Set<String> {
        didSet {
            guard disabledProviderIDs != oldValue else { return }
            ProviderVisibility.disabledIDs = disabledProviderIDs
            snapshots.removeAll { disabledProviderIDs.contains($0.id) }
            saveCache()
            refresh(userInitiated: true)
        }
    }

    private var timer: Timer?
    /// A refresh asked for while one was already running. Timer ticks stay
    /// drop-on-busy — another tick is due shortly — but a settings change must
    /// not wait a whole interval to take effect.
    private var queuedRefresh = false

    init() {
        let defaults = UserDefaults.standard
        let storedInterval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = storedInterval > 0 ? storedInterval : 300
        showPercent = defaults.object(forKey: Keys.showPercent) == nil ? true : defaults.bool(forKey: Keys.showPercent)
        language = defaults.string(forKey: Keys.language) ?? ""
        disabledProviderIDs = ProviderVisibility.disabledIDs
        loadCache()
        scheduleTimer()
        refresh()
    }

    func isEnabled(_ id: String) -> Bool { !disabledProviderIDs.contains(id) }

    func setProvider(_ id: String, enabled: Bool) {
        if enabled {
            disabledProviderIDs.remove(id)
        } else {
            disabledProviderIDs.insert(id)
        }
    }

    var hasEnabledProviders: Bool { ProviderRoster.listing.contains { isEnabled($0.id) } }

    /// A refresh the user asked for may probe through an active rate-limit
    /// backoff; a timer tick may not.
    func refresh(userInitiated: Bool = false) {
        guard !isRefreshing else {
            if userInitiated { queuedRefresh = true }
            return
        }
        isRefreshing = true
        let providers = ProviderRoster.enabled(userInitiated: userInitiated)
        Task { [weak self] in
            let results: [(Int, ProviderResult)] = await withTaskGroup(of: (Int, ProviderResult).self) { group in
                for (index, provider) in providers.enumerated() {
                    group.addTask { (index, await provider.fetch()) }
                }
                var collected: [(Int, ProviderResult)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }
            }
            guard let self else { return }
            // The set can change mid-flight, so drop anything switched off while
            // this refresh was in the air rather than resurrecting its card.
            self.snapshots = results
                .map { index, result in Self.makeSnapshot(provider: providers[index], result: result) }
                .filter { self.isEnabled($0.id) }
            self.lastUpdated = Date()
            self.isRefreshing = false
            self.saveCache()
            if self.queuedRefresh {
                self.queuedRefresh = false
                self.refresh(userInitiated: true)
            }
        }
    }

    func refreshIfStale() {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 60 { return }
        refresh()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Remembers the last known plan for each provider.
    ///
    /// The badge is a property of the subscription, not of the last fetch, so a
    /// temporary API failure should not blank it out. `needsSetup` is different:
    /// that means the account is not connected at all, and showing a stale tier
    /// there would be a lie.
    nonisolated enum PlanCache {
        static func key(_ id: String) -> String { "planName.\(id)" }
        static func remember(_ name: String?, for id: String) {
            guard let name, !name.isEmpty else { return }
            UserDefaults.standard.set(name, forKey: key(id))
        }
        static func recall(_ id: String) -> String? {
            UserDefaults.standard.string(forKey: key(id))
        }
        static func forget(_ id: String) {
            UserDefaults.standard.removeObject(forKey: key(id))
        }
    }

    nonisolated static func makeSnapshot(provider: UsageProvider, result: ProviderResult) -> ProviderSnapshot {
        switch result {
        case .ok(let planName, let windows, let limitReached, let note):
            PlanCache.remember(planName, for: provider.id)
            return ProviderSnapshot(
                id: provider.id, displayName: provider.displayName, planName: planName,
                windows: windows, fetchedAt: Date(), errorMessage: nil,
                needsSetup: false, limitReached: limitReached, note: note
            )
        case .error(let message):
            return ProviderSnapshot(
                id: provider.id, displayName: provider.displayName,
                planName: PlanCache.recall(provider.id),
                windows: [], fetchedAt: Date(), errorMessage: message,
                needsSetup: false, limitReached: false, note: nil
            )
        case .needsSetup(let message):
            // Not connected: drop the remembered tier so a re-login cannot show
            // the previous account's plan.
            PlanCache.forget(provider.id)
            return ProviderSnapshot(
                id: provider.id, displayName: provider.displayName, planName: nil,
                windows: [], fetchedAt: Date(), errorMessage: message,
                needsSetup: true, limitReached: false, note: nil
            )
        }
    }

    private var cacheURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AILimit")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cache.json")
    }

    private func saveCache() {
        let blob = CacheBlob(snapshots: snapshots, lastUpdated: lastUpdated)
        if let data = try? JSONEncoder().encode(blob) {
            try? data.write(to: cacheURL)
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let blob = try? JSONDecoder().decode(CacheBlob.self, from: data) else { return }
        // A service switched off since the last run must not flash back on launch.
        snapshots = blob.snapshots.filter { isEnabled($0.id) }
        lastUpdated = blob.lastUpdated
    }
}
