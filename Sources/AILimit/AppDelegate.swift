import AppKit
import SwiftUI
import Combine

final class HoverTarget: NSObject {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    @objc func mouseEntered(with event: NSEvent) { onEnter?() }
    @objc func mouseExited(with event: NSEvent) { onExit?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = AppStore()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let hoverTarget = HoverTarget()
    private var settingsWindow: NSWindow?
    private var closeWork: DispatchWorkItem?
    private var isPinned = false
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.toolTip = S.statusItemTooltip.s
            let tracking = NSTrackingArea(
                rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: hoverTarget,
                userInfo: nil
            )
            button.addTrackingArea(tracking)
        }
        hoverTarget.onEnter = { [weak self] in self?.hoverEntered() }
        hoverTarget.onExit = { [weak self] in self?.hoverExited() }

        let hosting = NSHostingController(rootView: PopoverView(
            store: store,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onHover: { [weak self] inside in
                if inside { self?.cancelClose() } else { self?.scheduleClose() }
            }
        ))
        hosting.sizingOptions = [.intrinsicContentSize]
        popover.contentViewController = hosting
        popover.delegate = self
        popover.behavior = .transient

        syncPopoverSize()
        updateIcon()
        store.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateIcon()
                self?.syncPopoverSize()
            }
            .store(in: &cancellables)
        store.$showPercent
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func hoverEntered() {
        cancelClose()
        if !popover.isShown {
            showPopover(pinned: false)
        }
        store.refreshIfStale()
    }

    private func hoverExited() {
        guard !isPinned else { return }
        scheduleClose()
    }

    @objc private func statusItemClicked() {
        if popover.isShown {
            if isPinned {
                closePopover()
            } else {
                isPinned = true
                popover.behavior = .applicationDefined
            }
        } else {
            showPopover(pinned: true)
        }
    }

    /// `NSHostingController.sizingOptions = [.intrinsicContentSize]` alone does not
    /// reach NSPopover here — it keeps its 320×320 default and clips the SwiftUI
    /// content (the header and footer disappeared entirely). Push the measured
    /// size in explicitly, both before showing and whenever the content changes.
    private func syncPopoverSize() {
        guard let content = popover.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        var size = content.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        // Last-resort guard so an unusually long list can never exceed the screen.
        if let visible = statusItem?.button?.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            size.height = min(size.height, visible.height - 40)
        }
        if popover.contentSize != size {
            popover.contentSize = size
        }
    }

    private func showPopover(pinned: Bool) {
        isPinned = pinned
        popover.behavior = pinned ? .applicationDefined : .transient
        guard let button = statusItem.button else { return }
        syncPopoverSize()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if pinned {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func closePopover() {
        isPinned = false
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in self.isPinned = false }
    }

    private func scheduleClose() {
        cancelClose()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPinned else { return }
            if let window = self.popover.contentViewController?.view.window {
                let mouseLocation = NSEvent.mouseLocation
                if window.frame.insetBy(dx: -8, dy: -8).contains(mouseLocation) { return }
            }
            self.closePopover()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }

    /// Providers that belong in the menu bar: ones the user actually set up.
    /// A `needsSetup` provider is not part of this user's toolkit and would only
    /// add a permanently dead column, so it is left out entirely.
    private var menuBarSnapshots: [ProviderSnapshot] {
        store.snapshots.filter { !$0.needsSetup }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let shown = menuBarSnapshots

        button.image = MeterIcon.image(entries: shown.map { snapshot in
            snapshot.isOK
                ? MeterIcon.Entry(percent: snapshot.worstPercent,
                                  color: MeterIcon.color(for: snapshot.worstPercent))
                : .unknown()
        })
        button.imagePosition = .imageLeading
        button.title = store.showPercent ? headlineTitle(shown) : ""
        button.toolTip = tooltip(shown)
    }

    /// The number printed next to the columns. Defaults to the first configured
    /// provider rather than the maximum: the maximum is what made the old icon
    /// useless, since a service parked at 100% for days masked every other one.
    private func headlineTitle(_ shown: [ProviderSnapshot]) -> String {
        let healthy = shown.filter(\.isOK)
        guard !healthy.isEmpty else { return "" }
        let preferred = UserDefaults.standard.string(forKey: Keys.menuBarProvider) ?? ""
        let chosen: ProviderSnapshot?
        if preferred == AppDelegate.highestValueToken {
            chosen = healthy.max { $0.worstPercent < $1.worstPercent }
        } else {
            // Fall back to the first healthy provider when the chosen one is
            // unavailable, so the slot never goes blank.
            chosen = healthy.first { $0.id == preferred } ?? healthy.first
        }
        guard let chosen else { return "" }
        return String(format: " %.0f%%", chosen.worstPercent)
    }

    private func tooltip(_ shown: [ProviderSnapshot]) -> String {
        guard !shown.isEmpty else { return S.statusItemTooltip.s }
        return shown.map { snapshot in
            guard snapshot.isOK else { return S.checkFailed(snapshot.displayName) }
            return "\(snapshot.displayName): \(Int(snapshot.worstPercent.rounded()))%"
        }.joined(separator: "\n")
    }

    static let highestValueToken = "__highest__"

    func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .resizable]
            window.title = S.settingsWindowTitle.s
            // Size to what the form actually needs instead of a guessed height,
            // and stay resizable so a longer error message can never be cut off.
            let fitting = hosting.view.fittingSize
            window.setContentSize(NSSize(width: max(540, fitting.width), height: max(520, fitting.height)))
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.title = S.settingsWindowTitle.s
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

#if DEBUG
    /// Hooks for `--preview-app`, which drives the real status-item path so the
    /// popover sizing is verified as shipped rather than as re-implemented.
    func debugShowPopover(with snapshots: [ProviderSnapshot]) {
        store.snapshots = snapshots
        store.lastUpdated = Date()
        showPopover(pinned: true)
    }

    /// Shows the popover with whatever the real providers returned.
    func debugShowPopoverLive() { showPopover(pinned: true) }

    var debugPopover: NSPopover { popover }
#endif
}
