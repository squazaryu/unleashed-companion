import SwiftUI
import UIKit

struct DolphinGalleryView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @StateObject private var model = DolphinGalleryModel()
    @State private var expandedLibrarySources: Set<DolphinLibrarySource> = []
    @State private var confirmsReset = false

    var body: some View {
        CardScroll {
            profileCard
            libraryCard
            collectionsCard
        }
        .navigationTitle("Dolphin Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.refreshPackStates()
            if ble.state == .ready {
                await model.loadFromDevice()
            }
        }
    }

    private var libraryCard: some View {
        SectionCard(title: "Animation library", systemImage: "photo.stack") {
            ForEach(DolphinLibrarySource.allCases) { source in
                if source != .legacy {
                    Divider().opacity(0.4)
                }
                librarySource(source)
            }
        }
    }

    @ViewBuilder
    private func librarySource(_ source: DolphinLibrarySource) -> some View {
        if source == .legacy {
            libraryDisclosure(source: source, count: DolphinCatalog.legacy.count) {
                LazyVGrid(columns: libraryColumns, spacing: 10) {
                    ForEach(DolphinCatalog.legacy) { animation in
                        DolphinLibraryTile(
                            animation: animation,
                            subtitle: "TumoFlip",
                            state: .builtIn
                        )
                    }
                }
            }
        } else {
            let packs = DolphinPackCatalog.packs(for: source)
            libraryDisclosure(
                source: source,
                count: packs.filter { model.cachedPackIDs.contains($0.id) }.count,
                total: packs.count
            ) {
                packGrid(packs)
                if let repository = DolphinPackCatalog.repository(for: source) {
                    Link(destination: repository) {
                        Label("\(source.rawValue) source", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var libraryColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]
    }

    private func libraryDisclosure<Content: View>(
        source: DolphinLibrarySource,
        count: Int,
        total: Int? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DolphinCollapsibleSection(isExpanded: expansionBinding(for: source)) {
            HStack(spacing: 10) {
                Image(systemName: source.systemImage)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                Text(source.rawValue)
                    .fontWeight(.semibold)
                Spacer()
                Text(total.map { "\(count)/\($0)" } ?? "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.top, 10)
        }
    }

    private func expansionBinding(for source: DolphinLibrarySource) -> Binding<Bool> {
        Binding(
            get: { expandedLibrarySources.contains(source) },
            set: { expanded in
                if expanded {
                    expandedLibrarySources.insert(source)
                } else {
                    expandedLibrarySources.remove(source)
                }
            }
        )
    }

    private func packGrid(_ packs: [DolphinPackDescriptor]) -> some View {
        LazyVGrid(columns: libraryColumns, spacing: 10) {
            ForEach(packs) { pack in
                DolphinLibraryTile(
                    animation: pack.animation,
                    subtitle: pack.author,
                    state: .download(model.packPhase(pack))
                ) {
                    Task { await model.download(pack) }
                }
            }
        }
    }

    private var profileCard: some View {
        SectionCard(title: "Desktop profile", systemImage: "sparkles.rectangle.stack") {
            Toggle("Use collection", isOn: $model.enabled)
                .tint(Theme.accent)

            Divider().opacity(0.4)

            LabeledContent("Collection") {
                Picker("Collection", selection: $model.activeCollectionID) {
                    ForEach(model.availableCollections) { collection in
                        Text(collection.name).tag(collection.id)
                    }
                }
                .labelsHidden()
            }

            Picker("Order", selection: $model.order) {
                ForEach(DolphinProfileOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)

            Picker("Timing", selection: $model.timing) {
                ForEach(DolphinProfileTiming.allCases) { timing in
                    Text(timing.label).tag(timing)
                }
            }
            .pickerStyle(.segmented)

            if model.timing == .custom {
                NavigationLink {
                    DolphinDurationEditor(seconds: $model.durationSeconds)
                } label: {
                    LabeledContent("Duration") {
                        Text(durationLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                Task { await model.apply() }
            } label: {
                HStack {
                    if model.phase == .applying {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "iphone.and.arrow.forward")
                    }
                    Text(model.enabled ? "Apply to Flipper" : "Disable on Flipper")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(ble.state != .ready || model.isBusy || !model.canApply)

            if let progress = model.transferProgress {
                transferProgressView(progress)
            }

            Button {
                confirmsReset = true
            } label: {
                Label("Reset to original", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(ble.state != .ready || model.isBusy)
            .confirmationDialog(
                "Reset wallpaper settings?",
                isPresented: $confirmsReset,
                titleVisibility: .visible
            ) {
                Button("Reset to original", role: .destructive) {
                    Task { await model.resetToOriginal() }
                }
                Button("Cancel", role: .cancel) {}
            }

            statusRow
        }
    }

    private var collectionsCard: some View {
        SectionCard(title: "Collections", systemImage: "square.stack.3d.up") {
            ForEach(model.availableCollections) { collection in
                HStack(spacing: 12) {
                    Button {
                        model.selectCollection(collection.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.activeCollectionID == collection.id
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.activeCollectionID == collection.id
                                                 ? Theme.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(collection.name)
                                    .foregroundStyle(.primary)
                                Text("\(collection.animationIDs.count) animations")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    if collection.id != DolphinGalleryModel.allCollectionID {
                        NavigationLink {
                            DolphinCollectionEditor(
                                collection: collection,
                                animations: model.availableAnimations
                            ) {
                                model.upsert($0)
                            }
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("Edit \(collection.name)")

                        Button(role: .destructive) {
                            model.deleteCollection(collection.id)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("Delete \(collection.name)")
                    }
                }
                if collection.id != model.availableCollections.last?.id {
                    Divider().opacity(0.4)
                }
            }

            NavigationLink {
                DolphinCollectionEditor(
                    collection: nil,
                    animations: model.availableAnimations
                ) {
                    model.upsert($0)
                }
            } label: {
                Label("New collection", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.phase {
        case .idle:
            HStack {
                Circle()
                    .fill(ble.state == .ready ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(ble.state == .ready ? "Flipper connected" : "Connect Flipper to apply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if ble.state == .ready {
                    Button {
                        Task { await model.loadFromDevice() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Reload profile from Flipper")
                }
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Reading profile")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .applying:
            EmptyView()
        case .applied:
            Label("Profile applied", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var durationLabel: String {
        let hours = model.durationSeconds / 3_600
        let minutes = (model.durationSeconds % 3_600) / 60
        let seconds = model.durationSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func transferProgressView(_ progress: DolphinPackSyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: transferIcon(progress.stage))
                    .foregroundStyle(Theme.accent)
                Text(transferTitle(progress.stage))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if progress.total > 0 {
                    Text("\(min(progress.completed, progress.total))/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if progress.total > 0 {
                ProgressView(
                    value: Double(min(progress.completed, progress.total)),
                    total: Double(progress.total)
                )
                .tint(Theme.accent)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }

            if let item = progress.item, !item.isEmpty {
                Text(item)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func transferTitle(_ stage: DolphinPackSyncStage) -> String {
        switch stage {
        case .caching: return "Preparing on iPhone"
        case .uploading: return "Uploading to Flipper"
        case .removing: return "Removing from Flipper"
        case .profile: return "Applying profile"
        }
    }

    private func transferIcon(_ stage: DolphinPackSyncStage) -> String {
        switch stage {
        case .caching: return "iphone.and.arrow.down"
        case .uploading: return "iphone.and.arrow.forward"
        case .removing: return "trash"
        case .profile: return "checkmark.rectangle.stack"
        }
    }
}

private struct DolphinCollectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let originalID: UUID
    private let animations: [DolphinAnimation]
    private let onSave: (DolphinCollection) -> Void

    @State private var name: String
    @State private var selection: Set<String>
    @State private var expandedSources: Set<DolphinLibrarySource> = []
    @State private var searchText = ""

    init(
        collection: DolphinCollection?,
        animations: [DolphinAnimation],
        onSave: @escaping (DolphinCollection) -> Void
    ) {
        originalID = collection?.id ?? UUID()
        self.animations = animations
        self.onSave = onSave
        _name = State(initialValue: collection?.name ?? "")
        _selection = State(initialValue: Set(collection?.animationIDs ?? []))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                TextField("Collection name", text: $name)
                    .textInputAutocapitalization(.words)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button {
                        selection = Set(animations.map(\.id))
                    } label: {
                        Label("Select all wallpapers", systemImage: "checkmark.circle")
                    }
                    Spacer()
                    Button {
                        selection.removeAll()
                    } label: {
                        Label("Clear all", systemImage: "xmark.circle")
                    }
                }
                .font(.subheadline)

                VStack(spacing: 10) {
                    ForEach(DolphinLibrarySource.allCases) { source in
                        animationDisclosure(source)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Collection")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search wallpapers")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let orderedIDs = animations
                        .map(\.id)
                        .filter(selection.contains)
                    onSave(DolphinCollection(
                        id: originalID,
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        animationIDs: orderedIDs
                    ))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selection.isEmpty)
            }
        }
    }

    private func animationDisclosure(_ source: DolphinLibrarySource) -> some View {
        let sourceAnimations = animations.filter { $0.source == source }
        let visibleAnimations = sourceAnimations.filter {
            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)
        }
        let sourceIDs = Set(sourceAnimations.map(\.id))
        let allSourceSelected = !sourceIDs.isEmpty && sourceIDs.isSubset(of: selection)
        return DolphinCollapsibleSection(isExpanded: expansionBinding(for: source)) {
            HStack {
                Label(source.rawValue, systemImage: source.systemImage)
                Spacer()
                Text("\(selection.intersection(sourceAnimations.map(\.id)).count)/\(sourceAnimations.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } content: {
            if sourceAnimations.isEmpty {
                Label("No animations", systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                HStack {
                    Text("\(sourceAnimations.count) wallpapers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if allSourceSelected {
                            selection.subtract(sourceIDs)
                        } else {
                            selection.formUnion(sourceIDs)
                        }
                    } label: {
                        Label(
                            allSourceSelected ? "Clear" : "Select all",
                            systemImage: allSourceSelected ? "xmark.circle" : "checkmark.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 10)

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ], spacing: 10) {
                    ForEach(visibleAnimations) { animation in
                        DolphinAnimationTile(
                            animation: animation,
                            selected: selection.contains(animation.id)
                        ) {
                            if selection.contains(animation.id) {
                                selection.remove(animation.id)
                            } else {
                                selection.insert(animation.id)
                            }
                        }
                    }
                }

                if visibleAnimations.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func expansionBinding(for source: DolphinLibrarySource) -> Binding<Bool> {
        Binding(
            get: { expandedSources.contains(source) },
            set: { expanded in
                if expanded {
                    expandedSources.insert(source)
                } else {
                    expandedSources.remove(source)
                }
            }
        )
    }
}

private struct DolphinLibraryTile: View {
    enum State {
        case builtIn
        case download(DolphinGalleryModel.PackPhase)
    }

    let animation: DolphinAnimation
    let subtitle: String
    let state: State
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.white
                DolphinAnimationArtwork(animation: animation)
            }
            .aspectRatio(2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(animation.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            stateView
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch state {
        case .builtIn:
            Label("Built in", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .download(let phase):
            switch phase {
            case .checking, .downloading:
                HStack(spacing: 7) {
                    ProgressView()
                    Text(phase == .checking ? "Checking" : "Downloading")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .downloaded:
                Label("On iPhone", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .unknown, .notDownloaded, .failed:
                Button {
                    action?()
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Download \(animation.title) to iPhone")
            }
        }
    }
}

private struct DolphinAnimationArtwork: View {
    let animation: DolphinAnimation

    @ViewBuilder
    var body: some View {
        if let asset = animation.previewAsset {
            Image(asset)
                .renderingMode(.original)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .padding(4)
        } else if let preview = bundledPreview {
            Image(uiImage: preview)
                .renderingMode(.original)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .padding(4)
        } else if let url = animation.previewURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(4)
                } else if phase.error != nil {
                    placeholder
                } else {
                    ProgressView()
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: "rectangle.on.rectangle.angled")
            .font(.title2)
            .foregroundStyle(.secondary)
    }

    private var bundledPreview: UIImage? {
        guard let url = Bundle.main.url(
            forResource: animation.id,
            withExtension: "png",
            subdirectory: "DolphinPreviews"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

private struct DolphinCollapsibleSection<Label: View, Content: View>: View {
    @Binding private var isExpanded: Bool
    private let label: Label
    private let content: Content

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder label: () -> Label,
        @ViewBuilder content: () -> Content
    ) {
        _isExpanded = isExpanded
        self.label = label()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    label
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
        .clipped()
        .animation(nil, value: isExpanded)
    }
}

private struct DolphinAnimationTile: View {
    let animation: DolphinAnimation
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Color.white
                    DolphinAnimationArtwork(animation: animation)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(selected ? .white : .secondary, selected ? Theme.accent : .white)
                        .padding(6)
                }
                .aspectRatio(2, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(animation.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Theme.accent : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(animation.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct DolphinDurationEditor: View {
    @Binding var seconds: Int
    @State private var secondsText: String
    @FocusState private var secondsFieldFocused: Bool

    init(seconds: Binding<Int>) {
        _seconds = seconds
        _secondsText = State(initialValue: String(seconds.wrappedValue))
    }

    var body: some View {
        CardScroll {
            SectionCard(title: "Duration", systemImage: "timer") {
                HStack(spacing: 0) {
                    wheel(title: "Hours", range: 0...23, value: hoursBinding)
                    wheel(title: "Minutes", range: 0...59, value: minutesBinding)
                    wheel(title: "Seconds", range: 0...59, value: secondsBinding)
                }
                .frame(height: 170)
            }

            SectionCard(title: "Total seconds", systemImage: "number") {
                HStack {
                    TextField("Seconds", text: $secondsText)
                        .keyboardType(.numberPad)
                        .focused($secondsFieldFocused)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        commitTextValue()
                    } label: {
                        Image(systemName: "checkmark")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Apply seconds")
                }
            }
        }
        .navigationTitle("Animation duration")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    commitTextValue()
                    secondsFieldFocused = false
                }
            }
        }
        .onChange(of: seconds) { _, value in
            if !secondsFieldFocused {
                secondsText = String(value)
            }
        }
    }

    private func wheel(
        title: String,
        range: ClosedRange<Int>,
        value: Binding<Int>
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(title, selection: value) {
                ForEach(range, id: \.self) { value in
                    Text(String(format: "%02d", value)).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { seconds / 3_600 },
            set: { update(hours: $0, minutes: minutesBinding.wrappedValue, seconds: secondsBinding.wrappedValue) }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { (seconds % 3_600) / 60 },
            set: { update(hours: hoursBinding.wrappedValue, minutes: $0, seconds: secondsBinding.wrappedValue) }
        )
    }

    private var secondsBinding: Binding<Int> {
        Binding(
            get: { seconds % 60 },
            set: { update(hours: hoursBinding.wrappedValue, minutes: minutesBinding.wrappedValue, seconds: $0) }
        )
    }

    private func update(hours: Int, minutes: Int, seconds componentSeconds: Int) {
        let total = hours * 3_600 + minutes * 60 + componentSeconds
        seconds = min(
            DolphinDesktopProfile.maximumDuration,
            max(DolphinDesktopProfile.minimumDuration, total)
        )
    }

    private func commitTextValue() {
        guard let value = Int(secondsText) else {
            secondsText = String(seconds)
            return
        }
        seconds = min(
            DolphinDesktopProfile.maximumDuration,
            max(DolphinDesktopProfile.minimumDuration, value)
        )
        secondsText = String(seconds)
    }
}
