import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: EditorViewModel
    @State private var keyMonitor: Any?
    @State private var isDropTargeted = false
    @State private var showingSecondaryShortcuts = false
    @State private var sidebarDropTarget: SidebarLayerDropTarget?
    @State private var sidebarFileDropTarget: SidebarFileDropTarget?
    @State private var sidebarRecordDropTarget: UUID?
    @State private var emptyStateAnimationRestartToken = 0

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1000, minHeight: 680)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted, perform: handleDrop)
        .overlay {
            if isDropTargeted && sidebarRecordDropTarget == nil {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                    .padding(18)
            }
        }
        .onAppear {
            installKeyboardMonitorIfNeeded()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { newValue in
                    if !newValue {
                        viewModel.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private func installKeyboardMonitorIfNeeded() {
        guard keyMonitor == nil else {
            return
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            let rawCharacters = event.charactersIgnoringModifiers ?? ""
            let characters = rawCharacters.lowercased()
            let isSpace = event.keyCode == 49 || rawCharacters == " "
            let isTab = event.keyCode == 48 || rawCharacters == "\t"
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            let noModifiers = modifiers.isEmpty
            let onlyShift = modifiers == [.shift]
            switch event.keyCode {
            case _ where isSpace:
                guard noModifiers, viewModel.currentSequence != nil else {
                    return event
                }
                viewModel.togglePreview()
                return nil
            case _ where isTab && onlyShift:
                guard !viewModel.files.isEmpty else {
                    return event
                }
                viewModel.previousFileWrapping()
                return nil
            case _ where isTab:
                guard noModifiers, !viewModel.files.isEmpty else {
                    return event
                }
                viewModel.nextFileWrapping()
                return nil
            case 53 where noModifiers:
                guard restartEmptyStateAnimationIfNeeded() else {
                    return event
                }
                return nil
            case _ where isReturn:
                guard noModifiers, viewModel.currentSequence != nil else {
                    return event
                }
                viewModel.saveCurrent(format: .gif, advanceAfterSave: true)
                return nil
            case 123 where noModifiers || onlyShift:
                guard viewModel.currentSequence != nil else {
                    return event
                }
                viewModel.move(dx: onlyShift ? -10 : -viewModel.moveStep, dy: 0)
                return nil
            case 124 where noModifiers || onlyShift:
                guard viewModel.currentSequence != nil else {
                    return event
                }
                viewModel.move(dx: onlyShift ? 10 : viewModel.moveStep, dy: 0)
                return nil
            case 125 where noModifiers || onlyShift:
                guard viewModel.currentSequence != nil else {
                    return event
                }
                viewModel.move(dx: 0, dy: onlyShift ? 10 : viewModel.moveStep)
                return nil
            case 126 where noModifiers || onlyShift:
                guard viewModel.currentSequence != nil else {
                    return event
                }
                viewModel.move(dx: 0, dy: onlyShift ? -10 : -viewModel.moveStep)
                return nil
            case 24 where noModifiers || onlyShift:
                guard viewModel.currentSequence != nil else {
                    return event
                }
                viewModel.increaseZoom()
                return nil
            case 27 where noModifiers:
                guard viewModel.currentSequence != nil else {
                    return event
                }
                viewModel.decreaseZoom()
                return nil
            default:
                break
            }

            if noModifiers {
                switch characters {
                case "r":
                    guard viewModel.currentSequence != nil else {
                        return event
                    }
                    viewModel.resetOffset()
                    return nil
                case "[":
                    guard viewModel.currentSequence != nil else {
                        return event
                    }
                    viewModel.decreaseDuration()
                    return nil
                case "]":
                    guard viewModel.currentSequence != nil else {
                        return event
                    }
                    viewModel.increaseDuration()
                    return nil
                default:
                    break
                }
            }

            return event
        }
    }

    private func restartEmptyStateAnimationIfNeeded() -> Bool {
        guard viewModel.currentSequence == nil, !viewModel.isLoadingSequence else {
            return false
        }

        emptyStateAnimationRestartToken += 1
        return true
    }

    private func removeKeyboardMonitor() {
        guard let keyMonitor else {
            return
        }

        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let supportedProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }


        guard !supportedProviders.isEmpty else {
            return false
        }

        loadDroppedURLs(from: supportedProviders) { droppedURLs in
            guard !droppedURLs.isEmpty else {
                return
            }

            Task { @MainActor in
                viewModel.importDroppedURLs(droppedURLs)
            }
        }

        return true
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.folderGroups) { folder in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { viewModel.isFolderExpanded(folder.url) },
                                set: { viewModel.setFolderExpanded($0, for: folder.url) }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(folder.files.enumerated()), id: \.element.id) { folderIndex, file in
                                    sidebarFileRow(for: file, in: folder, folderIndex: folderIndex)
                                }
                            }
                            .padding(.leading, 14)
                        } label: {
                            Label(folder.displayName, systemImage: "folder.fill")
                                .font(.headline)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .overlay {
                if viewModel.files.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)

                        Text("Drag and drop folder, MPO, JPG, or PNG here")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Button("Open Photos") {
                    viewModel.openFilesPanel()
                }
                .buttonStyle(.borderedProminent)

                Button("Open Folder") {
                    viewModel.openFolderPanel()
                }
                .buttonStyle(.bordered)

                Button("New Composition") {
                    viewModel.createEmptyGrouping()
                }
                .buttonStyle(.bordered)

                Button("Clear List") {
                    viewModel.clearQueue()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.files.isEmpty)
            }

        }
        .padding(18)
        .frame(minWidth: 250)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let file = viewModel.currentFile {
                if let sequence = viewModel.currentSequence {
                    topHeader(for: file)

                    ImageAlignmentCanvas(
                        sequence: sequence,
                        offsets: viewModel.currentLayerOffsets,
                        visibleLayerIndices: viewModel.currentVisibleLayerIndices,
                        offset: Binding(
                            get: { viewModel.currentOffset },
                            set: { viewModel.setOffset($0) }
                        ),
                        selectedLayerIndex: viewModel.selectedLayerIndex,
                        zoom: $viewModel.canvasZoom,
                        previewEnabled: viewModel.previewEnabled,
                        frameDuration: viewModel.gifDuration,
                        playbackPattern: viewModel.playbackPattern,
                        toastMessage: viewModel.toastMessage
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    controls
                } else if viewModel.isLoadingSequence {
                    loadingPreviewState(for: file)
                } else {
                    emptyPreviewState
                }
            } else {
                emptyPreviewState
            }
        }
        .padding(22)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyPreviewState: some View {
        AnimatedEmptyPreviewState(restartToken: emptyStateAnimationRestartToken)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadingPreviewState(for file: MPOFileRecord) -> some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)

            Text("Opening \(file.displayName)...")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func topHeader(for file: MPOFileRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(file.displayName)
                .font(.title2.weight(.semibold))

            Text("Photo \(viewModel.currentIndexLabel)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            transportControls

            if viewModel.currentFrameCount > 1 {
                layerControls
            }

            timingControls
            exportControls
            shortcutsBar
        }
    }

    private var transportControls: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 12) {
                iconControlButton(
                    systemName: "chevron.left.circle",
                    help: "Previous photo (Shift+Tab)",
                    enabled: viewModel.canGoPrevious
                ) {
                    viewModel.previousFile()
                }

                iconControlButton(
                    systemName: "chevron.right.circle",
                    help: "Next photo (Tab)",
                    enabled: viewModel.canGoNext
                ) {
                    viewModel.nextFile()
                }

                iconControlButton(
                    systemName: viewModel.previewEnabled ? "pause.circle" : "play.circle",
                    help: "Toggle preview (Space)"
                ) {
                    viewModel.togglePreview()
                }

                iconControlButton(
                    systemName: "arrow.down.circle",
                    help: "Save GIF (Command+S)"
                ) {
                    viewModel.saveCurrent(format: .gif)
                }
            }

            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 2)
    }

    private var layerControls: some View {
        HStack(alignment: .center, spacing: 14) {
            layerSelectorStrip

            if viewModel.currentVisibleFrameCount > 2 {
                playbackPatternControl
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
    }

    private var layerSelectorStrip: some View {
        HStack(spacing: 8) {
            Text("Layer")
                .font(.caption.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<viewModel.currentFrameCount, id: \.self) { index in
                        layerButton(for: index)
                    }
                }
            }
            .frame(maxWidth: 260)
        }
    }

    private func layerButton(for index: Int) -> some View {
        let isVisible = viewModel.currentVisibleLayerIndices.contains(index)

        return Group {
            if index == viewModel.selectedLayerIndex {
                Button("\(index + 1)") {
                    viewModel.selectLayer(index)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("\(index + 1)") {
                    viewModel.selectLayer(index)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .opacity(isVisible ? 1 : 0.35)
        .disabled(!isVisible)
    }

    private var playbackPatternControl: some View {
        HStack(spacing: 8) {
            Text("Preview order")
                .font(.caption.weight(.semibold))

            Picker("", selection: $viewModel.playbackPattern) {
                Text(PlaybackPattern.sequence.label).tag(PlaybackPattern.sequence)
                Text(PlaybackPattern.loop.label).tag(PlaybackPattern.loop)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
    }

    private var timingControls: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 10) {
                Text("Step")
                    .font(.caption.weight(.semibold))

                Picker("", selection: $viewModel.moveStep) {
                    Text("1 px").tag(1)
                    Text("5 px").tag(5)
                    Text("10 px").tag(10)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .foregroundStyle(.secondary)

                Slider(value: $viewModel.gifDuration, in: 0.05...1.00, step: 0.05)
                    .frame(minWidth: 180, maxWidth: 240)

                Text("\(String(format: "%.2f", viewModel.gifDuration)) s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.horizontal, 2)
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Export GIF")
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 0)

                exportSizeControl
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Output folder")
                        .font(.caption.weight(.semibold))

                    Text(outputFolderDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(outputFolderHelpText)
                }

                Spacer(minLength: 12)

                Button("Change...") {
                    viewModel.openOutputPanel()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var shortcutsBar: some View {
        HStack(alignment: .center, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    primaryShortcutItem(key: "Tab", action: "next")
                    primaryShortcutItem(key: "Space", action: "preview")
                    primaryShortcutItem(key: "← ↑ ↓ →", action: "align")
                    primaryShortcutItem(key: "⌘S", action: "save")
                    primaryShortcutItem(key: "↩", action: "save+next")
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        primaryShortcutItem(key: "Tab", action: "next")
                        primaryShortcutItem(key: "Space", action: "preview")
                        primaryShortcutItem(key: "← ↑ ↓ →", action: "align")
                    }

                    HStack(spacing: 14) {
                        primaryShortcutItem(key: "⌘S", action: "save")
                        primaryShortcutItem(key: "↩", action: "save+next")
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                showingSecondaryShortcuts.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("More shortcuts")
            .popover(isPresented: $showingSecondaryShortcuts, arrowEdge: .bottom) {
                secondaryShortcutsPopover
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var secondaryShortcutsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("More shortcuts")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                secondaryShortcutItem(key: "Shift+Tab", action: "previous")
                secondaryShortcutItem(key: "Shift + ← ↑ ↓ →", action: "move 10 px")
                secondaryShortcutItem(key: "+ / -", action: "zoom")
                secondaryShortcutItem(key: "[ ]", action: "speed")
                secondaryShortcutItem(key: "R", action: "reset")
                secondaryShortcutItem(key: "Esc", action: "restart intro")
            }
        }
        .padding(14)
        .frame(minWidth: 220, alignment: .leading)
    }

    private func primaryShortcutItem(key: String, action: String) -> some View {
        HStack(spacing: 6) {
            shortcutKeycap(key)

            Text(action)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func secondaryShortcutItem(key: String, action: String) -> some View {
        HStack(spacing: 8) {
            shortcutKeycap(key)

            Text(action)
                .font(.caption)
        }
    }

    private func shortcutKeycap(_ label: String) -> some View {
        Text(label)
            .font(.caption2.monospaced())
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private func iconControlButton(
        systemName: String,
        help: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 24, weight: .regular))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        .disabled(!enabled)
    }

    private func statusDot(for file: MPOFileRecord) -> some View {
        let color: Color
        if file.exportedFormats.contains(.gif) {
            color = .green
        } else if file.exportedFormats.contains(.png) {
            color = .blue
        } else {
            color = .secondary
        }

        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }

    private func sidebarFileRow(for file: MPOFileRecord, in folder: SidebarFolderGroup, folderIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if folderIndex == 0 {
                sidebarFileInsertionZone(folderURL: folder.url, insertionIndex: 0)
            }

            if file.hasBrowsableLayers {
                sidebarGroupHeaderRow(for: file)

                if viewModel.isSequenceExpanded(file) {
                    sidebarLayerList(for: file)
                        .padding(.leading, 18)
                }
            } else if file.isEmptySequence {
                sidebarEmptySequenceRow(for: file)
            } else if viewModel.canAcceptDroppedLayer(into: file) {
                sidebarStandaloneSequenceRow(for: file)
            } else {
                sidebarStandaloneRow(for: file)
            }

            sidebarFileInsertionZone(folderURL: folder.url, insertionIndex: folderIndex + 1)
        }
        .padding(.vertical, 1)
    }

    private func sidebarSequenceLabel(for file: MPOFileRecord) -> some View {
        HStack(spacing: 10) {
            statusDot(for: file)

            VStack(alignment: .leading, spacing: 0) {
                Text(file.displayName)
                    .font(.body)
                    .lineLimit(1)
            }
        }
    }

    private func sidebarGroupHeaderRow(for file: MPOFileRecord) -> some View {
        HStack(spacing: 8) {
            sidebarSequenceLabel(for: file)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.selectFile(file)
                viewModel.setSequenceExpanded(!viewModel.isSequenceExpanded(file), for: file)
            } label: {
                Image(systemName: viewModel.isSequenceExpanded(file) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            sidebarSelectionBackground(
                isSelected: viewModel.isSidebarFileSelected(file),
                isDropTargeted: sidebarRecordDropTarget == file.id
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            viewModel.selectFile(file)
        }
        .onDrag {
            sidebarFileItemProvider(fileID: file.id)
        }
        .onDrop(
            of: sidebarRecordDropTypeIdentifiers,
            delegate: sidebarRecordRowDropDelegate(
                for: file,
                onEntered: {
                    viewModel.setSequenceExpanded(true, for: file)
                }
            )
        )
    }

    private func sidebarStandaloneRow(for file: MPOFileRecord) -> some View {
        HStack(spacing: 8) {
            sidebarSequenceLabel(for: file)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            sidebarSelectionBackground(
                isSelected: viewModel.isSidebarFileSelected(file),
                isDropTargeted: sidebarRecordDropTarget == file.id
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            viewModel.selectFile(file)
        }
        .onDrag {
            sidebarFileItemProvider(fileID: file.id)
        }
        .onDrop(
            of: sidebarRecordDropTypeIdentifiers,
            delegate: sidebarRecordRowDropDelegate(for: file)
        )
    }

    private func sidebarStandaloneSequenceRow(for file: MPOFileRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            sidebarInsertionZone(for: file, insertionIndex: 0)

            HStack(spacing: 8) {
                sidebarSequenceLabel(for: file)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                sidebarSelectionBackground(
                    isSelected: viewModel.isSidebarFileSelected(file),
                    isDropTargeted: sidebarRecordDropTarget == file.id
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onTapGesture {
                viewModel.selectFile(file)
            }
            .onDrag {
                sidebarFileItemProvider(fileID: file.id)
            }
            .onDrop(
                of: sidebarRecordDropTypeIdentifiers,
                delegate: sidebarRecordRowDropDelegate(for: file)
            )

            sidebarInsertionZone(for: file, insertionIndex: 1)
        }
    }

    private func sidebarEmptySequenceRow(for file: MPOFileRecord) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                statusDot(for: file)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.displayName)
                        .font(.body)
                        .lineLimit(1)

                    Text("drop photos here")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            sidebarSelectionBackground(
                isSelected: viewModel.isSidebarFileSelected(file),
                isDropTargeted: sidebarRecordDropTarget == file.id
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            viewModel.selectFile(file)
        }
        .onDrag {
            sidebarFileItemProvider(fileID: file.id)
        }
        .onDrop(
            of: sidebarRecordDropTypeIdentifiers,
            delegate: sidebarRecordRowDropDelegate(for: file)
        )
    }

    private func sidebarLayerList(for file: MPOFileRecord) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            sidebarInsertionZone(for: file, insertionIndex: 0)

            ForEach(Array(file.layerDisplayNames.enumerated()), id: \.offset) { index, name in
                sidebarLayerRow(file: file, index: index, name: name)
                sidebarInsertionZone(for: file, insertionIndex: index + 1)
            }
        }
        .onDrop(
            of: sidebarRecordDropTypeIdentifiers,
            delegate: sidebarRecordRowDropDelegate(for: file)
        )
    }

    private func sidebarLayerRow(file: MPOFileRecord, index: Int, name: String) -> some View {
        let isVisible = viewModel.isLayerVisible(index, in: file)
        let isSelected = viewModel.isSidebarLayerSelected(index, in: file)

        return HStack(spacing: 8) {
            Button {
                if viewModel.selectedFileID != file.id {
                    viewModel.selectFile(file)
                }
                viewModel.toggleLayerVisibility(index, in: file)
            } label: {
                Image(systemName: isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isVisible ? .secondary : .tertiary)
            .help(isVisible ? "Hide this photo from preview/export" : "Show this photo in preview/export")

            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)

                Text(name)
                    .font(isSelected ? .body.weight(.semibold) : .body)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(isVisible ? 1 : 0.45)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(sidebarSelectionBackground(isSelected: isSelected))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            viewModel.selectLayer(index, for: file)
        }
        .onDrag {
            sidebarLayerItemProvider(fileID: file.id, layerIndex: index)
        }
        .onDrop(
            of: [UTType.mpo3dSidebarLayer.identifier],
            delegate: sidebarLayerDropDelegate(for: file, insertionIndex: index + 1)
        )
    }

    private func sidebarInsertionZone(for file: MPOFileRecord, insertionIndex: Int) -> some View {
        let target = SidebarLayerDropTarget(fileID: file.id, insertionIndex: insertionIndex)
        let isActive = sidebarDropTarget == target

        return ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 4)

            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .opacity(isActive ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.mpo3dSidebarLayer.identifier],
            delegate: sidebarLayerDropDelegate(for: file, insertionIndex: insertionIndex)
        )
    }

    private func sidebarFileInsertionZone(folderURL: URL, insertionIndex: Int) -> some View {
        let target = SidebarFileDropTarget(folderURL: folderURL.standardizedFileURL, insertionIndex: insertionIndex)
        let isActive = sidebarFileDropTarget == target

        return ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 20)

            Capsule()
                .fill(Color.accentColor.opacity(0.9))
                .frame(height: 3)
                .opacity(isActive ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.mpo3dSidebarFile.identifier],
            delegate: sidebarFileDropDelegate(for: folderURL, insertionIndex: insertionIndex)
        )
    }

    private var exportSizeControl: some View {
        HStack(spacing: 8) {
            Text("Size")
                .font(.caption.weight(.semibold))

            Picker("", selection: $viewModel.exportSizePreset) {
                ForEach(ExportSizePreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)
        }
    }

    private var outputFolderDescription: String {
        if let outputDirectory = viewModel.outputDirectory {
            return outputDirectory.path
        }

        return "Same as source photo"
    }

    private var outputFolderHelpText: String {
        if let outputDirectory = viewModel.outputDirectory {
            return outputDirectory.path
        }

        if let currentFile = viewModel.currentFile {
            return currentFile.folderURL.path
        }

        return ""
    }

    private var sidebarRecordDropTypeIdentifiers: [String] {
        [
            UTType.mpo3dSidebarFile.identifier,
            UTType.mpo3dSidebarLayer.identifier,
            UTType.fileURL.identifier,
        ]
    }

    private func sidebarSelectionBackground(isSelected: Bool, isDropTargeted: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.001))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.22)
                            : (isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        (isSelected || isDropTargeted) ? Color.accentColor.opacity(0.24) : Color.clear,
                        lineWidth: 1
                    )
            )
    }

    private func sidebarLayerItemProvider(fileID: UUID, layerIndex: Int) -> NSItemProvider {
        let payload = SidebarLayerDragPayload(fileID: fileID, layerIndex: layerIndex)
        return sidebarPayloadItemProvider(type: .mpo3dSidebarLayer, payload: payload.serialized)
    }

    private func sidebarFileItemProvider(fileID: UUID) -> NSItemProvider {
        let payload = SidebarFileDragPayload(fileID: fileID)
        return sidebarPayloadItemProvider(type: .mpo3dSidebarFile, payload: payload.serialized)
    }

    private func sidebarLayerDropDelegate(
        for file: MPOFileRecord,
        insertionIndex: Int,
        onEntered: (() -> Void)? = nil
    ) -> SidebarLayerDropDelegate {
        SidebarLayerDropDelegate(
            target: SidebarLayerDropTarget(fileID: file.id, insertionIndex: insertionIndex),
            activeTarget: $sidebarDropTarget,
            canAccept: { viewModel.canAcceptDroppedLayer(into: file) },
            onEntered: onEntered,
            onPerform: { payload, target in
                viewModel.moveLayer(
                    from: payload.fileID,
                    layerIndex: payload.layerIndex,
                    to: target.fileID,
                    insertionIndex: target.insertionIndex
                )
            }
        )
    }

    private func sidebarRecordRowDropDelegate(
        for file: MPOFileRecord,
        onEntered: (() -> Void)? = nil
    ) -> SidebarRecordRowDropDelegate {
        SidebarRecordRowDropDelegate(
            targetRecordID: file.id,
            activeTarget: $sidebarRecordDropTarget,
            onEntered: onEntered,
            onMoveLayer: { payload in
                viewModel.moveLayer(
                    from: payload.fileID,
                    layerIndex: payload.layerIndex,
                    to: file.id,
                    insertionIndex: file.layerCountHint
                )
            },
            onMergeRecord: { payload in
                viewModel.mergeFileRecord(from: payload.fileID, into: file.id)
            },
            onImportFiles: { urls in
                viewModel.importDroppedURLs(urls, into: file.id)
            }
        )
    }

    private func sidebarFileDropDelegate(for folderURL: URL, insertionIndex: Int) -> SidebarFileDropDelegate {
        SidebarFileDropDelegate(
            target: SidebarFileDropTarget(folderURL: folderURL.standardizedFileURL, insertionIndex: insertionIndex),
            activeTarget: $sidebarFileDropTarget,
            onPerform: { payload, target in
                viewModel.moveFileRecord(
                    from: payload.fileID,
                    toFolder: target.folderURL,
                    insertionIndex: target.insertionIndex
                )
            }
        )
    }

}

private struct AnimatedEmptyPreviewState: View {
    let restartToken: Int

    @State private var holdOpacity = 0.0
    @State private var stillOpacity = 0.0
    @State private var dotOneOpacity = 0.0
    @State private var dotTwoOpacity = 0.0
    @State private var dotThreeOpacity = 0.0
    @State private var youOpacity = 0.0
    @State private var lookOpacity = 0.0
    @State private var greatOpacity = 0.0
    @State private var faceDotSquint: CGFloat = 1.0
    @State private var handTilt = 0.0
    @State private var shutterDrop: CGFloat = 0.0
    @State private var flashOpacity = 0.0
    @State private var flashScale: CGFloat = 0.35
    @State private var greatShakeProgress = 0.0
    @State private var hasPlayedInitialSequence = false

    private enum Copy {
        static let hold = "hold"
        static let still = "still"
        static let you = "you"
        static let look = "look"
        static let great = "great"
    }

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                mascot

                HStack(spacing: 8) {
                    speechWord(Copy.hold, opacity: holdOpacity)
                    speechWord(Copy.still, opacity: stillOpacity)

                    HStack(spacing: 1) {
                        speechDot(dotOneOpacity)
                        speechDot(dotTwoOpacity)
                        speechDot(dotThreeOpacity)
                    }
                }

                HStack(spacing: 8) {
                    complimentWord(Copy.you, opacity: youOpacity)
                    complimentWord(Copy.look, opacity: lookOpacity)

                    Text(Copy.great)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .opacity(greatOpacity)
                        .modifier(ShakeEffect(animatableData: greatShakeProgress))
                }
            }

            VStack {
                Spacer()
                onboardingPanel
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: restartToken) {
            let initialDelay: UInt64 = hasPlayedInitialSequence ? 0 : 1_000
            hasPlayedInitialSequence = true
            await runSequence(initialDelay: initialDelay)
        }
        .accessibilityElement(children: .combine)
    }

    private var mascot: some View {
        HStack(spacing: 0) {
            mascotGlyph("/")
            mascotGlyph("[")

            ZStack {
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 18, height: 18)
                    .blur(radius: 0.5)

                Rectangle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 22, height: 2.2)

                Rectangle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 2.2, height: 22)
            }
            .scaleEffect(flashScale)
            .opacity(flashOpacity)
            .frame(width: 0, height: 0)
            .offset(x: 4, y: -1)
            .blendMode(.plusLighter)

            mascotGlyph("◉")

            mascotGlyph("\"")
                .offset(y: shutterDrop)

            mascotGlyph("]")

            mascotGlyph("＼")
                .rotationEffect(.degrees(-handTilt), anchor: .leading)

            mascotGlyph("_")

            mascotGlyph("・")
                .scaleEffect(x: 1 + ((1 - faceDotSquint) * 0.3), y: faceDotSquint, anchor: .center)
                .offset(y: (1 - faceDotSquint) * 1.2)

            mascotGlyph(")")
        }
        .font(.system(size: 34, weight: .medium, design: .rounded))
        .tracking(0.5)
        .compositingGroup()
    }

    @ViewBuilder
    private func mascotGlyph(_ value: String) -> some View {
        Text(value)
    }

    private func speechWord(_ value: String, opacity: Double) -> some View {
        Text(value)
            .font(.title2.weight(.semibold))
            .opacity(opacity)
    }

    private func speechDot(_ opacity: Double) -> some View {
        Text(".")
            .font(.title2.weight(.semibold))
            .opacity(opacity)
    }

    private func complimentWord(_ value: String, opacity: Double) -> some View {
        Text(value)
            .font(.title3)
            .foregroundStyle(.secondary)
            .opacity(opacity)
    }

    private var onboardingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick start")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            onboardingStep(number: "1", text: "Open photos or a folder from the left sidebar.")
            onboardingStep(number: "2", text: "Align by dragging the preview or using the arrow keys.")
            onboardingStep(number: "3", text: "Save your animated GIF when the motion looks right.")

            Text("Need a custom stack? Create a New Composition and drop photos into it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func onboardingStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .background(Color(nsColor: .controlBackgroundColor), in: Circle())

            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }

    @MainActor
    private func runSequence(initialDelay: UInt64) async {
        resetState()

        guard await pause(initialDelay) else { return }

        guard await pause(260) else { return }

        withAnimation(.easeOut(duration: 0.32)) {
            holdOpacity = 1
        }

        guard await pause(320) else { return }

        withAnimation(.easeOut(duration: 0.30)) {
            stillOpacity = 1
            handTilt = 6
            shutterDrop = 1.5
        }

        withAnimation(.easeInOut(duration: 1.52)) {
            faceDotSquint = 0.55
        }

        guard await pause(360) else { return }

        withAnimation(.easeOut(duration: 0.22)) {
            dotOneOpacity = 1
            handTilt = 10
            shutterDrop = 3
        }

        guard await pause(250) else { return }

        withAnimation(.easeOut(duration: 0.22)) {
            dotTwoOpacity = 1
            handTilt = 14
            shutterDrop = 4
        }

        guard await pause(290) else { return }

        withAnimation(.easeOut(duration: 0.24)) {
            dotThreeOpacity = 1
            handTilt = 18
            shutterDrop = 5
        }

        guard await pause(260) else { return }

        withAnimation(.easeIn(duration: 0.12)) {
            flashOpacity = 1
            flashScale = 1.2
        }

        guard await pause(140) else { return }

        withAnimation(.easeOut(duration: 0.20)) {
            flashOpacity = 0
            flashScale = 1.7
        }

        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
            faceDotSquint = 1
            handTilt = 0
            shutterDrop = 0
        }

        guard await pause(320) else { return }

        withAnimation(.easeOut(duration: 0.24)) {
            youOpacity = 1
        }

        guard await pause(220) else { return }

        withAnimation(.easeOut(duration: 0.24)) {
            lookOpacity = 1
        }

        guard await pause(190) else { return }

        withAnimation(.easeOut(duration: 0.12)) {
            greatOpacity = 1
        }

        withAnimation(.linear(duration: 0.56)) {
            greatShakeProgress = 1
        }
    }

    @MainActor
    private func resetState() {
        holdOpacity = 0
        stillOpacity = 0
        dotOneOpacity = 0
        dotTwoOpacity = 0
        dotThreeOpacity = 0
        youOpacity = 0
        lookOpacity = 0
        greatOpacity = 0
        faceDotSquint = 1
        handTilt = 0
        shutterDrop = 0
        flashOpacity = 0
        flashScale = 0.35
        greatShakeProgress = 0
    }

    private func pause(_ milliseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

private struct SaveToastPill: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
    }
}

private struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 7
    var shakesPerUnit = 4
    var animatableData: Double

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amount * sin(animatableData * .pi * Double(shakesPerUnit))
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

private struct SidebarLayerDragPayload {
    let fileID: UUID
    let layerIndex: Int

    var serialized: String {
        "layer|\(fileID.uuidString)|\(layerIndex)"
    }

    init(fileID: UUID, layerIndex: Int) {
        self.fileID = fileID
        self.layerIndex = layerIndex
    }

    init?(serialized: String) {
        let parts = serialized.split(separator: "|", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            parts[0] == "layer",
            let fileID = UUID(uuidString: String(parts[1])),
            let layerIndex = Int(parts[2])
        else {
            return nil
        }

        self.fileID = fileID
        self.layerIndex = layerIndex
    }
}

private struct SidebarFileDragPayload {
    let fileID: UUID

    var serialized: String {
        "file|\(fileID.uuidString)"
    }

    init(fileID: UUID) {
        self.fileID = fileID
    }

    init?(serialized: String) {
        let parts = serialized.split(separator: "|", omittingEmptySubsequences: false)
        guard
            parts.count == 2,
            parts[0] == "file",
            let fileID = UUID(uuidString: String(parts[1]))
        else {
            return nil
        }

        self.fileID = fileID
    }
}

private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct SidebarLayerDropTarget: Equatable {
    let fileID: UUID
    let insertionIndex: Int
}

private struct SidebarFileDropTarget: Equatable {
    let folderURL: URL
    let insertionIndex: Int
}

private struct SidebarLayerDropDelegate: DropDelegate {
    let target: SidebarLayerDropTarget
    @Binding var activeTarget: SidebarLayerDropTarget?
    let canAccept: () -> Bool
    let onEntered: (() -> Void)?
    let onPerform: (SidebarLayerDragPayload, SidebarLayerDropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let accepted = canAccept() && info.hasItemsConforming(to: [UTType.mpo3dSidebarLayer.identifier])
        return accepted
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else {
            activeTarget = nil
            return
        }

        onEntered?()
        activeTarget = target
    }

    func dropExited(info: DropInfo) {
        activeTarget = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return nil
        }

        activeTarget = target
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [UTType.mpo3dSidebarLayer.identifier]).first else {
            activeTarget = nil
            return false
        }

        activeTarget = nil
        loadSidebarPayload(from: provider, type: .mpo3dSidebarLayer) { text in
            guard let text, let payload = SidebarLayerDragPayload(serialized: text) else {
                return
            }

            Task { @MainActor in
                onPerform(payload, target)
            }
        }
        
        return true
    }
}

private struct SidebarFileDropDelegate: DropDelegate {
    let target: SidebarFileDropTarget
    @Binding var activeTarget: SidebarFileDropTarget?
    let onPerform: (SidebarFileDragPayload, SidebarFileDropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let accepted = info.hasItemsConforming(to: [UTType.mpo3dSidebarFile.identifier])
        return accepted
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else {
            activeTarget = nil
            return
        }

        activeTarget = target
    }

    func dropExited(info: DropInfo) {
        activeTarget = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return nil
        }

        activeTarget = target
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [UTType.mpo3dSidebarFile.identifier]).first else {
            activeTarget = nil
            return false
        }

        activeTarget = nil
        loadSidebarPayload(from: provider, type: .mpo3dSidebarFile) { text in
            guard let text, let payload = SidebarFileDragPayload(serialized: text) else {
                return
            }

            Task { @MainActor in
                onPerform(payload, target)
            }
        }

        return true
    }
}

private struct SidebarRecordRowDropDelegate: DropDelegate {
    let targetRecordID: UUID
    @Binding var activeTarget: UUID?
    let onEntered: (() -> Void)?
    let onMoveLayer: (SidebarLayerDragPayload) -> Void
    let onMergeRecord: (SidebarFileDragPayload) -> Void
    let onImportFiles: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let accepted = info.hasItemsConforming(to: [UTType.mpo3dSidebarFile.identifier])
            || info.hasItemsConforming(to: [UTType.mpo3dSidebarLayer.identifier])
            || info.hasItemsConforming(to: [UTType.fileURL.identifier])
        return accepted
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else {
            activeTarget = nil
            return
        }

        onEntered?()
        activeTarget = targetRecordID
    }

    func dropExited(info: DropInfo) {
        activeTarget = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return nil
        }

        activeTarget = targetRecordID
        let operation: DropOperation = info.hasItemsConforming(to: [UTType.fileURL.identifier]) ? .copy : .move
        return DropProposal(operation: operation)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else {
            activeTarget = nil
            return false
        }

        activeTarget = nil
        let hasSidebarFile = info.hasItemsConforming(to: [UTType.mpo3dSidebarFile.identifier])
        let hasSidebarLayer = info.hasItemsConforming(to: [UTType.mpo3dSidebarLayer.identifier])
        let hasExternalFiles = info.hasItemsConforming(to: [UTType.fileURL.identifier])

        if hasSidebarLayer,
           let provider = info.itemProviders(for: [UTType.mpo3dSidebarLayer.identifier]).first {
            loadSidebarPayload(from: provider, type: .mpo3dSidebarLayer) { text in
                guard let text, let payload = SidebarLayerDragPayload(serialized: text) else {
                    return
                }

                Task { @MainActor in
                    onMoveLayer(payload)
                }
            }
            return true
        }

        if hasSidebarFile && !hasExternalFiles,
           let provider = info.itemProviders(for: [UTType.mpo3dSidebarFile.identifier]).first {
            loadSidebarPayload(from: provider, type: .mpo3dSidebarFile) { text in
                guard let text, let payload = SidebarFileDragPayload(serialized: text) else {
                    return
                }

                Task { @MainActor in
                    onMergeRecord(payload)
                }
            }
            return true
        }

        if hasExternalFiles {
            let providers = info.itemProviders(for: [UTType.fileURL.identifier])
            guard !providers.isEmpty else {
                return false
            }

            loadDroppedURLs(from: providers) { urls in
                guard !urls.isEmpty else {
                    return
                }

                Task { @MainActor in
                    onImportFiles(urls)
                }
            }

            return true
        }

        if hasSidebarFile,
           let provider = info.itemProviders(for: [UTType.mpo3dSidebarFile.identifier]).first {
            loadSidebarPayload(from: provider, type: .mpo3dSidebarFile) { text in
                guard let text, let payload = SidebarFileDragPayload(serialized: text) else {
                    return
                }

                Task { @MainActor in
                    onMergeRecord(payload)
                }
            }
            return true
        }

        return false
    }
}

private extension UTType {
    // SwiftUI drop validation on macOS is more reliable with well-known pasteboard types.
    static let mpo3dSidebarLayer = UTType.json
    static let mpo3dSidebarFile = UTType.plainText
}

private func sidebarPayloadItemProvider(type: UTType, payload: String) -> NSItemProvider {
    let payloadData = Data(payload.utf8)
    let provider = NSItemProvider(item: payloadData as NSData, typeIdentifier: type.identifier)
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
        completion(payloadData, nil)
        return nil
    }
    return provider
}

private func loadSidebarPayload(
    from provider: NSItemProvider,
    type: UTType,
    completion: @escaping @Sendable (String?) -> Void
) {
    provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
        guard let data else {
            completion(nil)
            return
        }

        completion(String(data: data, encoding: .utf8))
    }
}

private func loadDroppedURLs(
    from providers: [NSItemProvider],
    completion: @escaping ([URL]) -> Void
) {
    let supportedProviders = providers.filter {
        $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    guard !supportedProviders.isEmpty else {
        completion([])
        return
    }

    let group = DispatchGroup()
    let collector = DroppedURLCollector()

    for provider in supportedProviders {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            defer { group.leave() }

            guard let url = droppedURL(from: item) else {
                return
            }

            collector.append(url)
        }
    }

    group.notify(queue: .main) {
        completion(collector.urls)
    }
}

private func droppedURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL {
        return url
    }

    if let url = item as? NSURL {
        return url as URL
    }

    if let data = item as? Data {
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    if let string = item as? String {
        return URL(string: string)
    }

    return nil
}

private struct ImageAlignmentCanvas: View {
    let sequence: FrameSequence
    let offsets: [PixelOffset]
    let visibleLayerIndices: [Int]
    @Binding var offset: PixelOffset
    let selectedLayerIndex: Int
    @Binding var zoom: Double
    let previewEnabled: Bool
    let frameDuration: Double
    let playbackPattern: PlaybackPattern
    let toastMessage: String?

    var body: some View {
        GeometryReader { geometry in
            let imageAspect = sequence.aspectRatio
            let fittedSize = fitSize(for: imageAspect, in: geometry.size)

            NativePreviewCanvas(
                sequence: sequence,
                offsets: offsets,
                visibleLayerIndices: visibleLayerIndices,
                offset: $offset,
                selectedLayerIndex: selectedLayerIndex,
                zoom: $zoom,
                previewEnabled: previewEnabled,
                frameDuration: frameDuration,
                playbackPattern: playbackPattern,
                fittedSize: fittedSize
            )
            .frame(width: fittedSize.width, height: fittedSize.height)
            .overlay(alignment: .topTrailing) {
                if let toastMessage {
                    SaveToastPill(message: toastMessage)
                        .padding(16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.26, dampingFraction: 0.92), value: toastMessage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(nsColor: PreviewCanvasPalette.background))
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 16, y: 8)
        }
    }

    private func fitSize(for aspectRatio: CGFloat, in availableSize: CGSize) -> CGSize {
        let availableWidth = max(availableSize.width, 1)
        let availableHeight = max(availableSize.height, 1)
        let availableAspect = availableWidth / availableHeight

        if availableAspect > aspectRatio {
            let height = availableHeight
            return CGSize(width: height * aspectRatio, height: height)
        }

        let width = availableWidth
        return CGSize(width: width, height: width / aspectRatio)
    }
}
