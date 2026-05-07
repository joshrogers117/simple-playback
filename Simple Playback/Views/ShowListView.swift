import SwiftUI
import UniformTypeIdentifiers

/// Operator-facing view of a single Show List. Shows the ordered cue list with the playhead
/// and live indicator, exposes GO / PREV / PANIC verbs, and supports drag-from-palette to
/// add cues that reference asset slides by ID.
struct ShowListView: View {
    @ObservedObject var showController: ShowController
    @Binding var project: PlayoutProject
    /// Currently selected cue in the list (separate from the playhead — selection is the
    /// editor's cursor, playhead is what fires next).
    @Binding var selectedCueID: UUID?

    @State private var dropTargeted = false

    private var activeListIndex: Int? {
        guard let id = project.activeShowListID else { return nil }
        return project.showLists.firstIndex(where: { $0.id == id })
    }

    private var activeListBinding: Binding<ShowList>? {
        guard let idx = activeListIndex else { return nil }
        return $project.showLists[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if showController.activeShowList.cues.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()

            transportBar
        }
        .frame(minWidth: 320)
        .background(.ultraThinMaterial)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.number")
                .foregroundStyle(.secondary)
            Text(showController.activeShowList.name)
                .font(.headline)
            Spacer()
            if showController.showMode {
                Label("SHOW MODE", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Show list is empty")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Drag a clip from the library, or generate a list from your imported media.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
            if !project.slides.isEmpty {
                Button {
                    generateFromLibrary()
                } label: {
                    Label("Generate from Library", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(showController.showMode)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [UTType.text.identifier], isTargeted: $dropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedCueID) {
                ForEach(showController.activeShowList.cues) { cue in
                    ShowListRow(
                        cue: cue,
                        standbyState: showController.standbyState(of: cue.id),
                        isPlayhead: showController.playheadCue?.id == cue.id,
                        isLive: showController.liveCueID == cue.id,
                        assetTitle: project.slides.first(where: { $0.id == cue.assetID })?.title
                    )
                    .tag(cue.id)
                    .listRowSeparator(.visible)
                }
                .onMove { indices, newOffset in
                    guard !showController.showMode else { return }
                    moveCues(from: indices, to: newOffset)
                }
                .onDelete { indices in
                    guard !showController.showMode else { return }
                    deleteCues(at: indices)
                }
            }
            .listStyle(.plain)
            .onChange(of: showController.playheadCue?.id) { _, newID in
                if let newID {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
            .onDrop(of: [UTType.text.identifier], isTargeted: $dropTargeted) { providers in
                handleDrop(providers: providers)
            }
        }
    }

    private var transportBar: some View {
        HStack(spacing: 8) {
            Button {
                showController.previous()
            } label: {
                Label("Previous", systemImage: "backward.end.fill")
                    .labelStyle(.iconOnly)
            }
            .help("Step playhead back (no fire)")
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(showController.activeShowList.cues.isEmpty)

            Button {
                showController.go()
            } label: {
                Label("GO", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(showController.panicActive ? .gray : .green)
            .help("Fire the cue at the playhead")
            .keyboardShortcut(.space, modifiers: [])
            .disabled(showController.panicActive || showController.activeShowList.cues.isEmpty)

            Button {
                showController.panic()
            } label: {
                Label("Panic", systemImage: "exclamationmark.octagon.fill")
            }
            .tint(.red)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Fade everything to black")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Mutation helpers

    private func generateFromLibrary() {
        guard !project.slides.isEmpty else { return }
        if let idx = activeListIndex {
            let cues = project.slides.enumerated().map { index, slide in
                Cue(number: "\(index + 1)", title: slide.title, assetID: slide.id)
            }
            project.showLists[idx].cues = cues
            if project.showLists[idx].playheadCueID == nil {
                project.showLists[idx].playheadCueID = cues.first?.id
            }
        } else {
            project.generateDefaultShowList()
        }
        if let active = project.activeShowList {
            showController.setActiveShowList(active)
        }
    }

    private func moveCues(from source: IndexSet, to destination: Int) {
        guard let binding = activeListBinding else { return }
        binding.wrappedValue.cues.move(fromOffsets: source, toOffset: destination)
        showController.syncShowListFromProject(binding.wrappedValue)
    }

    private func deleteCues(at indices: IndexSet) {
        guard let binding = activeListBinding else { return }
        for idx in indices.sorted(by: >) {
            binding.wrappedValue.remove(at: idx)
        }
        showController.syncShowListFromProject(binding.wrappedValue)
    }

    // MARK: - Drop handling (assets dragged from the palette)

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var didAccept = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
                let text: String?
                if let s = item as? String {
                    text = s
                } else if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = nil
                }
                guard let text, let assetID = UUID(uuidString: text) else { return }
                DispatchQueue.main.async {
                    self.appendCue(forAssetID: assetID)
                }
            }
            didAccept = true
        }
        return didAccept
    }

    private func appendCue(forAssetID assetID: UUID) {
        guard !showController.showMode else { return }
        guard let binding = activeListBinding else { return }
        guard let asset = project.slides.first(where: { $0.id == assetID }) else { return }
        let nextNumber = nextAvailableCueNumber(in: binding.wrappedValue)
        let cue = Cue(number: nextNumber, title: asset.title, assetID: assetID)
        do {
            try binding.wrappedValue.append(cue)
            showController.syncShowListFromProject(binding.wrappedValue)
        } catch {
            // Duplicate cue number is the only realistic failure mode given UUID asset linkage;
            // fall back to a UUID-suffixed number.
            let unique = "\(nextNumber)-\(UUID().uuidString.prefix(4))"
            let fallbackCue = Cue(number: unique, title: asset.title, assetID: assetID)
            try? binding.wrappedValue.append(fallbackCue)
            showController.syncShowListFromProject(binding.wrappedValue)
        }
    }

    private func nextAvailableCueNumber(in list: ShowList) -> String {
        var n = list.cues.count + 1
        while list.cue(number: "\(n)") != nil {
            n += 1
        }
        return "\(n)"
    }
}

private struct ShowListRow: View {
    let cue: Cue
    let standbyState: CueStandbyState
    let isPlayhead: Bool
    let isLive: Bool
    let assetTitle: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(cue.number)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(width: 60, alignment: .leading)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(cue.title.isEmpty ? (assetTitle ?? "Untitled") : cue.title)
                    .font(.body)
                    .lineLimit(1)
                if !cue.notes.isEmpty {
                    Text(cue.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            continuationBadge

            stateBadge
        }
        .padding(.vertical, 4)
        .listRowBackground(rowBackground)
    }

    private var rowBackground: some View {
        if isLive {
            Color.red.opacity(0.18)
        } else if isPlayhead {
            Color.blue.opacity(0.16)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var continuationBadge: some View {
        switch cue.continuation {
        case .hold:
            EmptyView()
        case .autoContinue:
            Image(systemName: "arrowshape.turn.up.right.fill")
                .foregroundStyle(.secondary)
                .help("Auto-continue: chains immediately to next cue")
        case .autoFollow:
            Image(systemName: "arrow.down.right.circle.fill")
                .foregroundStyle(.secondary)
                .help("Auto-follow: fires next cue after this one ends")
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch standbyState {
        case .idle:
            EmptyView()
        case .loaded:
            Label("Loaded", systemImage: "circle.dotted")
                .labelStyle(.iconOnly)
                .foregroundStyle(.blue)
        case .running:
            Label("Live", systemImage: "play.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 4))
        case .tail:
            Label("Tail", systemImage: "waveform")
                .labelStyle(.iconOnly)
                .foregroundStyle(.orange)
        }
    }
}
