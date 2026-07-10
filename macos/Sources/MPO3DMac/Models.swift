import AppKit
import CoreGraphics
import Foundation

enum ExportFormat: String, CaseIterable, Hashable {
    case gif
    case png

    var label: String {
        rawValue.uppercased()
    }

    var filenameExtension: String {
        rawValue
    }
}

enum ExportSizePreset: Hashable, CaseIterable {
    case original
    case maxDimension(Int)

    static let allCases: [ExportSizePreset] = [
        .original,
        .maxDimension(2400),
        .maxDimension(2000),
        .maxDimension(1600),
        .maxDimension(1200),
    ]

    var label: String {
        switch self {
        case .original:
            return "Original"
        case .maxDimension(let value):
            return "\(value) px"
        }
    }

    var maxDimension: Int? {
        switch self {
        case .original:
            return nil
        case .maxDimension(let value):
            return value
        }
    }
}

enum PlaybackPattern: String, CaseIterable, Hashable {
    case sequence
    case loop

    var label: String {
        switch self {
        case .sequence:
            return "Loop"
        case .loop:
            return "Back n Forth"
        }
    }

    func frameOrder(count: Int) -> [Int] {
        guard count > 0 else {
            return []
        }

        let forward = Array(0..<count)
        guard self == .loop, count > 2 else {
            return forward
        }

        return forward + Array((1..<(count - 1)).reversed())
    }

    func frameOrder(indices: [Int]) -> [Int] {
        guard !indices.isEmpty else {
            return []
        }

        guard self == .loop, indices.count > 2 else {
            return indices
        }

        return indices + Array(indices[1..<(indices.count - 1)].reversed())
    }
}

struct PixelOffset: Equatable, Hashable {
    var x: Int
    var y: Int

    static let zero = PixelOffset(x: 0, y: 0)

    func moved(dx: Int, dy: Int) -> PixelOffset {
        PixelOffset(x: x + dx, y: y + dy)
    }
}

enum LayerSource: Hashable {
    case file(URL)
    case mpoFrame(fileURL: URL, frameIndex: Int)

    var backingURL: URL {
        switch self {
        case .file(let url):
            return url.standardizedFileURL
        case .mpoFrame(let fileURL, _):
            return fileURL.standardizedFileURL
        }
    }

    var displayName: String {
        switch self {
        case .file(let url):
            return url.lastPathComponent
        case .mpoFrame(let fileURL, let frameIndex):
            return "\(fileURL.lastPathComponent) - \(frameIndex + 1)"
        }
    }

    var automaticStem: String {
        switch self {
        case .file(let url):
            return url.deletingPathExtension().lastPathComponent
        case .mpoFrame(let fileURL, _):
            return fileURL.deletingPathExtension().lastPathComponent
        }
    }

    var identity: String {
        switch self {
        case .file(let url):
            return "file:\(url.standardizedFileURL.path)"
        case .mpoFrame(let fileURL, let frameIndex):
            return "mpo:\(fileURL.standardizedFileURL.path)#\(frameIndex)"
        }
    }
}

enum MediaSource: Hashable {
    case layerStack(
        nameOverride: String?,
        folderURL: URL,
        layers: [LayerSource],
        preferredPrimaryURL: URL?
    )
    case emptySequence(name: String, folderURL: URL)

    var primaryURL: URL {
        switch self {
        case .layerStack(let nameOverride, let folderURL, let layers, let preferredPrimaryURL):
            if let nameOverride {
                return folderURL.standardizedFileURL.appendingPathComponent(nameOverride)
            }

            if let preferredPrimaryURL {
                return preferredPrimaryURL.standardizedFileURL
            }

            return layers.first?.backingURL ?? URL(fileURLWithPath: "/")
        case .emptySequence(let name, let folderURL):
            return folderURL.standardizedFileURL.appendingPathComponent(name)
        }
    }

    var folderURL: URL {
        switch self {
        case .layerStack(_, let folderURL, _, _):
            return folderURL.standardizedFileURL
        case .emptySequence(_, let folderURL):
            return folderURL.standardizedFileURL
        }
    }

    var allURLs: [URL] {
        switch self {
        case .layerStack(_, _, let layers, _):
            return layers.map(\.backingURL)
        case .emptySequence:
            return []
        }
    }

    var layerCountHint: Int {
        switch self {
        case .layerStack(_, _, let layers, _):
            return max(layers.count, 1)
        case .emptySequence:
            return 0
        }
    }

    var importIdentity: String {
        switch self {
        case .layerStack(let nameOverride, let folderURL, let layers, _):
            let nameComponent = nameOverride ?? "_"
            let layerComponent = layers.map(\.identity).joined(separator: "|")
            return "stack:\(folderURL.standardizedFileURL.path)|\(nameComponent)|\(layerComponent)"
        case .emptySequence(let name, let folderURL):
            return "empty:\(folderURL.standardizedFileURL.path)|\(name)"
        }
    }

    var displayName: String {
        switch self {
        case .layerStack(let nameOverride, _, let layers, _):
            if let nameOverride {
                return nameOverride
            }

            return Self.automaticDisplayName(for: layers)
        case .emptySequence(let name, _):
            return name
        }
    }

    var hasBrowsableLayers: Bool {
        switch self {
        case .layerStack(_, _, let layers, _):
            return layers.count > 1
        case .emptySequence:
            return false
        }
    }

    var layerDisplayNames: [String] {
        switch self {
        case .layerStack(_, _, let layers, _):
            return layers.map(\.displayName)
        case .emptySequence:
            return []
        }
    }

    var layers: [LayerSource] {
        switch self {
        case .layerStack(_, _, let layers, _):
            return layers
        case .emptySequence:
            return []
        }
    }

    var preferredPrimaryURL: URL? {
        switch self {
        case .layerStack(_, _, _, let preferredPrimaryURL):
            return preferredPrimaryURL?.standardizedFileURL
        case .emptySequence:
            return nil
        }
    }

    var nameOverride: String? {
        switch self {
        case .layerStack(let nameOverride, _, _, _):
            return nameOverride
        case .emptySequence(let name, _):
            return name
        }
    }

    private static func automaticDisplayName(for layers: [LayerSource]) -> String {
        guard !layers.isEmpty else {
            return "Composition"
        }

        if layers.count == 1 {
            switch layers[0] {
            case .file(let url):
                return url.lastPathComponent
            case .mpoFrame(let fileURL, let frameIndex):
                return "\(fileURL.lastPathComponent) (\(frameIndex + 1))"
            }
        }

        if layers.count == 2,
           case .mpoFrame(let lhsURL, let lhsIndex) = layers[0],
           case .mpoFrame(let rhsURL, let rhsIndex) = layers[1],
           lhsURL.standardizedFileURL == rhsURL.standardizedFileURL,
           Set([lhsIndex, rhsIndex]) == Set([0, 1]) {
            return lhsURL.lastPathComponent
        }

        let firstStem = layers.first?.automaticStem ?? "Composition"
        let lastStem = layers.last?.automaticStem ?? firstStem
        if firstStem == lastStem {
            return "\(firstStem) (\(layers.count))"
        }

        return "\(firstStem)-\(lastStem) (\(layers.count))"
    }
}

struct MPOFileRecord: Identifiable, Hashable {
    let id: UUID
    var source: MediaSource
    var layerOffsets: [Int: PixelOffset]
    var hiddenLayerIndices: Set<Int>
    var exportedFormats: Set<ExportFormat>
    var playbackPattern: PlaybackPattern

    init(
        id: UUID = UUID(),
        source: MediaSource,
        layerOffsets: [Int: PixelOffset] = [:],
        hiddenLayerIndices: Set<Int> = [],
        exportedFormats: Set<ExportFormat> = [],
        playbackPattern: PlaybackPattern = .loop
    ) {
        self.id = id
        self.source = source
        self.layerOffsets = layerOffsets
        self.hiddenLayerIndices = hiddenLayerIndices
        self.exportedFormats = exportedFormats
        self.playbackPattern = playbackPattern
    }

    var url: URL {
        source.primaryURL
    }

    var folderURL: URL {
        source.folderURL
    }

    var importIdentity: String {
        source.importIdentity
    }

    var layerCountHint: Int {
        source.layerCountHint
    }

    var displayName: String {
        source.displayName
    }

    func visibleLayerIndices(frameCount: Int) -> [Int] {
        (0..<frameCount).filter { !hiddenLayerIndices.contains($0) }
    }

    func isLayerVisible(_ index: Int) -> Bool {
        !hiddenLayerIndices.contains(index)
    }

    var hasBrowsableLayers: Bool {
        source.hasBrowsableLayers
    }

    var layerDisplayNames: [String] {
        source.layerDisplayNames
    }

    var isEmptySequence: Bool {
        if case .emptySequence = source {
            return true
        }
        return false
    }
}

struct SidebarFolderGroup: Identifiable, Hashable {
    let url: URL
    let files: [MPOFileRecord]

    var id: String {
        url.path
    }

    var displayName: String {
        FileManager.default.displayName(atPath: url.path)
    }
}


struct FrameSequenceLayer {
    let cgImage: CGImage
    let fullImage: NSImage
    let previewImage: NSImage
    let interactiveImage: NSImage

    init(image: CGImage, previewMaxDimension: CGFloat, interactiveMaxDimension: CGFloat) {
        self.cgImage = image
        self.fullImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )

        let preview = Self.makePreviewCGImage(from: image, maxDimension: previewMaxDimension)
        self.previewImage = NSImage(
            cgImage: preview,
            size: NSSize(width: preview.width, height: preview.height)
        )

        let interactive = Self.makePreviewCGImage(from: image, maxDimension: interactiveMaxDimension)
        self.interactiveImage = NSImage(
            cgImage: interactive,
            size: NSSize(width: interactive.width, height: interactive.height)
        )
    }

    var pixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    private static func makePreviewCGImage(from image: CGImage, maxDimension: CGFloat = 2048) -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let largestDimension = max(width, height)

        guard largestDimension > maxDimension else {
            return image
        }

        let scale = maxDimension / largestDimension
        let targetWidth = max(Int((width * scale).rounded()), 1)
        let targetHeight = max(Int((height * scale).rounded()), 1)

        guard
            let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }
}

struct FrameSequence {
    let layers: [FrameSequenceLayer]

    init(
        images: [CGImage],
        previewMaxDimension: CGFloat = 1600,
        interactiveMaxDimension: CGFloat = 960
    ) {
        self.layers = images.map {
            FrameSequenceLayer(
                image: $0,
                previewMaxDimension: previewMaxDimension,
                interactiveMaxDimension: interactiveMaxDimension
            )
        }
    }

    var frameCount: Int {
        layers.count
    }

    var basePixelSize: CGSize {
        layers.first?.pixelSize ?? .zero
    }

    var aspectRatio: CGFloat {
        let size = basePixelSize
        return max(size.width / max(size.height, 1), 0.01)
    }
}
