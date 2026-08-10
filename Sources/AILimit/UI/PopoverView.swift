import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var store: AppStore
    var onOpenSettings: () -> Void
    var onHover: (Bool) -> Void

    /// Wide enough that a long window name such as `주간 · Claude Opus 4.5`
    /// fits on one line without truncation.
    static let contentWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if store.snapshots.isEmpty {
                Text(store.hasEnabledProviders ? S.loading.s : S.noServicesEnabled.s)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
            ForEach(store.snapshots) { snapshot in
                ProviderCard(snapshot: snapshot, onOpenSettings: onOpenSettings)
            }
            Divider()
            Text(S.autoRefreshFooter.s)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: Self.contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onHover(perform: onHover)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(S.appTitle.s)
                .font(.headline)
                .fixedSize()
            Spacer(minLength: 4)
            if let updated = store.lastUpdated {
                Text(updated, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                store.refresh(userInitiated: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(
                        store.isRefreshing
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: store.isRefreshing
                    )
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help(S.refreshNow.s)

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(S.settings.s)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help(S.quit.s)
        }
    }
}

struct ProviderCard: View {
    let snapshot: ProviderSnapshot
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(snapshot.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let plan = snapshot.planName {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if snapshot.limitReached {
                    Text(S.limitReached.s)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.red)
                        .fixedSize()
                }
            }

            if snapshot.isOK {
                if snapshot.windows.isEmpty && snapshot.note == nil {
                    Text(S.noUsageData.s)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.windows.indices, id: \.self) { index in
                    WindowRow(window: snapshot.windows[index])
                }
                if let note = snapshot.note {
                    HStack(spacing: 5) {
                        Image(systemName: "creditcard")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: snapshot.needsSetup ? "key.slash" : "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text(snapshot.errorMessage ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Only browser-cookie providers have an action here. Claude and
                // OpenAI need a CLI login instead, which the message already says.
                if snapshot.needsSetup, let console = Self.consoleURL(for: snapshot.id) {
                    HStack(spacing: 8) {
                        Button(S.setUpCookie.s) { onOpenSettings() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button {
                            if let url = URL(string: console) { NSWorkspace.shared.open(url) }
                        } label: {
                            Text(S.openLoginPage.s)
                        }
                        .buttonStyle(.link)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }

    /// Providers whose setup is "log in with your browser".
    static func consoleURL(for id: String) -> String? {
        switch id {
        case "qwen": return QwenRegionConfig.current().dashboardURL
        case "cursor": return "https://cursor.com/dashboard"
        default: return nil
        }
    }

    private var statusColor: Color {
        if !snapshot.isOK { return .orange }
        if snapshot.limitReached { return .red }
        switch Severity.of(snapshot.worstPercent) {
        case .ok: return .green
        case .warn: return .orange
        case .critical: return .red
        }
    }
}

/// Name and percentage share the top line, the bar spans the full width below.
/// The previous fixed-width name column truncated anything longer than a few
/// characters (`주간 · Claude Opus 4.5` → `주간 · Claude…`).
struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(Int(window.percent.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .fixedSize()
            }
            UsageBar(percent: window.percent)
            if window.detail != nil || window.resetsAt != nil {
                HStack(spacing: 8) {
                    if let detail = window.detail {
                        Text(detail)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let resetsAt = window.resetsAt {
                        Text(RelativeTime.resetText(resetsAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, geo.size.width * CGFloat(min(100, max(0, percent)) / 100)))
            }
        }
        .frame(height: 6)
    }

    private var color: Color {
        switch Severity.of(percent) {
        case .ok: return .green
        case .warn: return .orange
        case .critical: return .red
        }
    }
}
