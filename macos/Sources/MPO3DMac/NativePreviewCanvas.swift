import AppKit
import SwiftUI

private struct ZoomAnchor {
    let ratioX: CGFloat
    let ratioY: CGFloat
    let locationInClipView: CGPoint
}

struct NativePreviewCanvas: NSViewRepresentable {
    let sequence: FrameSequence
    let offsets: [PixelOffset]
    let visibleLayerIndices: [Int]
    @Binding var offset: PixelOffset
    let selectedLayerIndex: Int
    @Binding var zoom: Double
    let previewEnabled: Bool
    let frameDuration: Double
    let playbackPattern: PlaybackPattern
    let fittedSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(offset: $offset, zoom: $zoom)
    }

    func makeNSView(context: Context) -> ManualPreviewScrollView {
        let scrollView = ManualPreviewScrollView()
        let hostView = PreviewCanvasHostView()
        let documentView = ManualPreviewDocumentView()

        hostView.documentView = documentView
        scrollView.documentView = hostView

        context.coordinator.attach(
            scrollView: scrollView,
            hostView: hostView,
            documentView: documentView
        )

        return scrollView
    }

    func updateNSView(_ scrollView: ManualPreviewScrollView, context: Context) {
        context.coordinator.offsetBinding = $offset
        context.coordinator.zoomBinding = $zoom
        context.coordinator.update(
            sequence: sequence,
            offsets: offsets,
            visibleLayerIndices: visibleLayerIndices,
            selectedLayerIndex: selectedLayerIndex,
            zoom: zoom,
            previewEnabled: previewEnabled,
            frameDuration: frameDuration,
            playbackPattern: playbackPattern,
            fittedSize: fittedSize
        )
    }

    static func dismantleNSView(_ scrollView: ManualPreviewScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var offsetBinding: Binding<PixelOffset>
        var zoomBinding: Binding<Double>

        private weak var scrollView: ManualPreviewScrollView?
        private weak var hostView: PreviewCanvasHostView?
        private weak var documentView: ManualPreviewDocumentView?
        private weak var magnificationRecognizer: NSMagnificationGestureRecognizer?

        private var currentSequence: FrameSequence?
        private var currentOffsets: [PixelOffset] = []
        private var currentVisibleLayerIndices: [Int] = []
        private var currentSelectedLayerIndex = 0
        private var currentZoom: Double = 1.0
        private var currentPreviewEnabled = false
        private var currentFrameDuration: Double = 0.20
        private var currentPlaybackPattern: PlaybackPattern = .loop
        private var currentFittedSize: CGSize = .zero
        private var isLiveZooming = false
        private var gestureStartZoom: Double?
        private var lastGestureAnchor: ZoomAnchor?

        init(offset: Binding<PixelOffset>, zoom: Binding<Double>) {
            self.offsetBinding = offset
            self.zoomBinding = zoom
        }

        func attach(
            scrollView: ManualPreviewScrollView,
            hostView: PreviewCanvasHostView,
            documentView: ManualPreviewDocumentView
        ) {
            self.scrollView = scrollView
            self.hostView = hostView
            self.documentView = documentView

            documentView.onOffsetCommit = { [weak self] finalOffset in
                guard let self else {
                    return
                }

                if offsetBinding.wrappedValue != finalOffset {
                    offsetBinding.wrappedValue = finalOffset
                }
            }

            scrollView.onLayoutChange = { [weak self] in
                self?.refreshLayout(anchor: nil, preserveVisibleCenter: true)
            }

            let recognizer = NSMagnificationGestureRecognizer(
                target: self,
                action: #selector(handleMagnification(_:))
            )
            scrollView.contentView.addGestureRecognizer(recognizer)
            self.magnificationRecognizer = recognizer
        }

        func detach() {
            if let magnificationRecognizer, let scrollView {
                scrollView.contentView.removeGestureRecognizer(magnificationRecognizer)
            }

            scrollView?.onLayoutChange = nil
            documentView?.onOffsetCommit = nil
            documentView?.stopPreview()
        }

        func update(
            sequence: FrameSequence,
            offsets: [PixelOffset],
            visibleLayerIndices: [Int],
            selectedLayerIndex: Int,
            zoom: Double,
            previewEnabled: Bool,
            frameDuration: Double,
            playbackPattern: PlaybackPattern,
            fittedSize: CGSize
        ) {
            let sequenceChanged = currentSequence.map { ObjectIdentifier($0.layers[0].fullImage) } != ObjectIdentifier(sequence.layers[0].fullImage)

            currentSequence = sequence
            currentOffsets = normalizedOffsets(offsets, frameCount: sequence.frameCount)
            currentVisibleLayerIndices = normalizedVisibleLayerIndices(visibleLayerIndices, frameCount: sequence.frameCount)
            currentSelectedLayerIndex = min(max(selectedLayerIndex, 0), max(sequence.frameCount - 1, 0))
            currentZoom = clampedZoom(zoom)
            currentPreviewEnabled = previewEnabled
            currentFrameDuration = frameDuration
            currentPlaybackPattern = playbackPattern
            currentFittedSize = fittedSize

            let canvasBackgroundColor = PreviewCanvasPalette.background
            scrollView?.backgroundColor = canvasBackgroundColor
            hostView?.backgroundColor = canvasBackgroundColor

            documentView?.update(
                sequence: sequence,
                offsets: currentOffsets,
                visibleLayerIndices: currentVisibleLayerIndices,
                selectedLayerIndex: currentSelectedLayerIndex,
                zoom: currentZoom,
                previewEnabled: previewEnabled,
                frameDuration: frameDuration,
                playbackPattern: playbackPattern,
                liveZooming: isLiveZooming
            )

            refreshLayout(anchor: nil, preserveVisibleCenter: !sequenceChanged)
        }

        @objc
        private func handleMagnification(_ recognizer: NSMagnificationGestureRecognizer) {
            guard currentSequence != nil else {
                return
            }

            switch recognizer.state {
            case .began:
                gestureStartZoom = currentZoom
                lastGestureAnchor = currentZoomAnchor()
                isLiveZooming = true
                documentView?.setLiveZooming(true)

            case .changed:
                applyGestureZoom(recognizer)

            case .ended, .cancelled:
                applyGestureZoom(recognizer)
                let finalAnchor = lastGestureAnchor
                gestureStartZoom = nil
                isLiveZooming = false
                documentView?.setLiveZooming(false)
                refreshLayout(anchor: finalAnchor, preserveVisibleCenter: false)
                if abs(zoomBinding.wrappedValue - currentZoom) > 0.0005 {
                    zoomBinding.wrappedValue = currentZoom
                }
                lastGestureAnchor = nil

            default:
                break
            }
        }

        private func applyGestureZoom(_ recognizer: NSMagnificationGestureRecognizer) {
            guard
                let scrollView,
                let hostView,
                let documentView,
                let currentSequence
            else {
                return
            }

            let anchor = currentZoomAnchor(
                scrollView: scrollView,
                hostView: hostView,
                documentView: documentView
            )
            lastGestureAnchor = anchor

            let baseZoom = gestureStartZoom ?? currentZoom
            let nextZoom = clampedZoom(baseZoom * (1 + Double(recognizer.magnification)))

            currentZoom = nextZoom

            documentView.update(
                sequence: currentSequence,
                offsets: currentOffsets,
                visibleLayerIndices: currentVisibleLayerIndices,
                selectedLayerIndex: currentSelectedLayerIndex,
                zoom: nextZoom,
                previewEnabled: currentPreviewEnabled,
                frameDuration: currentFrameDuration,
                playbackPattern: currentPlaybackPattern,
                liveZooming: isLiveZooming
            )

            refreshLayout(anchor: anchor, preserveVisibleCenter: false)
        }

        private func normalizedOffsets(_ offsets: [PixelOffset], frameCount: Int) -> [PixelOffset] {
            (0..<frameCount).map { index in
                index < offsets.count ? offsets[index] : .zero
            }
        }

        private func normalizedVisibleLayerIndices(_ indices: [Int], frameCount: Int) -> [Int] {
            let filtered = indices.filter { $0 >= 0 && $0 < frameCount }
            return filtered.isEmpty ? [0] : filtered
        }

        private func currentZoomAnchor() -> ZoomAnchor? {
            guard
                let scrollView,
                let hostView,
                let documentView
            else {
                return nil
            }

            return currentZoomAnchor(
                scrollView: scrollView,
                hostView: hostView,
                documentView: documentView
            )
        }

        private func currentZoomAnchor(
            scrollView: ManualPreviewScrollView,
            hostView: PreviewCanvasHostView,
            documentView: ManualPreviewDocumentView
        ) -> ZoomAnchor {
            let clipView = scrollView.contentView
            let clipBounds = clipView.bounds
            let fallbackViewportPoint = CGPoint(
                x: clipBounds.width * 0.5,
                y: clipBounds.height * 0.5
            )
            let fallbackRawClipPoint = CGPoint(
                x: clipBounds.midX,
                y: clipBounds.midY
            )

            let rawPointInClipView: CGPoint = {
                guard let windowPoint = scrollView.window?.mouseLocationOutsideOfEventStream else {
                    return fallbackRawClipPoint
                }

                let convertedPoint = clipView.convert(windowPoint, from: nil)
                return CGPoint(
                    x: min(max(convertedPoint.x, clipBounds.minX), clipBounds.maxX),
                    y: min(max(convertedPoint.y, clipBounds.minY), clipBounds.maxY)
                )
            }()

            let locationInClipView = CGPoint(
                x: min(max(rawPointInClipView.x - clipBounds.minX, 0), clipBounds.width),
                y: min(max(rawPointInClipView.y - clipBounds.minY, 0), clipBounds.height)
            )
            let resolvedClipPoint = clipBounds.isEmpty ? fallbackViewportPoint : locationInClipView
            let locationInHostView = hostView.convert(rawPointInClipView, from: clipView)
            let locationInDocument = documentView.convert(locationInHostView, from: hostView)
            let documentBounds = documentView.bounds
            let documentWidth = max(documentBounds.width, 1)
            let documentHeight = max(documentBounds.height, 1)

            return ZoomAnchor(
                ratioX: max(0, min(locationInDocument.x / documentWidth, 1)),
                ratioY: max(0, min(locationInDocument.y / documentHeight, 1)),
                locationInClipView: resolvedClipPoint
            )
        }

        private func refreshLayout(anchor: ZoomAnchor?, preserveVisibleCenter: Bool) {
            guard
                let scrollView,
                let hostView,
                let documentView
            else {
                return
            }

            let viewportSize = CGSize(
                width: max(scrollView.contentSize.width, 1),
                height: max(scrollView.contentSize.height, 1)
            )
            let documentSize = CGSize(
                width: max(currentFittedSize.width * currentZoom, 1),
                height: max(currentFittedSize.height * currentZoom, 1)
            )

            let previousHostSize = hostView.frame.size
            let previousVisibleRect = scrollView.documentVisibleRect
            let previousCenterRatio: CGPoint?
            if preserveVisibleCenter, previousHostSize.width > 0, previousHostSize.height > 0 {
                previousCenterRatio = CGPoint(
                    x: previousVisibleRect.midX / previousHostSize.width,
                    y: previousVisibleRect.midY / previousHostSize.height
                )
            } else {
                previousCenterRatio = nil
            }

            let hostSize = CGSize(
                width: max(viewportSize.width, documentSize.width),
                height: max(viewportSize.height, documentSize.height)
            )
            hostView.frame = CGRect(origin: .zero, size: hostSize)

            let documentOrigin = CGPoint(
                x: max((hostSize.width - documentSize.width) * 0.5, 0),
                y: max((hostSize.height - documentSize.height) * 0.5, 0)
            )
            documentView.frame = CGRect(origin: documentOrigin, size: documentSize)
            documentView.applyLayoutForCurrentState()

            if let anchor {
                let anchoredPoint = CGPoint(
                    x: documentOrigin.x + (anchor.ratioX * documentSize.width),
                    y: documentOrigin.y + (anchor.ratioY * documentSize.height)
                )

                scroll(
                    toKeep: anchoredPoint,
                    at: anchor.locationInClipView,
                    in: scrollView,
                    hostSize: hostSize,
                    viewportSize: viewportSize
                )
                return
            }

            if let previousCenterRatio {
                let anchoredCenter = CGPoint(
                    x: previousCenterRatio.x * hostSize.width,
                    y: previousCenterRatio.y * hostSize.height
                )
                scroll(
                    toKeep: anchoredCenter,
                    at: CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5),
                    in: scrollView,
                    hostSize: hostSize,
                    viewportSize: viewportSize
                )
                return
            }

            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func scroll(
            toKeep hostPoint: CGPoint,
            at clipPoint: CGPoint,
            in scrollView: NSScrollView,
            hostSize: CGSize,
            viewportSize: CGSize
        ) {
            let maxOffsetX = max(hostSize.width - viewportSize.width, 0)
            let maxOffsetY = max(hostSize.height - viewportSize.height, 0)

            let targetOrigin = CGPoint(
                x: min(max(hostPoint.x - clipPoint.x, 0), maxOffsetX),
                y: min(max(hostPoint.y - clipPoint.y, 0), maxOffsetY)
            )

            scrollView.contentView.scroll(to: targetOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func clampedZoom(_ value: Double) -> Double {
            min(max(value, 1.0), 8.0)
        }
    }
}

@MainActor
final class ManualPreviewScrollView: NSScrollView {
    var onLayoutChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func layout() {
        super.layout()
        onLayoutChange?()
    }

    private func configure() {
        drawsBackground = true
        backgroundColor = PreviewCanvasPalette.background
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        usesPredominantAxisScrolling = false
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .automatic
    }
}

@MainActor
final class PreviewCanvasHostView: NSView {
    weak var documentView: ManualPreviewDocumentView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let documentView {
                addSubview(documentView)
            }
        }
    }

    var backgroundColor: NSColor = PreviewCanvasPalette.background {
        didSet {
            wantsLayer = true
            layer?.backgroundColor = backgroundColor.cgColor
        }
    }

    override var isFlipped: Bool {
        true
    }
}

@MainActor
final class ManualPreviewDocumentView: NSView {
    var onOffsetCommit: ((PixelOffset) -> Void)?

    private var imageViews: [NSImageView] = []
    private var sequence: FrameSequence?
    private var currentOffsets: [PixelOffset] = []
    private var currentVisibleLayerIndices: [Int] = []
    private var currentSelectedLayerIndex = 0
    private var currentZoom: Double = 1.0
    private var currentPreviewEnabled = false
    private var currentFrameDuration: Double = 0.20
    private var currentPlaybackPattern: PlaybackPattern = .loop
    private var isLiveZooming = false
    private var previewFrameOrder: [Int] = []
    private var previewFrameOrderIndex = 0
    private var previewTimer: Timer?
    private var dragStartPoint: NSPoint?
    private var dragStartOffset: PixelOffset?

    override var isFlipped: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        sequence: FrameSequence,
        offsets: [PixelOffset],
        visibleLayerIndices: [Int],
        selectedLayerIndex: Int,
        zoom: Double,
        previewEnabled: Bool,
        frameDuration: Double,
        playbackPattern: PlaybackPattern,
        liveZooming: Bool
    ) {
        let previousSequenceIdentity = self.sequence.map { ObjectIdentifier($0.layers[0].fullImage) }
        let nextSequenceIdentity = ObjectIdentifier(sequence.layers[0].fullImage)
        let sequenceChanged = previousSequenceIdentity != nextSequenceIdentity || self.sequence?.frameCount != sequence.frameCount
        let modeChanged = currentPreviewEnabled != previewEnabled
        let durationChanged = abs(currentFrameDuration - frameDuration) > 0.0005
        let zoomChanged = abs(currentZoom - zoom) > 0.0005
        let offsetsChanged = currentOffsets != offsets
        let liveChanged = isLiveZooming != liveZooming
        let selectionChanged = currentSelectedLayerIndex != selectedLayerIndex
        let playbackPatternChanged = currentPlaybackPattern != playbackPattern

        self.sequence = sequence
        self.currentOffsets = offsets
        self.currentVisibleLayerIndices = visibleLayerIndices.isEmpty ? [0] : visibleLayerIndices
        self.currentSelectedLayerIndex = min(max(selectedLayerIndex, 0), max(sequence.frameCount - 1, 0))
        self.currentZoom = zoom
        self.currentPreviewEnabled = previewEnabled
        self.currentFrameDuration = frameDuration
        self.currentPlaybackPattern = playbackPattern
        self.isLiveZooming = liveZooming

        ensureImageViews(count: sequence.frameCount)
        updateDisplayedImages()

        if sequenceChanged {
            previewFrameOrderIndex = 0
        }

        if sequenceChanged || offsetsChanged || zoomChanged || liveChanged || selectionChanged {
            applyLayoutForCurrentState()
        }

        if sequenceChanged || modeChanged || durationChanged || liveChanged || playbackPatternChanged {
            configurePreviewPlayback(resetFrame: sequenceChanged || modeChanged || playbackPatternChanged)
        } else {
            applyDisplayState()
        }
    }

    func setLiveZooming(_ liveZooming: Bool) {
        guard isLiveZooming != liveZooming else {
            return
        }

        isLiveZooming = liveZooming
        updateDisplayedImages()
        applyLayoutForCurrentState()
        configurePreviewPlayback(resetFrame: false)
    }

    func applyLayoutForCurrentState() {
        guard let sequence, !sequence.layers.isEmpty else {
            return
        }

        let displaySize = bounds.size
        let baseSize = sequence.basePixelSize
        let baseScaleX = displaySize.width / max(baseSize.width, 1)
        let baseScaleY = displaySize.height / max(baseSize.height, 1)

        for (index, layer) in sequence.layers.enumerated() {
            let offset = index < currentOffsets.count ? currentOffsets[index] : .zero
            imageViews[index].frame = CGRect(
                x: CGFloat(offset.x) * baseScaleX,
                y: CGFloat(offset.y) * baseScaleY,
                width: layer.pixelSize.width * baseScaleX,
                height: layer.pixelSize.height * baseScaleY
            )
        }
    }

    func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = convert(event.locationInWindow, from: nil)
        dragStartOffset = currentOffsets[safe: currentSelectedLayerIndex] ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let sequence,
            let dragStartPoint,
            let dragStartOffset
        else {
            return
        }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let baseSize = sequence.basePixelSize
        let baseScaleX = bounds.width / max(baseSize.width, 1)
        let baseScaleY = bounds.height / max(baseSize.height, 1)

        let deltaX = Int(((currentPoint.x - dragStartPoint.x) / max(baseScaleX, 0.0001)).rounded())
        let deltaY = Int(((currentPoint.y - dragStartPoint.y) / max(baseScaleY, 0.0001)).rounded())
        let newOffset = PixelOffset(
            x: dragStartOffset.x + deltaX,
            y: dragStartOffset.y + deltaY
        )

        guard currentSelectedLayerIndex < currentOffsets.count else {
            return
        }

        guard newOffset != currentOffsets[currentSelectedLayerIndex] else {
            return
        }

        currentOffsets[currentSelectedLayerIndex] = newOffset
        applyLayoutForCurrentState()
    }

    override func mouseUp(with event: NSEvent) {
        dragStartPoint = nil
        dragStartOffset = nil
        guard currentSelectedLayerIndex < currentOffsets.count else {
            return
        }
        onOffsetCommit?(currentOffsets[currentSelectedLayerIndex])
    }

    private func ensureImageViews(count: Int) {
        if imageViews.count > count {
            for imageView in imageViews[count...] {
                imageView.removeFromSuperview()
            }
            imageViews.removeSubrange(count...)
        }

        while imageViews.count < count {
            let imageView = NSImageView()
            configureImageView(imageView)
            addSubview(imageView)
            imageViews.append(imageView)
        }
    }

    private func configureImageView(_ imageView: NSImageView) {
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignTopLeft
        imageView.animates = false
    }

    private func updateDisplayedImages() {
        guard let sequence else {
            return
        }

        for (index, layer) in sequence.layers.enumerated() where index < imageViews.count {
            imageViews[index].image = isLiveZooming ? layer.interactiveImage : layer.previewImage
        }
    }

    private func configurePreviewPlayback(resetFrame: Bool) {
        previewTimer?.invalidate()
        previewTimer = nil

        previewFrameOrder = currentPlaybackPattern.frameOrder(indices: currentVisibleLayerIndices)
        if previewFrameOrder.isEmpty {
            previewFrameOrder = [0]
        }

        if resetFrame || previewFrameOrderIndex >= previewFrameOrder.count {
            previewFrameOrderIndex = 0
        }

        guard currentPreviewEnabled else {
            applyDisplayState()
            return
        }

        applyDisplayState()

        guard !isLiveZooming, previewFrameOrder.count > 1 else {
            return
        }

        previewTimer = Timer.scheduledTimer(withTimeInterval: max(currentFrameDuration, 0.05), repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.previewFrameOrderIndex = (self.previewFrameOrderIndex + 1) % self.previewFrameOrder.count
                self.applyDisplayState()
            }
        }

        if let previewTimer {
            RunLoop.main.add(previewTimer, forMode: .common)
        }
    }

    private func applyDisplayState() {
        guard !imageViews.isEmpty else {
            return
        }

        imageViews.forEach {
            $0.isHidden = true
            $0.alphaValue = 1.0
        }

        if currentPreviewEnabled {
            let frameIndex = previewFrameOrder[safe: previewFrameOrderIndex] ?? 0
            guard frameIndex < imageViews.count else {
                return
            }
            imageViews[frameIndex].isHidden = false
            imageViews[frameIndex].alphaValue = 1.0
            return
        }

        guard let baseIndex = currentVisibleLayerIndices.first, baseIndex < imageViews.count else {
            return
        }

        imageViews[baseIndex].isHidden = false
        imageViews[baseIndex].alphaValue = 1.0

        guard currentVisibleLayerIndices.count > 1 else {
            return
        }

        let overlayIndex: Int = {
            if currentSelectedLayerIndex != baseIndex, currentVisibleLayerIndices.contains(currentSelectedLayerIndex) {
                return currentSelectedLayerIndex
            }

            return currentVisibleLayerIndices.dropFirst().first ?? baseIndex
        }()
        imageViews[overlayIndex].isHidden = false
        imageViews[overlayIndex].alphaValue = overlayIndex == baseIndex ? 1.0 : 0.5
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else {
            return nil
        }
        return self[index]
    }
}
