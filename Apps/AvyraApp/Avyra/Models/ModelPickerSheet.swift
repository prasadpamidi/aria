import AriaApple
import SwiftUI

#if canImport(AriaMLX)
    import AriaMLX
#endif

// MARK: - ModelPickerSheet

/// Native-feeling model picker. Three sections in a standard
/// `Form` / `insetGrouped` list:
///
///   1. **Active** — single highlighted row showing what the chat
///      will route through right now, with a tap-to-change disclosure.
///   2. **Available models** — every catalog family as a disclosure
///      row (sf-symbol indicator + name + variant count + capability
///      summary). Tap to push the family detail screen.
///   3. **About local models** — plain footer, not a card. No
///      dismiss state to track.
///
/// Family detail screen is a vertical list of variants with native
/// accessory icons (downloaded checkmark / cloud arrow / progress
/// ring). Tapping a downloaded variant activates it + dismisses;
/// tapping a non-downloaded variant kicks off the download with
/// inline progress. Swipe-to-delete on downloaded rows.
///
/// All state flows through `MLXModelManager` so swaps reflect
/// everywhere (chat header pill, settings) without manual fan-out.
struct ModelPickerSheet: View {
    // MARK: Lifecycle

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.appState = appState
        self.onClose = onClose
    }

    // MARK: Internal

    var body: some View {
        NavigationStack {
            List {
                self.activeSection
                #if canImport(AriaMLX)
                    self.availableSection
                #endif
                self.aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .cancel, action: self.onClose)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: Private

    @Bindable private var appState: AppState

    private let onClose: () -> Void

    private var activeIconName: String {
        #if canImport(AriaMLX)
            if self.appState.modelManager.activeCapabilities != nil {
                return "shippingbox"
            }
        #endif
        return "apple.intelligence"
    }

    private var activeName: String {
        #if canImport(AriaMLX)
            if let capabilities = self.appState.modelManager.activeCapabilities {
                return capabilities.displayName
            }
        #endif
        return "Apple Intelligence"
    }

    private var activeSubtitle: String {
        #if canImport(AriaMLX)
            if self.appState.modelManager.activeCapabilities != nil {
                return "Open-weight model · running locally with MLX"
            }
        #endif
        return "On-device · always available"
    }

    private var hasActiveMLXModel: Bool {
        #if canImport(AriaMLX)
            return self.appState.modelManager.activeCapabilities != nil
        #else
            return false
        #endif
    }

    // MARK: - Active section

    private var activeSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: self.activeIconName)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.activeName)
                        .font(.body.weight(.semibold))
                    Text(self.activeSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        } header: {
            Text("Active model")
        } footer: {
            Text("Used for every chat turn until you switch models.")
        }
    }

    // MARK: - Available

    #if canImport(AriaMLX)
        private var availableSection: some View {
            Section {
                self.appleIntelligenceRow
                let families = ModelFamilyGroup.fromCatalog(
                    self.appState.modelManager.catalog
                )
                ForEach(families) { family in
                    NavigationLink {
                        ModelFamilyDetail(
                            family: family,
                            manager: self.appState.modelManager,
                            downloads: self.appState.downloads,
                            onPicked: self.onClose
                        )
                    } label: {
                        ModelFamilyRow(
                            family: family,
                            activeId: self.appState.modelManager.activeModelID
                        )
                    }
                }
            } header: {
                Text("Available models")
            } footer: {
                Text(
                    "Apple Intelligence is built in and runs without download. Open-weight models download on first use."
                )
            }
        }

        private var appleIntelligenceRow: some View {
            Button {
                self.appState.modelManager.setActiveModel(id: nil)
                self.onClose()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "apple.intelligence")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Intelligence")
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text("On-device 3B · Always available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !self.hasActiveMLXModel {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    #endif

    // MARK: - About

    private var aboutSection: some View {
        Section {
            // Empty section, footer-only — gives us a real iOS
            // grouped footer below the model lists without needing a
            // separate card visual treatment.
            EmptyView()
        } footer: {
            Text(
                "Local models are measured in billions of parameters (0.6B, 1B, 3B). Bigger sizes are usually smarter but slower and use more memory — pick a size that fits your device."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ModelFamilyGroup

#if canImport(AriaMLX)
    /// Groups raw catalog rows by family and computes the metadata
    /// the row + detail views need (display name, variant count,
    /// rolled-up capability summary).
    struct ModelFamilyGroup: Identifiable {
        // MARK: Internal

        let id: String
        let displayName: String
        let variants: [MLXModelCapabilities]

        var variantCount: Int {
            self.variants.count
        }

        /// Roll up capability flags across every variant — the family
        /// row advertises "has vision" if any variant supports
        /// vision, etc., so the user can spot interesting families
        /// without drilling in.
        var summary: ModelFamilySummary {
            ModelFamilySummary(
                hasTools: self.variants.contains { $0.supportsTools },
                hasVision: self.variants.contains { $0.supportsVision }
            )
        }

        /// Build groups from the catalog, preserving catalog order.
        static func fromCatalog(_ catalog: [MLXModelCapabilities]) -> [ModelFamilyGroup] {
            var seen: [String] = []
            var bucket: [String: [MLXModelCapabilities]] = [:]
            for entry in catalog {
                let key = Self.canonicalFamily(for: entry.family)
                if bucket[key] == nil {
                    seen.append(key)
                }
                bucket[key, default: []].append(entry)
            }
            return seen.map { key in
                ModelFamilyGroup(
                    id: key,
                    displayName: Self.displayName(for: key),
                    variants: bucket[key] ?? []
                )
            }
        }

        // MARK: Private

        private static func canonicalFamily(for raw: String) -> String {
            switch raw {
            case "qwen3.5-vl", "qwen3.5": "qwen"
            case "llama-3.2": "llama"
            case "gemma-2", "gemma-4": "gemma"
            default: raw
            }
        }

        private static func displayName(for key: String) -> String {
            switch key {
            case "qwen": "Qwen 3.5"
            case "llama": "Llama 3.2"
            case "gemma": "Gemma"
            default: key.capitalized
            }
        }
    }

    struct ModelFamilySummary {
        let hasTools: Bool
        let hasVision: Bool
    }

    // MARK: - ModelFamilyRow

    /// Native-style List row for a family. SF-symbol indicator on the
    /// left, family name + a concise descriptor on the right, plus a
    /// small "in use" marker when the active model belongs to this
    /// family.
    struct ModelFamilyRow: View {
        // MARK: Internal

        let family: ModelFamilyGroup
        let activeId: String?

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(self.family.displayName)
                            .font(.body)
                        if self.isActiveFamily {
                            Text("In use")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(Color.accentColor.opacity(0.14))
                                )
                        }
                    }
                    Text(self.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }

        // MARK: Private

        private var isActiveFamily: Bool {
            guard let activeId else {
                return false
            }
            return self.family.variants.contains { $0.id == activeId }
        }

        /// "3 sizes · Tools · Vision" — concise inline summary of
        /// what's interesting about this family.
        private var subtitle: String {
            var parts: [String] = []
            parts.append("\(self.family.variantCount) \(self.family.variantCount == 1 ? "size" : "sizes")")
            if self.family.summary.hasTools {
                parts.append("Tools")
            }
            if self.family.summary.hasVision {
                parts.append("Vision")
            }
            return parts.joined(separator: " · ")
        }
    }
#endif

// MARK: - ModelFamilyDetail

#if canImport(AriaMLX)
    /// Variant list pushed from a family row. Each row uses native
    /// iOS accessory conventions:
    ///
    ///   - **Not downloaded** — cloud-arrow icon, tap to download
    ///   - **Downloading** — circular progress ring + percentage
    ///   - **Downloaded** — checkmark when active, plain when idle
    ///   - **Swipe** — delete (downloaded only)
    ///
    /// Tapping a downloaded variant activates it + dismisses the
    /// whole sheet. No big "Download" pill buttons or destructive
    /// red trash icons in the row — the visual chrome stays minimal
    /// and feels like a real iOS settings screen.
    struct ModelFamilyDetail: View {
        // MARK: Internal

        let family: ModelFamilyGroup
        let manager: MLXModelManager
        let downloads: DownloadCoordinator
        let onPicked: () -> Void

        var body: some View {
            List {
                if self.downloads.hasActiveDownloads {
                    DownloadInProgressBanner(
                        active: Array(self.downloads.active.values)
                            .sorted { $0.displayName < $1.displayName }
                    )
                    .listRowInsets(.init(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(self.family.variants, id: \.id) { variant in
                        VariantRow(
                            variant: variant,
                            state: self.state(for: variant),
                            isActive: variant.id == self.manager.activeModelID,
                            onTap: { self.handleTap(variant: variant) }
                        )
                        // Long-press menu for the actions that don't
                        // fit the primary tap (delete, cancel) — more
                        // discoverable than swipe alone for App Store
                        // users not used to iOS power-user gestures.
                        .contextMenu {
                                if case .downloaded = self.state(for: variant) {
                                    Button(role: .destructive) {
                                        self.delete(variant: variant)
                                    } label: {
                                        Label("Delete from device", systemImage: "trash")
                                    }
                                }
                                if case .downloading = self.state(for: variant) {
                                    Button(role: .destructive) {
                                        self.downloads.cancel(modelId: variant.id)
                                    } label: {
                                        Label("Cancel download", systemImage: "xmark.circle")
                                    }
                                }
                            }
                            // Swipe-to-delete for users who DO know iOS
                            // conventions — backs up the context menu.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if case .downloaded = self.state(for: variant) {
                                    Button(role: .destructive) {
                                        self.delete(variant: variant)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                if case .downloading = self.state(for: variant) {
                                    Button {
                                        self.downloads.cancel(modelId: variant.id)
                                    } label: {
                                        Label("Cancel", systemImage: "xmark")
                                    }
                                }
                            }
                    }
                } footer: {
                    Text(self.familyBlurb)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(self.family.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .task { self.refreshDownloadedCache() }
            .alert("Something went wrong", isPresented: self.errorBinding) {
                Button("OK", role: .cancel) { self.errorMessage = nil }
            } message: {
                Text(self.errorMessage ?? "")
            }
        }

        // MARK: Private

        @State private var downloadedCache: [String: Bool] = [:]
        @State private var errorMessage: String?

        private var errorBinding: Binding<Bool> {
            Binding(
                get: { self.errorMessage != nil },
                set: { if !$0 {
                    self.errorMessage = nil
                } }
            )
        }

        /// Short descriptor for the family — generic so we don't have
        /// to maintain per-family copy. The variant rows carry the
        /// per-size detail.
        private var familyBlurb: String {
            "All sizes run fully on-device using MLX. Larger sizes give better answers but need more memory and time per response."
        }

        // MARK: - State helpers

        /// Single source of truth: coordinator's view of "is this
        /// downloading right now?" wins, then the disk cache decides
        /// `downloaded` vs `notDownloaded`. Refreshed on appear and
        /// after each download completes / is deleted.
        private func state(for variant: MLXModelCapabilities) -> VariantDownloadState {
            if let snap = self.downloads.snapshot(for: variant.id) {
                return .downloading(snap)
            }
            switch self.downloadedCache[variant.id] {
            case .some(true): return .downloaded
            case .some(false): return .notDownloaded
            case .none: return .unknown
            }
        }

        private func refreshDownloadedCache() {
            for variant in self.family.variants {
                let downloaded = (try? self.manager.isDownloaded(id: variant.id)) == true
                self.downloadedCache[variant.id] = downloaded
            }
        }

        private func handleTap(variant: MLXModelCapabilities) {
            switch self.state(for: variant) {
            case .unknown:
                break
            case .notDownloaded:
                self.downloads.start(
                    variant: variant,
                    manager: self.manager,
                    onCompleted: { self.refreshDownloadedCache() },
                    onFailed: { self.errorMessage = $0 }
                )
            case .downloading:
                self.downloads.cancel(modelId: variant.id)
            case .downloaded:
                self.manager.setActiveModel(id: variant.id)
                self.onPicked()
            }
        }

        private func delete(variant: MLXModelCapabilities) {
            Task {
                do {
                    try await self.manager.remove(id: variant.id)
                    await MainActor.run {
                        self.downloadedCache[variant.id] = false
                    }
                } catch {
                    await MainActor.run {
                        self.errorMessage = "Could not delete: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - VariantDownloadState

    enum VariantDownloadState: Equatable {
        case unknown
        case notDownloaded
        case downloading(DownloadCoordinator.ActiveDownload)
        case downloaded
    }

    // MARK: - VariantRow

    struct VariantRow: View {
        // MARK: Internal

        let variant: MLXModelCapabilities
        let state: VariantDownloadState
        let isActive: Bool
        let onTap: () -> Void

        var body: some View {
            Button(action: self.onTap) {
                HStack(spacing: 14) {
                    self.leadingAccessory
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(self.variant.displayName)
                                .font(.body)
                                .foregroundStyle(.primary)
                            if self.isActive {
                                Text("In use")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tint)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(Color.accentColor.opacity(0.14))
                                    )
                            }
                        }
                        Text(self.subtitleLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !self.capabilityChips.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(self.capabilityChips, id: \.self) { chip in
                                    Text(chip)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .overlay(
                                            Capsule().stroke(
                                                Color.secondary.opacity(0.35),
                                                lineWidth: 0.6
                                            )
                                        )
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    Spacer()
                    self.trailingAccessory
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }

        /// "17.6 MB" when total is unknown; "17.6 MB of 1.39 GB" once
        /// HF has walked the snapshot manifest. "Preparing…" when
        /// nothing has hit disk yet — the manifest walk takes a
        /// second or two before the first byte is fetched.
        static func bytesLabel(completed: Int64, total: Int64?) -> String {
            guard completed > 0 || total != nil else {
                return "Preparing…"
            }
            let completedStr = Self.formatBytes(completed)
            if let total {
                return "\(completedStr) of \(Self.formatBytes(total))"
            }
            return completedStr
        }

        /// "4.85 MB/s" formatted with `ByteCountFormatter`. Returns
        /// `nil` when rate isn't available yet.
        static func rateLabel(_ bytesPerSecond: Double?) -> String? {
            guard let bps = bytesPerSecond, bps > 0 else {
                return nil
            }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useMB, .useKB]
            return "\(formatter.string(fromByteCount: Int64(bps)))/s"
        }

        /// "11 minutes remaining" / "45 seconds remaining" — adapts
        /// the unit to whatever's most readable. Returns `nil`
        /// when we don't have a meaningful ETA yet (no rate, near-
        /// complete, etc.).
        static func etaLabel(_ seconds: TimeInterval?) -> String? {
            guard let seconds, seconds > 5 else {
                return nil
            }
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .short
            formatter.maximumUnitCount = 1
            formatter.allowedUnits = [.hour, .minute, .second]
            guard let str = formatter.string(from: seconds) else {
                return nil
            }
            return "\(str) remaining"
        }

        // MARK: Private

        private var subtitleLine: String {
            "\(self.diskSize) · \(self.variant.recommendedRAMGigabytes)+ GB RAM"
        }

        private var diskSize: String {
            let gb = Double(self.variant.approximateDiskBytes) / 1_000_000_000.0
            if gb >= 1 {
                return String(format: "%.2f GB", gb)
            }
            let mb = Double(self.variant.approximateDiskBytes) / 1_000_000.0
            return String(format: "%.0f MB", mb)
        }

        private var capabilityChips: [String] {
            var chips: [String] = []
            if self.variant.supportsVision {
                chips.append("Vision")
            }
            if self.variant.supportsTools {
                chips.append("Tools")
            }
            return chips
        }

        /// Left-side state icon. Downloads always render an animating
        /// `ProgressView` spinner — never a determinate ring — because
        /// swift-huggingface only reports `Progress.completedUnitCount`
        /// at file-completion boundaries, not per byte. A trim-ring
        /// that sits frozen at the same fraction for minutes reads as
        /// "stuck"; the spinner reads as "still working" and is
        /// honest about the granularity we have.
        @ViewBuilder
        private var leadingAccessory: some View {
            switch self.state {
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            case .notDownloaded:
                Image(systemName: "icloud.and.arrow.down")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .tint(.accentColor)
                    .frame(width: 22, height: 22)
            case .downloaded:
                Image(systemName: self.isActive ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(self.isActive ? Color.accentColor : Color.secondary)
            }
        }

        /// Right-side accessory.
        ///
        /// While downloading, we surface the rich "X GB / Y GB",
        /// "R MB/s", and "N min remaining" combo — same shape as the
        /// reference apps. The bytes + rate come from the live disk
        /// poller in `DownloadCoordinator`, not the SDK's per-file
        /// callback, so they update every second instead of jumping
        /// at file boundaries.
        @ViewBuilder
        private var trailingAccessory: some View {
            switch self.state {
            case let .downloading(snap):
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Self.bytesLabel(completed: snap.completedBytes, total: snap.totalBytes))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let rate = Self.rateLabel(snap.bytesPerSecond) {
                        Text(rate)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let eta = Self.etaLabel(snap.etaSeconds) {
                        Text(eta)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            case .downloaded:
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            default:
                EmptyView()
            }
        }

        private static func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowedUnits = [.useMB, .useGB]
            return formatter.string(fromByteCount: bytes)
        }
    }

    // MARK: - DownloadInProgressBanner

    /// Sticky info card pinned at the top of `ModelFamilyDetail` while
    /// any download is in flight. Warns the user not to background or
    /// lock the app — Avyra uses a standard URLSession for HF model
    /// pulls, and a backgrounded foreground session pauses transfers.
    ///
    /// The coordinator already keeps the screen awake via
    /// `isIdleTimerDisabled`; this banner is the user-facing partner
    /// to that side effect.
    ///
    /// Lists every active download by friendly name so a user with
    /// two pulls in flight knows which one's in trouble if they
    /// background the app anyway.
    struct DownloadInProgressBanner: View {
        // MARK: Internal

        let active: [DownloadCoordinator.ActiveDownload]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(self.headline)
                            .font(.subheadline.weight(.semibold))
                        Text(
                            "Keep Avyra open until it finishes. Backgrounding or locking your phone will pause the download."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if self.active.count <= 3 {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(self.active, id: \.modelId) { snap in
                            self.row(snap: snap)
                        }
                    }
                    .padding(.leading, 30)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
            )
        }

        // MARK: Private

        private var headline: String {
            let n = self.active.count
            return n == 1 ? "Downloading 1 model" : "Downloading \(n) models"
        }

        private func row(snap: DownloadCoordinator.ActiveDownload) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(snap.displayName)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(VariantRow.bytesLabel(
                        completed: snap.completedBytes,
                        total: snap.totalBytes
                    ))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                }
                // Rate + ETA secondary line. Only shown once the
                // disk poller has enough samples to compute them —
                // the line stays hidden for the first ~2 s of a
                // download instead of flashing "—".
                if let detail = Self.detailLine(snap) {
                    Text(detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }

        /// "4.85 MB/s · 11 min remaining" when both are available;
        /// just one of them when only one is; nil while we don't
        /// have enough samples yet.
        private static func detailLine(_ snap: DownloadCoordinator.ActiveDownload) -> String? {
            let rate = VariantRow.rateLabel(snap.bytesPerSecond)
            let eta = VariantRow.etaLabel(snap.etaSeconds)
            return [rate, eta].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
    }
#endif

// MARK: - String niceties

#if canImport(AriaMLX)
    extension String {
        fileprivate var nilIfEmpty: String? {
            self.isEmpty ? nil : self
        }
    }
#endif
