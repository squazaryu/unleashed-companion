import Charts
import SwiftUI

struct TumoSpectrumView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @StateObject private var viewModel = TumoSpectrumViewModel()

    var body: some View {
        CardScroll {
            statusCard
            if let report = viewModel.report {
                overviewCard(report)
                histogramCard(report.capture)
                detailsCard(report.capture)
                if let comparison = report.comparison, let compared = report.compared {
                    comparisonCard(comparison, compared: compared)
                }
                reportCard(report)
            } else if let captureSet = viewModel.captureSet {
                captureSetOverviewCard(captureSet)
                if let bitstream = captureSet.inference.bitstream {
                    captureSetBitFieldsCard(captureSet, bitstream: bitstream)
                }
                captureSetInferenceCard(captureSet)
                captureSetSamplesCard(captureSet)
            }
            if !viewModel.reportFiles.isEmpty { recentCard }
        }
        .navigationTitle("TumoSpectrum")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(viewModel.isLoading)
                    .accessibilityLabel("Refresh TumoSpectrum reports")
            }
        }
        .task { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var statusCard: some View {
        SectionCard(
            title: "Signal workspace",
            systemImage: "waveform.path.ecg",
            accessory: AnyView(StatusPill(
                text: viewModel.isLoading ? "Loading" : (viewModel.document == nil ? "Ready" : "Report"),
                color: viewModel.errorMessage == nil ? (viewModel.document == nil ? .secondary : .green) : .red,
                systemImage: viewModel.isLoading ? "arrow.triangle.2.circlepath" : nil
            ))
        ) {
            HStack(spacing: 10) {
                Label(ble.state == .ready ? "Flipper connected" : "Flipper offline",
                      systemImage: ble.state == .ready ? "checkmark.circle.fill" : "bolt.slash.fill")
                Spacer()
                Text(ble.appBridgeV2 ? "Bridge v2" : "No bridge")
            }
            .font(.caption)
            .foregroundStyle(ble.state == .ready ? Color.secondary : Color.orange)

            Text(viewModel.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func overviewCard(_ report: TumoSpectrumReport) -> some View {
        SectionCard(
            title: report.capture.name,
            systemImage: sourceIcon(report.capture.type),
            accessory: AnyView(StatusPill(text: report.capture.type, color: Theme.accent))
        ) {
            HStack {
                statTile(frequency(report.capture.frequencyHz), "frequency")
                statTile("\(report.capture.timings)", "timings")
                statTile("\(report.capture.repeatScore)%", "repeat")
            }
            Divider().opacity(0.35)
            HStack {
                Label(report.capture.protocol, systemImage: "waveform")
                    .lineLimit(1)
                Spacer()
                Text(report.createdAt)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func histogramCard(_ capture: TumoSpectrumReport.Capture) -> some View {
        SectionCard(title: "Pulse histogram", systemImage: "chart.bar.fill") {
            Chart(histogramItems(capture)) { item in
                BarMark(
                    x: .value("Bucket", item.label),
                    y: .value("Share", item.value)
                )
                .foregroundStyle(Theme.accent)
                .cornerRadius(2)
            }
            .frame(height: 150)
            .chartYAxis { AxisMarks(position: .leading) }
            .accessibilityLabel("Pulse duration histogram")

            HStack {
                statTile(duration(capture.minUs), "minimum")
                statTile(duration(capture.avgUs), "average")
                statTile(duration(capture.maxUs), "maximum")
            }
        }
    }

    private func detailsCard(_ capture: TumoSpectrumReport.Capture) -> some View {
        SectionCard(title: "Analysis", systemImage: "scope") {
            detailRow("Candidate", capture.candidate)
            detailRow("Duration", duration(capture.durationUs))
            detailRow("Bursts", "\(capture.bursts)")
            detailRow("Preset", capture.preset)
            if capture.truncated {
                Label("Statistics use a bounded preview of the capture.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !capture.note.isEmpty {
                Divider().opacity(0.35)
                Text(capture.note)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func comparisonCard(
        _ comparison: TumoSpectrumReport.Comparison,
        compared: TumoSpectrumReport.Capture
    ) -> some View {
        SectionCard(
            title: "Comparison",
            systemImage: "square.split.2x1",
            accessory: AnyView(StatusPill(
                text: comparison.likelySame ? "Likely same" : "Different",
                color: comparison.likelySame ? .green : .orange
            ))
        ) {
            HStack {
                statTile("\(comparison.overallSimilarity)%", "overall")
                statTile("\(comparison.histogramSimilarity)%", "histogram")
                statTile(signed(comparison.frequencyDeltaHz, suffix: " Hz"), "frequency Δ")
            }
            Divider().opacity(0.35)
            detailRow("Compared with", compared.name)
            detailRow("Pulse delta", signed(comparison.pulseDelta))
            detailRow("Duration delta", signed(comparison.durationDeltaPercent, suffix: "%"))
        }
    }

    private func reportCard(_ report: TumoSpectrumReport) -> some View {
        SectionCard(title: "Report", systemImage: "doc.text") {
            if let file = viewModel.reportFileName {
                detailRow("File", file)
            }
            Text(report.capture.path)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            ShareLink(item: shareText(report)) {
                Label("Share report", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    private func captureSetOverviewCard(_ report: TumoSpectrumCaptureSetReport) -> some View {
        SectionCard(
            title: report.control,
            systemImage: report.captureType == "SUB RAW" ? "dot.radiowaves.right" : "light.beacon.max.fill",
            accessory: AnyView(StatusPill(text: report.captureType, color: Theme.accent))
        ) {
            detailRow("Device", report.device)
            HStack {
                statTile("\(report.sampleCount)", "captures")
                statTile("\(report.inference.stablePercent)%", "stable")
                statTile("\(report.inference.changingPoints)", "changing")
            }
            Divider().opacity(0.35)
            HStack {
                Label(report.inference.encoding, systemImage: "waveform")
                Spacer()
                Text(report.createdAt)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func captureSetInferenceCard(_ report: TumoSpectrumCaptureSetReport) -> some View {
        SectionCard(
            title: "Timing inference",
            systemImage: "chart.xyaxis.line",
            accessory: AnyView(StatusPill(
                text: report.inference.replayClass,
                color: report.inference.replayClass == "Static-like" ? .green : .orange
            ))
        ) {
            Chart(stabilityItems(report)) { item in
                BarMark(
                    x: .value("Region", item.label),
                    y: .value("Timing points", item.value)
                )
                .foregroundStyle(item.color)
                .cornerRadius(3)
            }
            .frame(height: 130)
            .chartYAxis { AxisMarks(position: .leading) }
            .accessibilityLabel("Stable and changing timing points")

            Divider().opacity(0.35)
            detailRow("Aligned points", "\(report.inference.alignedPoints)")
            detailRow("Observed frames", "\(report.inference.frames)")
            detailRow(
                "Timing clusters",
                report.inference.clustersUs.map { duration($0) }.joined(separator: " · ")
            )

            Label(
                "Static-like describes timing similarity only. It does not prove that a signal is safe or valid to replay.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func captureSetBitFieldsCard(
        _ report: TumoSpectrumCaptureSetReport,
        bitstream: TumoSpectrumCaptureSetReport.Inference.Bitstream
    ) -> some View {
        let fields = report.inference.fields ?? []
        let counter = report.inference.counter
        let checksum = report.inference.checksum
        let columns = Array(repeating: GridItem(.flexible(minimum: 12), spacing: 3), count: 16)

        return SectionCard(
            title: "Candidate bit fields",
            systemImage: "square.grid.3x3.fill",
            accessory: AnyView(StatusPill(
                text: bitstream.bitCount == 0 ? "No bits" : "\(bitstream.bitCount) bits",
                color: bitstream.bitCount == 0 ? .secondary : Theme.accent
            ))
        ) {
            if bitstream.bitCount > 0 {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(bitstream.pattern.enumerated()), id: \.offset) { index, value in
                        Text(String(value))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(bitForeground(value))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .background(bitColor(value), in: RoundedRectangle(cornerRadius: 3))
                            .accessibilityLabel("Bit \(index), \(bitMeaning(value))")
                    }
                }

                HStack {
                    statTile("\(bitstream.stableBits)", "stable")
                    statTile("\(bitstream.changingBits)", "changing")
                    statTile("\(bitstream.unknownBits)", "unknown")
                }
            } else {
                Label("This timing family has no conservative bit decode yet.", systemImage: "questionmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !fields.isEmpty {
                Divider().opacity(0.35)
                ForEach(fields) { field in
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(fieldColor(field.kind))
                            .frame(width: 4, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(field.kind.capitalized)
                            Text("bits \(field.start)...\(field.start + field.length - 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(field.length) bit\(field.length == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider().opacity(0.35)
            if let counter, counter.found {
                detailRow(
                    "Counter candidate",
                    "\(counter.direction), bits \(counter.start)...\(counter.start + counter.length - 1)"
                )
            } else {
                detailRow("Counter candidate", "Not found")
            }
            if let checksum, !checksum.candidates.isEmpty {
                detailRow("Checksum candidates", checksum.candidates.joined(separator: " · ").uppercased())
            } else {
                detailRow("Checksum candidates", "Not found")
            }
            detailRow(
                "Stock handoff",
                report.inference.replayClass == "Static-like" ? "Available on Flipper" : "Disabled for changing signal"
            )

            Label(
                "Fields are bounded candidates derived from the selected captures, not a confirmed protocol definition.",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func captureSetSamplesCard(_ report: TumoSpectrumCaptureSetReport) -> some View {
        SectionCard(title: "Capture set", systemImage: "square.stack.3d.up") {
            ForEach(Array(report.samples.enumerated()), id: \.offset) { index, sample in
                if index > 0 { Divider().opacity(0.35) }
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.plus")
                        .foregroundStyle(Theme.accent)
                    Text(sample)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("#\(index + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let file = viewModel.reportFileName {
                Divider().opacity(0.35)
                detailRow("Report", file)
            }

            ShareLink(item: shareText(report)) {
                Label("Share inference report", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    private var recentCard: some View {
        SectionCard(title: "Recent reports", systemImage: "clock.arrow.circlepath") {
            ForEach(Array(viewModel.reportFiles.enumerated()), id: \.element.id) { index, file in
                if index > 0 { Divider().opacity(0.35) }
                Button { viewModel.open(fileName: file.name) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: file.name.hasPrefix("set_") ? "square.stack.3d.up" : "waveform.path.ecg")
                            .foregroundStyle(Theme.accent)
                        Text(file.name)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func histogramItems(_ capture: TumoSpectrumReport.Capture) -> [HistogramItem] {
        capture.histogram.enumerated().map { HistogramItem(index: $0.offset, value: $0.element) }
    }

    private func stabilityItems(_ report: TumoSpectrumCaptureSetReport) -> [StabilityItem] {
        [
            StabilityItem(label: "Stable", value: report.inference.stablePoints, color: .green),
            StabilityItem(label: "Changing", value: report.inference.changingPoints, color: .orange)
        ]
    }

    private func bitColor(_ value: Character) -> Color {
        switch value {
        case "*": return .orange.opacity(0.24)
        case "?": return Color.secondary.opacity(0.16)
        default: return .green.opacity(0.20)
        }
    }

    private func bitForeground(_ value: Character) -> Color {
        switch value {
        case "*": return .orange
        case "?": return .secondary
        default: return .green
        }
    }

    private func bitMeaning(_ value: Character) -> String {
        switch value {
        case "*": return "changing"
        case "?": return "unknown"
        default: return "stable \(value)"
        }
    }

    private func fieldColor(_ kind: String) -> Color {
        switch kind {
        case "changing": return .orange
        case "unknown": return .secondary
        default: return .green
        }
    }

    private func sourceIcon(_ type: String) -> String {
        if type.hasPrefix("SUB") { return "dot.radiowaves.right" }
        if type.hasPrefix("IR") { return "light.beacon.max.fill" }
        if type == "GPIO CAPTURE" { return "waveform.path" }
        return "waveform.badge.magnifyingglass"
    }

    private func frequency(_ hz: UInt64) -> String {
        if hz >= 1_000_000 { return String(format: "%.3f MHz", Double(hz) / 1_000_000) }
        if hz >= 1_000 { return String(format: "%.1f kHz", Double(hz) / 1_000) }
        return "\(hz) Hz"
    }

    private func duration(_ microseconds: UInt64) -> String {
        if microseconds >= 1_000_000 { return String(format: "%.2f s", Double(microseconds) / 1_000_000) }
        if microseconds >= 1_000 { return String(format: "%.2f ms", Double(microseconds) / 1_000) }
        return "\(microseconds) µs"
    }

    private func signed(_ value: Int64, suffix: String = "") -> String {
        "\(value >= 0 ? "+" : "")\(value)\(suffix)"
    }

    private func shareText(_ report: TumoSpectrumReport) -> String {
        var lines = [
            "TumoSpectrum \(report.version)",
            "Capture: \(report.capture.name)",
            "Type: \(report.capture.type)",
            "Frequency: \(frequency(report.capture.frequencyHz))",
            "Protocol: \(report.capture.protocol)",
            "Timings: \(report.capture.timings)",
            "Duration: \(duration(report.capture.durationUs))",
            "Bursts: \(report.capture.bursts)",
            "Repeat score: \(report.capture.repeatScore)%",
            "Candidate: \(report.capture.candidate)"
        ]
        if !report.capture.note.isEmpty { lines.append("Note: \(report.capture.note)") }
        if let comparison = report.comparison {
            lines.append("Similarity: \(comparison.overallSimilarity)%")
        }
        return lines.joined(separator: "\n")
    }

    private func shareText(_ report: TumoSpectrumCaptureSetReport) -> String {
        var lines = [
            "TumoSpectrum \(report.version)",
            "Device: \(report.device)",
            "Control: \(report.control)",
            "Type: \(report.captureType)",
            "Captures: \(report.sampleCount)",
            "Encoding: \(report.inference.encoding)",
            "Classification: \(report.inference.replayClass)",
            "Stable: \(report.inference.stablePercent)%",
            "Timing clusters: \(report.inference.clustersUs.map { duration($0) }.joined(separator: ", "))"
        ]
        if let bitstream = report.inference.bitstream {
            lines.append("Candidate bits: \(bitstream.reference)")
            lines.append("Field pattern: \(bitstream.pattern)")
        }
        if let counter = report.inference.counter, counter.found {
            lines.append("Counter candidate: \(counter.direction) [\(counter.start):\(counter.length)]")
        }
        if let checksum = report.inference.checksum, !checksum.candidates.isEmpty {
            lines.append("Checksum candidates: \(checksum.candidates.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

private struct HistogramItem: Identifiable {
    let index: Int
    let value: Int
    var id: Int { index }
    var label: String { "\(index + 1)" }
}

private struct StabilityItem: Identifiable {
    let label: String
    let value: Int
    let color: Color
    var id: String { label }
}
