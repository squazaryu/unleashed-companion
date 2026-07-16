import SwiftUI

/// Edit the Home layout: drag to reorder within a group (Edit button), move tiles
/// between groups or hide them via each row's menu, and re-add hidden tiles.
struct CustomizeHomeView: View {
    @ObservedObject private var layout = HomeLayoutStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(HomeGroupID.allCases) { group in
                Section {
                    let tiles = layout.tiles(group)
                    if tiles.isEmpty {
                        Text("Empty — move a tile here from another section.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(tiles) { tile in
                        row(tile, in: group)
                    }
                    .onMove { layout.reorder(group, from: $0, to: $1) }
                } header: {
                    Label(group.name, systemImage: group.systemImage)
                }
            }

            Section {
                if layout.hidden.isEmpty {
                    Text("Nothing hidden — every tile is on your Home screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(layout.hidden) { tile in
                    hiddenRow(tile)
                }
            } header: {
                Label("Hidden", systemImage: "eye.slash")
            } footer: {
                Text("Drag the grip to reorder within a section. Use a tile's menu to move it to another section or hide it. Tabs Home / Screen / Settings stay fixed.")
            }
        }
        .navigationTitle("Customize Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { layout.reset() } label: {
                        Label("Reset to default", systemImage: "arrow.counterclockwise")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func row(_ tile: HomeTileID, in group: HomeGroupID) -> some View {
        HStack(spacing: 12) {
            icon(tile.systemImage, tile.tint)
            Text(tile.title)
            Spacer()
            Menu {
                ForEach(HomeGroupID.allCases.filter { $0 != group }) { g in
                    Button { withAnimation { layout.move(tile, to: g) } } label: {
                        Label("Move to \(g.name)", systemImage: g.systemImage)
                    }
                }
                Divider()
                Button(role: .destructive) { withAnimation { layout.hide(tile) } } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
        }
    }

    private func hiddenRow(_ tile: HomeTileID) -> some View {
        HStack(spacing: 12) {
            icon(tile.systemImage, .secondary)
            Text(tile.title).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(HomeGroupID.allCases) { g in
                    Button { withAnimation { layout.unhide(tile, to: g) } } label: {
                        Label("Add to \(g.name)", systemImage: g.systemImage)
                    }
                }
            } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
            }
        }
    }

    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .foregroundStyle(tint)
            .frame(width: 28, alignment: .center)
    }
}
