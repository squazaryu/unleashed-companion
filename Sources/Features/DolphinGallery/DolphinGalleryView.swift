import SwiftUI

struct DolphinGalleryView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @StateObject private var model = DolphinGalleryModel()

    var body: some View {
        CardScroll {
            profileCard
            collectionsCard
        }
        .navigationTitle("Dolphin Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if ble.state == .ready {
                await model.loadFromDevice()
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
                            DolphinCollectionEditor(collection: collection) {
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
                DolphinCollectionEditor(collection: nil) {
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
}

private struct DolphinCollectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let originalID: UUID
    private let onSave: (DolphinCollection) -> Void

    @State private var name: String
    @State private var selection: Set<String>

    init(collection: DolphinCollection?, onSave: @escaping (DolphinCollection) -> Void) {
        originalID = collection?.id ?? UUID()
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
                        selection = Set(DolphinCatalog.animations.map(\.id))
                    } label: {
                        Label("Select all", systemImage: "checkmark.circle")
                    }
                    Spacer()
                    Button {
                        selection.removeAll()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                }
                .font(.subheadline)

                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ], spacing: 10) {
                    ForEach(DolphinCatalog.animations) { animation in
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
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Collection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let orderedIDs = DolphinCatalog.animations
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
                    Image(animation.previewAsset)
                        .renderingMode(.original)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .padding(4)
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
        .onChange(of: seconds) { value in
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
