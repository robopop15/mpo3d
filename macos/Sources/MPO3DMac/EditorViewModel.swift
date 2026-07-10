import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var files: [MPOFileRecord] = []
    @Published var expandedFolderPaths: Set<String> = []
    @Published var expandedSequenceIDs: Set<UUID> = []
    @Published var selectedSidebarLayerIndex: Int?
    @Published var selectedFileID: UUID? {
        didSet {
            loadSelectedFile()
        }
    }
    @Published private(set) var currentSequence: FrameSequence?
    @Published private(set) var isLoadingSequence = false
    @Published var currentOffset: PixelOffset = .zero
    @Published var selectedLayerIndex: Int = 0 {
        didSet {
            loadSelectedLayerOffset()
        }
    }
    @Published var playbackPattern: PlaybackPattern = .loop {
        didSet {
            syncPlaybackPatternIntoCurrentFile()
        }
    }
    @Published var outputDirectory: URL?
    @Published var previewEnabled = false
    @Published var gifDuration: Double = 0.20
    @Published var moveStep: Int = 1
    @Published var canvasZoom: Double = 1.0
    @Published var exportSizePreset: ExportSizePreset = .original {
        didSet {
            rebuildPreviewSequenceIfNeeded()
        }
    }
    @Published var toastMessage: String?
    @Published var statusMessage = "Open photos or a folder to get started."
    @Published var errorMessage: String?

    private var loadTask: Task<Void, Never>?
    private var pendingSelectedLayerIndex: Int?
    private var toastDismissTask: Task<Void, Never>?

    var currentFile: MPOFileRecord? {
        guard let index = currentFileIndex else {
            return nil
        }
        return files[index]
    }

    var currentFrameCount: Int {
        currentSequence?.frameCount ?? currentFile?.layerCountHint ?? 0
    }

    var currentLayerOffsets: [PixelOffset] {
        offsets(for: currentFile, frameCount: currentFrameCount)
    }

    var currentVisibleLayerIndices: [Int] {
        visibleLayerIndices(for: currentFile, frameCount: currentFrameCount)
    }

    var currentVisibleFrameCount: Int {
        currentVisibleLayerIndices.count
    }

    var folderGroups: [SidebarFolderGroup] {
        var orderedFolders: [URL] = []
        var grouped: [URL: [MPOFileRecord]] = [:]

        for record in files {
            let folderURL = record.folderURL
            if grouped[folderURL] == nil {
                orderedFolders.append(folderURL)
                grouped[folderURL] = []
            }

            grouped[folderURL, default: []].append(record)
        }

        return orderedFolders.map { folderURL in
            SidebarFolderGroup(
                url: folderURL,
                files: grouped[folderURL, default: []]
            )
        }
    }

    var currentFileIndex: Int? {
        guard let selectedFileID else {
            return nil
        }
        return files.firstIndex { $0.id == selectedFileID }
    }

    var currentIndexLabel: String {
        guard let currentFileIndex else {
            return "0 / \(files.count)"
        }
        return "\(currentFileIndex + 1) / \(files.count)"
    }

    var canGoPrevious: Bool {
        guard let currentFileIndex else {
            return false
        }
        return currentFileIndex > 0
    }

    var canGoNext: Bool {
        guard let currentFileIndex else {
            return false
        }
        return currentFileIndex < files.count - 1
    }

    func openFilesPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose MPO, JPEG, or PNG Files"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let mpoType = UTType(tag: "mpo", tagClass: .filenameExtension, conformingTo: .data) ?? .data
        panel.allowedContentTypes = [mpoType, .jpeg, .png]

        guard panel.runModal() == .OK else {
            return
        }

        importFiles(panel.urls, allowLooseJPEGSequence: true, preferExplicitJPEGSelectionGrouping: true)
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder with MPO, JPEG, or PNG Files"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let folder = panel.url else {
            return
        }

        importFolder(folder)
    }

    func openOutputPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if let outputDirectory {
            panel.directoryURL = outputDirectory
        } else if let currentFile {
            panel.directoryURL = currentFile.url.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let folder = panel.url else {
            return
        }

        outputDirectory = folder
        statusMessage = "Output folder changed to \(folder.path)."
    }

    func importFolder(_ folderURL: URL) {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let supportedFiles = contents
                .filter(Self.isSupportedImportURL(_:))
                .sorted(by: Self.sortURL)

            guard !supportedFiles.isEmpty else {
                errorMessage = "No MPO, JPEG, or PNG files were found in that folder."
                return
            }

            importFiles(
                supportedFiles,
                expandedFolders: [folderURL.standardizedFileURL.path],
                allowLooseJPEGSequence: false,
                preferExplicitJPEGSelectionGrouping: false
            )
        } catch {
            errorMessage = "The selected folder could not be read."
        }
    }

    func importFiles(
        _ urls: [URL],
        allowLooseJPEGSequence: Bool = true,
        preferExplicitJPEGSelectionGrouping: Bool = false
    ) {
        importFiles(
            urls,
            expandedFolders: [],
            allowLooseJPEGSequence: allowLooseJPEGSequence,
            preferExplicitJPEGSelectionGrouping: preferExplicitJPEGSelectionGrouping
        )
    }

    func importDroppedURLs(_ urls: [URL]) {
        let standardized = urls.map { $0.standardizedFileURL }
        var importableFiles: [URL] = []
        var expandedFolders: Set<String> = []
        var sawFolderWithoutSupportedFiles = false
        var droppedDirectFile = false
        var droppedFolder = false

        for url in standardized {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                droppedFolder = true
                do {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                    let supportedContents = contents
                        .filter(Self.isSupportedImportURL(_:))
                        .sorted(by: Self.sortURL)

                    if supportedContents.isEmpty {
                        sawFolderWithoutSupportedFiles = true
                        continue
                    }

                    importableFiles.append(contentsOf: supportedContents)
                    expandedFolders.insert(url.path)
                } catch {
                    errorMessage = "One of the dropped folders could not be read."
                }
            } else if Self.isSupportedImportURL(url) {
                importableFiles.append(url)
                expandedFolders.insert(url.deletingLastPathComponent().path)
                droppedDirectFile = true
            }
        }

        guard !importableFiles.isEmpty else {
            if sawFolderWithoutSupportedFiles {
                errorMessage = "No MPO, JPEG, or PNG files were found in the dropped item."
            } else {
                errorMessage = "Drop a folder with MPO/JPEG/PNG files or one or more photos."
            }
            return
        }

        importFiles(
            importableFiles,
            expandedFolders: expandedFolders,
            allowLooseJPEGSequence: droppedDirectFile,
            preferExplicitJPEGSelectionGrouping: droppedDirectFile && !droppedFolder
        )
    }

    func isFolderExpanded(_ folderURL: URL) -> Bool {
        expandedFolderPaths.contains(folderURL.standardizedFileURL.path)
    }

    func setFolderExpanded(_ isExpanded: Bool, for folderURL: URL) {
        let path = folderURL.standardizedFileURL.path
        if isExpanded {
            expandedFolderPaths.insert(path)
        } else {
            expandedFolderPaths.remove(path)
        }
    }

    func isSequenceExpanded(_ record: MPOFileRecord) -> Bool {
        expandedSequenceIDs.contains(record.id)
    }

    func setSequenceExpanded(_ isExpanded: Bool, for record: MPOFileRecord) {
        if isExpanded {
            expandedSequenceIDs.insert(record.id)
        } else {
            expandedSequenceIDs.remove(record.id)
        }
    }

    func clearQueue() {
        loadTask?.cancel()
        loadTask = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        previewEnabled = false
        canvasZoom = 1.0
        files = []
        expandedFolderPaths = []
        expandedSequenceIDs = []
        selectedFileID = nil
        currentSequence = nil
        isLoadingSequence = false
        currentOffset = .zero
        selectedLayerIndex = 0
        selectedSidebarLayerIndex = nil
        toastMessage = nil
        playbackPattern = .loop
        statusMessage = "List cleared. Open new photos."
    }

    func createEmptyGrouping() {
        let folderURL = preferredEmptyGroupingFolderURL
        let name = uniqueEmptyGroupingName(in: folderURL)
        let record = MPOFileRecord(source: .emptySequence(name: name, folderURL: folderURL))

        insertRecordsPreservingFolderSections([record])
        expandedFolderPaths.insert(folderURL.path)
        selectedSidebarLayerIndex = nil
        pendingSelectedLayerIndex = nil
        selectedFileID = record.id
    }

    func setOffset(_ offset: PixelOffset) {
        currentOffset = offset
        syncOffsetIntoCurrentFile()
    }

    func move(dx: Int, dy: Int) {
        setOffset(currentOffset.moved(dx: dx, dy: dy))
    }

    func resetOffset() {
        setOffset(.zero)
    }

    func selectFile(_ record: MPOFileRecord) {
        pendingSelectedLayerIndex = nil
        selectedSidebarLayerIndex = nil

        guard selectedFileID != record.id else {
            return
        }

        selectedFileID = record.id
    }

    func selectLayer(_ index: Int) {
        guard
            index >= 0,
            index < currentFrameCount,
            currentVisibleLayerIndices.contains(index)
        else {
            return
        }
        selectedLayerIndex = index
    }

    func selectLayer(_ index: Int, for record: MPOFileRecord) {
        pendingSelectedLayerIndex = index
        selectedSidebarLayerIndex = index

        if selectedFileID == record.id {
            selectLayer(index)
        } else {
            selectedFileID = record.id
        }
    }

    func isSidebarFileSelected(_ record: MPOFileRecord) -> Bool {
        selectedFileID == record.id && selectedSidebarLayerIndex == nil
    }

    func isSidebarLayerSelected(_ index: Int, in record: MPOFileRecord) -> Bool {
        selectedFileID == record.id && selectedSidebarLayerIndex == index
    }

    func isLayerVisible(_ index: Int, in record: MPOFileRecord) -> Bool {
        record.isLayerVisible(index)
    }

    func toggleLayerVisibility(_ index: Int, in record: MPOFileRecord) {
        guard let fileIndex = files.firstIndex(where: { $0.id == record.id }) else {
            return
        }

        let frameCount = files[fileIndex].layerCountHint
        let currentlyVisible = visibleLayerIndices(for: files[fileIndex], frameCount: frameCount)

        if files[fileIndex].hiddenLayerIndices.contains(index) {
            files[fileIndex].hiddenLayerIndices.remove(index)
        } else {
            guard currentlyVisible.count > 1 else {
                statusMessage = "Keep at least one photo enabled."
                return
            }
            files[fileIndex].hiddenLayerIndices.insert(index)
        }

        if selectedFileID == record.id {
            syncSelectionWithVisibleLayers()
        }
    }

    func visibleLayerCount(for record: MPOFileRecord) -> Int {
        visibleLayerIndices(for: record, frameCount: record.layerCountHint).count
    }

    func canAcceptDroppedLayer(into record: MPOFileRecord) -> Bool {
        sequenceState(for: record) != nil
    }

    func canAcceptDroppedFiles(into record: MPOFileRecord) -> Bool {
        sequenceState(for: record) != nil
    }

    func canDragLayer(from record: MPOFileRecord, index: Int) -> Bool {
        sequenceState(for: record)?.layers.indices.contains(index) == true
    }

    func moveLayer(
        from sourceRecordID: UUID,
        layerIndex: Int,
        to targetRecordID: UUID,
        insertionIndex: Int
    ) {
        guard
            let sourceIndex = files.firstIndex(where: { $0.id == sourceRecordID }),
            let targetIndex = files.firstIndex(where: { $0.id == targetRecordID }),
            sourceRecordID == targetRecordID
                ? sequenceState(for: files[sourceIndex])?.layers.indices.contains(layerIndex) == true
                : true
        else {
            return
        }

        if sourceRecordID == targetRecordID {
            guard var state = sequenceState(for: files[sourceIndex]), state.layers.indices.contains(layerIndex) else {
                return
            }

            let movingItem = state.remove(at: layerIndex)
            let rawDestination = max(0, min(insertionIndex, state.layers.count + 1))
            let adjustedDestination = rawDestination > layerIndex ? rawDestination - 1 : rawDestination

            guard adjustedDestination != layerIndex else {
                return
            }

            state.insert(movingItem, at: adjustedDestination)

            applySequenceState(state, toRecordAt: sourceIndex)
            refreshExpansionState(forRecordID: sourceRecordID)

            pendingSelectedLayerIndex = adjustedDestination
            selectedSidebarLayerIndex = adjustedDestination
            selectedFileID = sourceRecordID
            statusMessage = "\(movingItem.layer.displayName) moved."
            return
        }

        guard
            var sourceState = sequenceState(for: files[sourceIndex]),
            var targetState = sequenceState(for: files[targetIndex]),
            sourceState.layers.indices.contains(layerIndex)
        else {
            return
        }

        let movingItem = sourceState.remove(at: layerIndex)
        let adjustedDestination = max(0, min(insertionIndex, targetState.layers.count))

        if sourceRecordID != targetRecordID, targetState.layers.contains(movingItem.layer) {
            statusMessage = "\(movingItem.layer.displayName) is already in that composition."
            return
        }

        targetState.insert(movingItem, at: adjustedDestination)

        if sourceState.layers.isEmpty {
            files.remove(at: sourceIndex)
        } else if let refreshedSourceIndex = files.firstIndex(where: { $0.id == sourceRecordID }) {
            applySequenceState(sourceState, toRecordAt: refreshedSourceIndex)
        }

        if let refreshedTargetIndex = files.firstIndex(where: { $0.id == targetRecordID }) {
            applySequenceState(targetState, toRecordAt: refreshedTargetIndex)
        }

        refreshExpansionState(forRecordID: sourceRecordID)
        refreshExpansionState(forRecordID: targetRecordID)

        pendingSelectedLayerIndex = adjustedDestination
        selectedSidebarLayerIndex = adjustedDestination

        if selectedFileID == targetRecordID, sourceRecordID != targetRecordID {
            loadSelectedFile()
        } else {
            selectedFileID = targetRecordID
        }

        if let refreshedTargetIndex = files.firstIndex(where: { $0.id == targetRecordID }) {
            let movedName = movingItem.layer.displayName
            statusMessage = "\(movedName) moved to \(files[refreshedTargetIndex].displayName)."
        }
    }

    func mergeFileRecord(from sourceRecordID: UUID, into targetRecordID: UUID) {
        guard sourceRecordID != targetRecordID,
              let sourceIndex = files.firstIndex(where: { $0.id == sourceRecordID }),
              let targetIndex = files.firstIndex(where: { $0.id == targetRecordID }),
              let sourceState = sequenceState(for: files[sourceIndex]),
              var targetState = sequenceState(for: files[targetIndex]) else {
            return
        }

        guard !sourceState.layers.isEmpty else {
            return
        }

        if let duplicateLayer = sourceState.layers.first(where: { targetState.layers.contains($0) }) {
            statusMessage = "\(duplicateLayer.displayName) is already in that composition."
            return
        }

        let insertionIndex = targetState.layers.count
        for item in sourceState.items {
            targetState.insert(item, at: targetState.layers.count)
        }

        files.remove(at: sourceIndex)
        guard let refreshedTargetIndex = files.firstIndex(where: { $0.id == targetRecordID }) else {
            return
        }

        applySequenceState(targetState, toRecordAt: refreshedTargetIndex)
        refreshExpansionState(forRecordID: sourceRecordID)
        refreshExpansionState(forRecordID: targetRecordID)

        pendingSelectedLayerIndex = insertionIndex
        selectedSidebarLayerIndex = insertionIndex
        selectedFileID = targetRecordID
        statusMessage = "\(files[refreshedTargetIndex].displayName) updated."
    }

    func importDroppedURLs(_ urls: [URL], into targetRecordID: UUID) {
        guard let targetIndex = files.firstIndex(where: { $0.id == targetRecordID }),
              var targetState = sequenceState(for: files[targetIndex]) else {
            return
        }

        let droppedLayers = Self.buildDroppedLayerSources(from: urls)
        guard !droppedLayers.isEmpty else {
            errorMessage = "Drop MPO, JPG, PNG, or a folder with supported photos."
            return
        }

        if let duplicateLayer = droppedLayers.first(where: { targetState.layers.contains($0) }) {
            statusMessage = "\(duplicateLayer.displayName) is already in that composition."
            return
        }

        let insertionIndex = targetState.layers.count
        for layer in droppedLayers {
            targetState.insert(
                SequenceLayerState.Item(layer: layer, offset: .zero, hidden: false),
                at: targetState.layers.count
            )
        }

        applySequenceState(targetState, toRecordAt: targetIndex)
        refreshExpansionState(forRecordID: targetRecordID)
        pendingSelectedLayerIndex = insertionIndex
        selectedSidebarLayerIndex = insertionIndex
        selectedFileID = targetRecordID
        statusMessage = "\(droppedLayers.count) layer(s) added."
    }

    func moveFileRecord(
        from sourceRecordID: UUID,
        toFolder folderURL: URL,
        insertionIndex: Int
    ) {
        let standardizedFolderURL = folderURL.standardizedFileURL
        let folderIndices = files.indices.filter { files[$0].folderURL == standardizedFolderURL }

        guard
            let sourceFolderIndex = folderIndices.firstIndex(where: { files[$0].id == sourceRecordID }),
            !folderIndices.isEmpty
        else {
            return
        }

        var folderRecords = folderIndices.map { files[$0] }
        let movingRecord = folderRecords.remove(at: sourceFolderIndex)
        let rawDestination = max(0, min(insertionIndex, folderRecords.count + 1))
        let adjustedDestination = rawDestination > sourceFolderIndex ? rawDestination - 1 : rawDestination

        guard adjustedDestination != sourceFolderIndex else {
            return
        }

        folderRecords.insert(movingRecord, at: adjustedDestination)

        var replacementIterator = folderRecords.makeIterator()
        for globalIndex in folderIndices {
            if let replacement = replacementIterator.next() {
                files[globalIndex] = replacement
            }
        }

        statusMessage = "\(movingRecord.displayName) moved."
    }

    func togglePreview() {
        previewEnabled.toggle()
    }

    func nextFile() {
        guard let currentFileIndex, currentFileIndex < files.count - 1 else {
            return
        }
        selectedSidebarLayerIndex = nil
        selectedFileID = files[currentFileIndex + 1].id
    }

    func nextFileWrapping() {
        guard !files.isEmpty else {
            return
        }

        guard let currentFileIndex else {
            selectedSidebarLayerIndex = nil
            selectedFileID = files.first?.id
            return
        }

        let nextIndex = (currentFileIndex + 1) % files.count
        selectedSidebarLayerIndex = nil
        selectedFileID = files[nextIndex].id
    }

    func previousFile() {
        guard let currentFileIndex, currentFileIndex > 0 else {
            return
        }
        selectedSidebarLayerIndex = nil
        selectedFileID = files[currentFileIndex - 1].id
    }

    func previousFileWrapping() {
        guard !files.isEmpty else {
            return
        }

        guard let currentFileIndex else {
            selectedSidebarLayerIndex = nil
            selectedFileID = files.last?.id
            return
        }

        let previousIndex = (currentFileIndex - 1 + files.count) % files.count
        selectedSidebarLayerIndex = nil
        selectedFileID = files[previousIndex].id
    }

    func saveCurrent(format: ExportFormat, advanceAfterSave: Bool = false) {
        guard let sequence = currentSequence, let currentFile else {
            errorMessage = "No photo is currently open."
            return
        }

        let outputFolder = resolvedOutputDirectory(for: currentFile.url)

        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

            let outputURL = outputFolder
                .appendingPathComponent(currentFile.url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension(format.filenameExtension)

            try MPOExporter.export(
                sequence: sequence,
                offsets: currentLayerOffsets,
                visibleLayerIndices: currentVisibleLayerIndices,
                selectedLayerIndex: selectedLayerIndex,
                playbackPattern: playbackPattern,
                format: format,
                duration: gifDuration,
                maxDimension: exportSizePreset.maxDimension,
                outputURL: outputURL
            )

            if let index = currentFileIndex {
                files[index].exportedFormats.insert(format)
            }

            showToast("\(format.label) saved")
            statusMessage = "\(format.label) saved to \(outputURL.path)."

            if advanceAfterSave {
                nextFile()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func increaseDuration() {
        gifDuration = min(gifDuration + 0.05, 1.00)
    }

    func decreaseDuration() {
        gifDuration = max(gifDuration - 0.05, 0.05)
    }

    func increaseZoom() {
        canvasZoom = min(canvasZoom + 0.25, 8.0)
    }

    func decreaseZoom() {
        canvasZoom = max(canvasZoom - 0.25, 1.0)
    }

    func resetZoom() {
        canvasZoom = 1.0
    }

    private func importFiles(
        _ urls: [URL],
        expandedFolders: Set<String>,
        allowLooseJPEGSequence: Bool,
        preferExplicitJPEGSelectionGrouping: Bool
    ) {
        let records = Self.buildImportRecords(
            from: urls,
            allowLooseJPEGSequence: allowLooseJPEGSequence,
            preferExplicitJPEGSelectionGrouping: preferExplicitJPEGSelectionGrouping
        )


        guard !records.isEmpty else {
            errorMessage = "Select at least one MPO, JPEG, or PNG file."
            return
        }

        let existingIdentities = Set(files.map(\.importIdentity))
        let newRecords = records.filter { !existingIdentities.contains($0.importIdentity) }

        guard !newRecords.isEmpty else {
            statusMessage = "The selected files are already in the list."
            return
        }

        insertRecordsPreservingFolderSections(newRecords)
        expandedFolderPaths.formUnion(expandedFolders)
        expandedFolderPaths.formUnion(newRecords.map { $0.folderURL.path })
        expandedSequenceIDs.formUnion(
            newRecords
                .filter { $0.hasBrowsableLayers }
                .map(\.id)
        )

        if selectedFileID == nil {
            selectedFileID = files.first?.id
        } else {
            statusMessage = "\(newRecords.count) item(s) added."
        }
    }

    private func loadSelectedFile() {
        previewEnabled = false
        loadTask?.cancel()
        loadTask = nil

        guard let currentFile else {
            currentSequence = nil
            isLoadingSequence = false
            currentOffset = .zero
            selectedLayerIndex = 0
            selectedSidebarLayerIndex = nil
            return
        }

        if currentFile.isEmptySequence {
            canvasZoom = 1.0
            currentSequence = nil
            isLoadingSequence = false
            currentOffset = .zero
            selectedLayerIndex = 0
            selectedSidebarLayerIndex = nil
            playbackPattern = currentFile.playbackPattern
            statusMessage = "\(currentFile.displayName) is ready. Drag photos into it."
            return
        }

        canvasZoom = 1.0
        currentSequence = nil
        isLoadingSequence = true
        statusMessage = "Opening \(currentFile.displayName)..."

        let fileID = currentFile.id
        let source = currentFile.source
        let displayName = currentFile.displayName

        loadTask = Task.detached(priority: .userInitiated) {
            do {
                let images = try MPOImageLoader.loadFrameImages(from: source)
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run { [weak self] in
                    guard let self, self.selectedFileID == fileID else {
                        return
                    }

                    currentSequence = buildFrameSequence(from: images)
                    isLoadingSequence = false

                    if let index = currentFileIndex {
                        playbackPattern = files[index].playbackPattern
                    }

                    syncSelectionWithVisibleLayers()
                    statusMessage = "Editing \(displayName)."
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run { [weak self] in
                    guard let self, self.selectedFileID == fileID else {
                        return
                    }

                    currentSequence = nil
                    isLoadingSequence = false
                    errorMessage = "Could not open \(displayName): \(error.localizedDescription)"
                }
            }
        }
    }

    private func loadSelectedLayerOffset() {
        guard let currentFile else {
            currentOffset = .zero
            return
        }

        let frameCount = currentFrameCount
        guard
            selectedLayerIndex >= 0,
            selectedLayerIndex < max(frameCount, 1),
            currentFile.isLayerVisible(selectedLayerIndex)
        else {
            currentOffset = .zero
            return
        }

        currentOffset = currentFile.layerOffsets[selectedLayerIndex] ?? .zero
    }

    private func syncOffsetIntoCurrentFile() {
        guard let index = currentFileIndex else {
            return
        }

        files[index].layerOffsets[selectedLayerIndex] = currentOffset
    }

    private func syncPlaybackPatternIntoCurrentFile() {
        guard let index = currentFileIndex else {
            return
        }

        files[index].playbackPattern = playbackPattern
    }

    private func offsets(for record: MPOFileRecord?, frameCount: Int) -> [PixelOffset] {
        guard let record else {
            return []
        }

        return (0..<frameCount).map { record.layerOffsets[$0] ?? .zero }
    }

    private func visibleLayerIndices(for record: MPOFileRecord?, frameCount: Int) -> [Int] {
        guard let record else {
            return []
        }

        let visible = record.visibleLayerIndices(frameCount: frameCount)
        if visible.isEmpty, frameCount > 0 {
            return [0]
        }
        return visible
    }

    private func syncSelectionWithVisibleLayers() {
        guard let currentFile else {
            selectedLayerIndex = 0
            currentOffset = .zero
            pendingSelectedLayerIndex = nil
            return
        }

        let visibleIndices = visibleLayerIndices(for: currentFile, frameCount: currentFrameCount)
        guard let firstVisible = visibleIndices.first else {
            selectedLayerIndex = 0
            currentOffset = .zero
            pendingSelectedLayerIndex = nil
            return
        }

        let preferredSelection = pendingSelectedLayerIndex
        let nextSelection: Int

        if let preferredSelection, visibleIndices.contains(preferredSelection) {
            nextSelection = preferredSelection
        } else if visibleIndices.contains(selectedLayerIndex) {
            nextSelection = selectedLayerIndex
        } else if visibleIndices.count > 1, let firstNonBase = visibleIndices.first(where: { $0 != 0 }) {
            nextSelection = firstNonBase
        } else {
            nextSelection = firstVisible
        }

        pendingSelectedLayerIndex = nil
        selectedLayerIndex = nextSelection
        if selectedSidebarLayerIndex != nil {
            selectedSidebarLayerIndex = nextSelection
        }
        currentOffset = currentFile.layerOffsets[nextSelection] ?? .zero
    }

    private func resolvedOutputDirectory(for currentFileURL: URL) -> URL {
        if let outputDirectory {
            return outputDirectory
        }

        return currentFileURL.deletingLastPathComponent()
    }

    private func rebuildPreviewSequenceIfNeeded() {
        guard let sequence = currentSequence, !isLoadingSequence else {
            return
        }

        currentSequence = buildFrameSequence(from: sequence.layers.map(\.cgImage))
    }

    private func buildFrameSequence(from images: [CGImage]) -> FrameSequence {
        FrameSequence(
            images: images,
            previewMaxDimension: previewProxyMaxDimension,
            interactiveMaxDimension: interactiveProxyMaxDimension
        )
    }

    private var preferredEmptyGroupingFolderURL: URL {
        if let currentFile {
            return currentFile.folderURL
        }

        if let outputDirectory {
            return outputDirectory.standardizedFileURL
        }

        if let firstFile = files.first {
            return firstFile.folderURL
        }

        return Self.emptyGroupingShelfURL
    }

    private func uniqueEmptyGroupingName(in folderURL: URL) -> String {
        let baseName = "Composition"
        let normalizedExistingNames = Set(
            files
                .filter { $0.folderURL == folderURL }
                .map { $0.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        )

        var candidate = baseName
        var suffix = 2

        while normalizedExistingNames.contains(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            candidate = "\(baseName) \(suffix)"
            suffix += 1
        }

        return candidate
    }

    private func insertRecordsPreservingFolderSections(_ records: [MPOFileRecord]) {
        guard !records.isEmpty else {
            return
        }

        let orderedFolderURLs = records.reduce(into: [URL]()) { result, record in
            if !result.contains(record.folderURL) {
                result.append(record.folderURL)
            }
        }

        for folderURL in orderedFolderURLs {
            let folderRecords = records.filter { $0.folderURL == folderURL }

            if let lastIndex = files.lastIndex(where: { $0.folderURL == folderURL }) {
                files.insert(contentsOf: folderRecords, at: lastIndex + 1)
                continue
            }

            if let insertionIndex = insertionIndexForNewFolderSection(folderURL) {
                files.insert(contentsOf: folderRecords, at: insertionIndex)
            } else {
                files.append(contentsOf: folderRecords)
            }
        }
    }

    private func insertionIndexForNewFolderSection(_ folderURL: URL) -> Int? {
        let existingFolders = files.reduce(into: [URL]()) { result, record in
            if !result.contains(record.folderURL) {
                result.append(record.folderURL)
            }
        }

        for existingFolder in existingFolders {
            if folderURL.path.localizedCaseInsensitiveCompare(existingFolder.path) == .orderedAscending,
               let firstIndex = files.firstIndex(where: { $0.folderURL == existingFolder }) {
                return firstIndex
            }
        }

        return nil
    }

    private func showToast(_ message: String, durationNanoseconds: UInt64 = 1_600_000_000) {
        toastDismissTask?.cancel()

        withAnimation(.easeOut(duration: 0.18)) {
            toastMessage = message
        }

        toastDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: durationNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            withAnimation(.easeIn(duration: 0.18)) {
                self?.toastMessage = nil
            }
        }
    }

    private var previewProxyMaxDimension: CGFloat {
        guard let exportMax = exportSizePreset.maxDimension else {
            return 1600
        }

        return CGFloat(min(exportMax, 1600))
    }

    private var interactiveProxyMaxDimension: CGFloat {
        guard let exportMax = exportSizePreset.maxDimension else {
            return 960
        }

        return CGFloat(min(exportMax, 960))
    }

    private func sequenceState(for record: MPOFileRecord) -> SequenceLayerState? {
        switch record.source {
        case .layerStack(_, _, let layers, _):
            let offsets = (0..<layers.count).map { record.layerOffsets[$0] ?? .zero }
            let hidden = (0..<layers.count).map { record.hiddenLayerIndices.contains($0) }
            return SequenceLayerState(layers: layers, offsets: offsets, hidden: hidden)
        case .emptySequence:
            return SequenceLayerState(layers: [], offsets: [], hidden: [])
        }
    }

    private func applySequenceState(_ state: SequenceLayerState, toRecordAt index: Int) {
        let folderURL = files[index].folderURL
        let preservedNameOverride: String?
        switch files[index].source {
        case .layerStack(let nameOverride, _, _, _):
            preservedNameOverride = nameOverride
        case .emptySequence(let name, _):
            preservedNameOverride = name
        }

        if state.layers.isEmpty, let preservedNameOverride {
            files[index].source = .emptySequence(name: preservedNameOverride, folderURL: folderURL)
        } else {
            files[index].source = .layerStack(
                nameOverride: preservedNameOverride,
                folderURL: folderURL,
                layers: state.layers,
                preferredPrimaryURL: preservedNameOverride == nil ? state.layers.first?.backingURL : nil
            )
        }
        files[index].layerOffsets = Dictionary(
            uniqueKeysWithValues: state.offsets.enumerated().compactMap { item in
                item.element == .zero ? nil : (item.offset, item.element)
            }
        )
        files[index].hiddenLayerIndices = Set(
            state.hidden.enumerated().compactMap { item in
                item.element ? item.offset : nil
            }
        )
    }

    private func refreshExpansionState(forRecordID recordID: UUID) {
        guard let record = files.first(where: { $0.id == recordID }) else {
            expandedSequenceIDs.remove(recordID)
            return
        }

        if record.hasBrowsableLayers {
            expandedSequenceIDs.insert(recordID)
        } else {
            expandedSequenceIDs.remove(recordID)
        }
    }

    nonisolated private static func buildImportRecords(
        from urls: [URL],
        allowLooseJPEGSequence: Bool,
        preferExplicitJPEGSelectionGrouping: Bool
    ) -> [MPOFileRecord] {
        let standardized = urls
            .filter(isSupportedImportURL(_:))
            .map { $0.standardizedFileURL }

        let groupedByFolder = Dictionary(grouping: standardized) {
            $0.deletingLastPathComponent().standardizedFileURL
        }

        return groupedByFolder.keys
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            .flatMap { folderURL in
                buildFolderRecords(
                    from: groupedByFolder[folderURL, default: []].sorted(by: sortURL),
                    allowLooseJPEGSequence: allowLooseJPEGSequence,
                    preferExplicitJPEGSelectionGrouping: preferExplicitJPEGSelectionGrouping
                )
            }
    }

    nonisolated private static func buildFolderRecords(
        from urls: [URL],
        allowLooseJPEGSequence: Bool,
        preferExplicitJPEGSelectionGrouping: Bool
    ) -> [MPOFileRecord] {
        guard let folderURL = urls.first?.deletingLastPathComponent().standardizedFileURL else {
            return []
        }

        let mpoURLs = urls.filter(isMPOURL(_:))
        let stillImageURLs = urls.filter(isStillImageURL(_:))

        var records = mpoURLs.map { importedMPORecord(for: $0, folderURL: folderURL) }
        records.append(
            contentsOf: buildStillImageRecords(
                from: stillImageURLs,
                folderURL: folderURL,
                allowLooseJPEGSequence: allowLooseJPEGSequence,
                preferExplicitJPEGSelectionGrouping: preferExplicitJPEGSelectionGrouping
            )
        )
        return records
    }

    nonisolated private static func buildStillImageRecords(
        from urls: [URL],
        folderURL: URL,
        allowLooseJPEGSequence: Bool,
        preferExplicitJPEGSelectionGrouping: Bool
    ) -> [MPOFileRecord] {
        guard !urls.isEmpty else {
            return []
        }

        if preferExplicitJPEGSelectionGrouping, urls.count > 1 {
            return [importedStillImageRecord(for: urls, folderURL: folderURL)]
        }

        if allowLooseJPEGSequence, urls.count > 1, !urls.contains(where: { isExplicitBurstJPEG($0) }) {
            return [importedStillImageRecord(for: urls, folderURL: folderURL)]
        }

        let candidates = urls.map(makeJPEGSequenceCandidate(for:))
        let runs = buildJPEGRuns(from: candidates)

        var records: [MPOFileRecord] = []

        for run in runs {
            if run.count == 1, let onlyURL = run.first?.url {
                records.append(importedStillImageRecord(for: [onlyURL], folderURL: folderURL))
                continue
            }

            if run.first?.isExplicitBurst == true {
                records.append(importedStillImageRecord(for: run.map(\.url), folderURL: folderURL))
                continue
            }

            for chunk in splitHeuristicJPEGRun(run) {
                let urls = chunk.map(\.url)
                if urls.count == 1 {
                    records.append(importedStillImageRecord(for: [urls[0]], folderURL: folderURL))
                } else {
                    records.append(importedStillImageRecord(for: urls, folderURL: folderURL))
                }
            }
        }

        return records
    }

    nonisolated private static func importedMPORecord(for url: URL, folderURL: URL) -> MPOFileRecord {
        MPOFileRecord(
            source: .layerStack(
                nameOverride: nil,
                folderURL: folderURL,
                layers: layerSources(forImportedURL: url),
                preferredPrimaryURL: url.standardizedFileURL
            )
        )
    }

    nonisolated private static func importedStillImageRecord(for urls: [URL], folderURL: URL) -> MPOFileRecord {
        MPOFileRecord(
            source: .layerStack(
                nameOverride: nil,
                folderURL: folderURL,
                layers: urls.map { LayerSource.file($0.standardizedFileURL) },
                preferredPrimaryURL: urls.first?.standardizedFileURL
            )
        )
    }

    nonisolated private static func layerSources(forImportedURL url: URL) -> [LayerSource] {
        let standardizedURL = url.standardizedFileURL
        if isMPOURL(standardizedURL) {
            return [
                .mpoFrame(fileURL: standardizedURL, frameIndex: 0),
                .mpoFrame(fileURL: standardizedURL, frameIndex: 1),
            ]
        }

        if isStillImageURL(standardizedURL) {
            return [.file(standardizedURL)]
        }

        return []
    }

    nonisolated private static func buildDroppedLayerSources(from urls: [URL]) -> [LayerSource] {
        let standardized = urls.map { $0.standardizedFileURL }
        var fileURLs: [URL] = []

        for url in standardized {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                fileURLs.append(contentsOf: contents.filter(isSupportedImportURL(_:)).sorted(by: sortURL))
            } else if isSupportedImportURL(url) {
                fileURLs.append(url)
            }
        }

        return fileURLs.flatMap(layerSources(forImportedURL:))
    }

    nonisolated private static func isExplicitBurstJPEG(_ url: URL) -> Bool {
        guard isJPEGURL(url) else {
            return false
        }

        let fileName = url.deletingPathExtension().lastPathComponent.uppercased()
        guard fileName.hasPrefix("_S"), fileName.count == 8 else {
            return false
        }

        let digits = String(fileName.dropFirst(2))
        return digits.count == 6 && digits.allSatisfy(\.isNumber)
    }

    nonisolated private static func makeJPEGSequenceCandidate(for url: URL) -> JPEGSequenceCandidate {
        let stem = url.deletingPathExtension().lastPathComponent
        let split = stem.splitNumericSuffix()

        return JPEGSequenceCandidate(
            url: url,
            prefix: split.prefix.uppercased(),
            numericSuffix: split.numericSuffix,
            captureDate: jpegCaptureDate(for: url),
            isExplicitBurst: isExplicitBurstJPEG(url)
        )
    }

    nonisolated private static func buildJPEGRuns(from candidates: [JPEGSequenceCandidate]) -> [[JPEGSequenceCandidate]] {
        guard !candidates.isEmpty else {
            return []
        }

        var runs: [[JPEGSequenceCandidate]] = []
        var currentRun: [JPEGSequenceCandidate] = [candidates[0]]

        for candidate in candidates.dropFirst() {
            if let previous = currentRun.last, shouldContinueJPEGRun(after: previous, with: candidate) {
                currentRun.append(candidate)
            } else {
                runs.append(currentRun)
                currentRun = [candidate]
            }
        }

        runs.append(currentRun)
        return runs
    }

    nonisolated private static func shouldContinueJPEGRun(
        after previous: JPEGSequenceCandidate,
        with next: JPEGSequenceCandidate
    ) -> Bool {
        guard previous.prefix == next.prefix else {
            return false
        }

        guard
            let previousSuffix = previous.numericSuffix,
            let nextSuffix = next.numericSuffix,
            nextSuffix == previousSuffix + 1
        else {
            return false
        }

        guard let previousDate = previous.captureDate, let nextDate = next.captureDate else {
            return true
        }

        return nextDate.timeIntervalSince(previousDate) <= jpegSequenceMaxGap
    }

    nonisolated private static func splitHeuristicJPEGRun(_ run: [JPEGSequenceCandidate]) -> [[JPEGSequenceCandidate]] {
        let sizes = heuristicJPEGGroupSizes(for: run.count)
        guard !sizes.isEmpty else {
            return []
        }

        var groups: [[JPEGSequenceCandidate]] = []
        var cursor = 0

        for size in sizes {
            let end = min(cursor + size, run.count)
            groups.append(Array(run[cursor..<end]))
            cursor = end
        }

        return groups
    }

    nonisolated private static func heuristicJPEGGroupSizes(for count: Int) -> [Int] {
        guard count > 0 else {
            return []
        }

        if count == 1 {
            return [1]
        }

        if count == 2 {
            return [2]
        }

        var sizes = Array(repeating: heuristicJPEGSequenceGroupSize, count: count / heuristicJPEGSequenceGroupSize)
        let remainder = count % heuristicJPEGSequenceGroupSize

        if remainder == 0 {
            return sizes
        }

        if remainder == 1, let lastIndex = sizes.indices.last {
            sizes[lastIndex] = 2
            sizes.append(2)
            return sizes
        }

        sizes.append(remainder)
        return sizes
    }

    nonisolated private static func jpegCaptureDate(for url: URL) -> Date? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }

        if
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
            let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String,
            let date = jpegDateFormatter.date(from: original)
        {
            return date
        }

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    nonisolated private static func isSupportedImportURL(_ url: URL) -> Bool {
        isMPOURL(url) || isStillImageURL(url)
    }

    nonisolated private static func isMPOURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "mpo"
    }

    nonisolated private static func isStillImageURL(_ url: URL) -> Bool {
        isJPEGURL(url) || isPNGURL(url)
    }

    nonisolated private static func isJPEGURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "jpg" || ext == "jpeg"
    }

    nonisolated private static func isPNGURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "png"
    }

    nonisolated private static func sortURL(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsFolder = lhs.deletingLastPathComponent().path
        let rhsFolder = rhs.deletingLastPathComponent().path

        let folderCompare = lhsFolder.localizedCaseInsensitiveCompare(rhsFolder)
        if folderCompare != .orderedSame {
            return folderCompare == .orderedAscending
        }

        return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
    }

    nonisolated private static func sortRecord(_ lhs: MPOFileRecord, _ rhs: MPOFileRecord) -> Bool {
        sortURL(lhs.url, rhs.url)
    }

    nonisolated private static let emptyGroupingShelfURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("mpo3d Groups", isDirectory: true)
        .standardizedFileURL

    nonisolated private static let jpegSequenceMaxGap: TimeInterval = 30
    nonisolated private static let heuristicJPEGSequenceGroupSize = 3
    nonisolated private static let jpegDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

private struct JPEGSequenceCandidate {
    let url: URL
    let prefix: String
    let numericSuffix: Int?
    let captureDate: Date?
    let isExplicitBurst: Bool
}

private struct SequenceLayerState {
    struct Item {
        let layer: LayerSource
        let offset: PixelOffset
        let hidden: Bool
    }

    var layers: [LayerSource]
    var offsets: [PixelOffset]
    var hidden: [Bool]

    var items: [Item] {
        layers.enumerated().map { index, layer in
            Item(
                layer: layer,
                offset: offsets[index],
                hidden: hidden[index]
            )
        }
    }

    mutating func remove(at index: Int) -> Item {
        let item = Item(
            layer: layers.remove(at: index),
            offset: offsets.remove(at: index),
            hidden: hidden.remove(at: index)
        )
        return item
    }

    mutating func insert(_ item: Item, at index: Int) {
        let clampedIndex = max(0, min(index, layers.count))
        layers.insert(item.layer, at: clampedIndex)
        offsets.insert(item.offset, at: clampedIndex)
        hidden.insert(item.hidden, at: clampedIndex)
    }
}

private extension String {
    func splitNumericSuffix() -> (prefix: String, numericSuffix: Int?) {
        guard let lastNonDigit = lastIndex(where: { !$0.isNumber }) else {
            return ("", Int(self))
        }

        let suffixStart = index(after: lastNonDigit)
        guard suffixStart < endIndex else {
            return (self, nil)
        }

        let prefix = String(self[..<suffixStart])
        let suffix = String(self[suffixStart...])
        return (prefix, Int(suffix))
    }
}
