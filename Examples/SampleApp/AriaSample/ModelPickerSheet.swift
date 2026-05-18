import AriaApple
import SwiftUI

#if canImport(AriaMLX)
    import AriaMLX
#endif

// MARK: - ModelPickerSheet

/// In-chat model picker — tap the model pill in the header to swap
/// providers without leaving the conversation.
///
/// Lists:
///   - FoundationModels (always available on iOS 26+ devices that ship
///     with Apple Intelligence). Default if nothing else is picked.
///   - All MLX models the user has downloaded via the MLX Models view.
///     Tapping one activates it for the chat agent on the next turn.
///
/// Selection persists via `MLXModelManager.persistenceKey` so the
/// choice survives relaunch.
struct ModelPickerSheet: View {
    // MARK: Lifecycle

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.appState = appState
        self.onClose = onClose
    }

    // MARK: Internal

    var body: some View {
        NavigationStack {
            Form {
                self.foundationModelsSection
                #if canImport(AriaMLX)
                    self.mlxModelsSection
                #endif
                self.aboutSection
            }
            .navigationTitle("Pick a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: self.onClose)
                }
            }
        }
    }

    // MARK: Private

    @Bindable private var appState: AppState
    private let onClose: () -> Void

    private var foundationModelsSection: some View {
        Section {
            self.row(
                title: "FoundationModels",
                subtitle: "On-device 3B · always available",
                systemImage: "cpu",
                isActive: !self.hasActiveMLXModel
            ) {
                #if canImport(AriaMLX)
                    self.appState.modelManager.setActiveModel(id: nil)
                #endif
                self.onClose()
            }
        } header: {
            Text("Built-in")
        }
    }

    private var hasActiveMLXModel: Bool {
        #if canImport(AriaMLX)
            return self.appState.modelManager.activeCapabilities != nil
        #else
            return false
        #endif
    }

    #if canImport(AriaMLX)
        @ViewBuilder
        private var mlxModelsSection: some View {
            let installed = self.installedMLXEntries()
            if installed.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "tray")
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No MLX models installed")
                                .font(.subheadline)
                            Text("Open Settings → MLX models to download one.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("MLX")
                }
            } else {
                Section {
                    ForEach(installed, id: \.id) { entry in
                        self.row(
                            title: entry.displayName,
                            subtitle: entry.supportsVision ? "Vision · tool-free" : "Text",
                            systemImage: "shippingbox",
                            isActive: self.appState.modelManager.activeCapabilities?.id == entry.id
                        ) {
                            self.appState.modelManager.setActiveModel(id: entry.id)
                            self.onClose()
                        }
                    }
                } header: {
                    Text("MLX")
                } footer: {
                    Text("MLX models run fully on-device. Vision-capable models advertise " +
                        "`supportsVision: true`; tool-calling is disabled on vision-only models.")
                }
            }
        }

        /// Catalog entries that have been downloaded to disk. `isDownloaded`
        /// throws on disk-walk failures; treating a throw as "not installed"
        /// is correct here — if disk is unreadable we shouldn't claim to
        /// have models.
        private func installedMLXEntries() -> [MLXModelCapabilities] {
            self.appState.modelManager.catalog.filter { entry in
                (try? self.appState.modelManager.isDownloaded(id: entry.id)) == true
            }
        }
    #endif

    private var aboutSection: some View {
        Section {
            Link(destination: URL(string: "https://ml-explore.github.io/mlx/")!) {
                Label("About MLX", systemImage: "info.circle")
            }
        }
    }

    @ViewBuilder
    private func row(
        title: String,
        subtitle: String,
        systemImage: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

