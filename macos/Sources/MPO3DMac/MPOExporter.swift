import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MPOExporterError: LocalizedError {
    case couldNotCreateContext
    case couldNotCreateImage
    case couldNotCreateDestination
    case couldNotFinalizeDestination
    case noFramesToExport

    var errorDescription: String? {
        switch self {
        case .couldNotCreateContext:
            return "Could not create the export canvas."
        case .couldNotCreateImage:
            return "Could not generate the final image."
        case .couldNotCreateDestination:
            return "Could not create the output file."
        case .couldNotFinalizeDestination:
            return "Could not finish the export."
        case .noFramesToExport:
            return "There are no frames to export."
        }
    }
}

enum MPOExporter {
    static func export(
        sequence: FrameSequence,
        offsets: [PixelOffset],
        visibleLayerIndices: [Int],
        selectedLayerIndex: Int,
        playbackPattern: PlaybackPattern,
        format: ExportFormat,
        duration: Double,
        maxDimension: Int?,
        outputURL: URL
    ) throws {
        let images = sequence.layers.map(\.cgImage)
        guard !images.isEmpty else {
            throw MPOExporterError.noFramesToExport
        }

        let normalizedOffsets = normalizeOffsets(offsets, frameCount: images.count)
        let normalizedVisibleLayerIndices = normalizeVisibleLayerIndices(visibleLayerIndices, frameCount: images.count)
        let layout = ExportLayout(
            images: images,
            offsets: normalizedOffsets,
            visibleLayerIndices: normalizedVisibleLayerIndices,
            maxDimension: maxDimension
        )

        switch format {
        case .gif:
            try exportGIF(
                images: images,
                layout: layout,
                playbackPattern: playbackPattern,
                duration: duration,
                outputURL: outputURL
            )
        case .png:
            try exportPNG(
                images: images,
                layout: layout,
                selectedLayerIndex: selectedLayerIndex,
                outputURL: outputURL
            )
        }
    }

    private static func normalizeOffsets(_ offsets: [PixelOffset], frameCount: Int) -> [PixelOffset] {
        (0..<frameCount).map { index in
            index < offsets.count ? offsets[index] : .zero
        }
    }

    private static func normalizeVisibleLayerIndices(_ indices: [Int], frameCount: Int) -> [Int] {
        let filtered = indices.filter { $0 >= 0 && $0 < frameCount }
        return filtered.isEmpty ? [0] : filtered
    }

    private static func exportGIF(
        images: [CGImage],
        layout: ExportLayout,
        playbackPattern: PlaybackPattern,
        duration: Double,
        outputURL: URL
    ) throws {
        let frameOrder = playbackPattern.frameOrder(indices: layout.visibleLayerIndices)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameOrder.count,
            nil
        ) else {
            throw MPOExporterError.couldNotCreateDestination
        }

        let gifProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
                kCGImagePropertyGIFHasGlobalColorMap: false,
                kCGImagePropertyGIFCanvasPixelWidth: Int(layout.finalSize.width.rounded()),
                kCGImagePropertyGIFCanvasPixelHeight: Int(layout.finalSize.height.rounded()),
            ],
        ]

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: max(duration, 0.05),
                kCGImagePropertyGIFUnclampedDelayTime: max(duration, 0.05),
            ],
        ]

        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        for frameIndex in frameOrder {
            let frame = try renderImage(
                size: layout.finalSize,
                draws: [
                    (images[frameIndex], layout.drawRects[frameIndex], 1.0),
                ]
            )
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw MPOExporterError.couldNotFinalizeDestination
        }
    }

    private static func exportPNG(
        images: [CGImage],
        layout: ExportLayout,
        selectedLayerIndex: Int,
        outputURL: URL
    ) throws {
        let overlayIndex: Int? = {
            guard layout.visibleLayerIndices.count > 1 else {
                return nil
            }

            let baseIndex = layout.visibleLayerIndices[0]
            if selectedLayerIndex == baseIndex {
                return layout.visibleLayerIndices.dropFirst().first
            }

            if layout.visibleLayerIndices.contains(selectedLayerIndex) {
                return selectedLayerIndex
            }

            return layout.visibleLayerIndices.dropFirst().first
        }()

        let baseIndex = layout.visibleLayerIndices[0]
        var draws: [(image: CGImage, rect: CGRect, alpha: CGFloat)] = [
            (images[baseIndex], layout.drawRects[baseIndex], 1.0),
        ]

        if let overlayIndex {
            draws.append((images[overlayIndex], layout.drawRects[overlayIndex], 0.55))
        }

        let image = try renderImage(
            size: layout.finalSize,
            draws: draws
        )

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MPOExporterError.couldNotCreateDestination
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw MPOExporterError.couldNotFinalizeDestination
        }
    }

    private static func renderImage(
        size: CGSize,
        draws: [(image: CGImage, rect: CGRect, alpha: CGFloat)]
    ) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: max(Int(ceil(size.width)), 1),
                height: max(Int(ceil(size.height)), 1),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw MPOExporterError.couldNotCreateContext
        }

        context.interpolationQuality = .high
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        for draw in draws {
            let rect = CGRect(
                x: draw.rect.origin.x,
                y: size.height - draw.rect.maxY,
                width: draw.rect.width,
                height: draw.rect.height
            )
            context.saveGState()
            context.setAlpha(draw.alpha)
            context.draw(draw.image, in: rect)
            context.restoreGState()
        }

        guard let image = context.makeImage() else {
            throw MPOExporterError.couldNotCreateImage
        }

        return image
    }
}

private struct ExportLayout {
    let finalSize: CGSize
    let drawRects: [CGRect]
    let visibleLayerIndices: [Int]

    init(images: [CGImage], offsets: [PixelOffset], visibleLayerIndices: [Int], maxDimension: Int?) {
        let frameRects = zip(images, offsets).map { image, offset in
            CGRect(
                x: CGFloat(offset.x),
                y: CGFloat(offset.y),
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        }
        let cropRect = Self.cropRect(for: frameRects, visibleLayerIndices: visibleLayerIndices)
        let scale = Self.exportScale(for: cropRect.size, maxDimension: maxDimension)

        self.finalSize = CGSize(
            width: max(cropRect.width * scale, 1),
            height: max(cropRect.height * scale, 1)
        )
        self.drawRects = frameRects.map { rect in
            CGRect(
                x: (rect.origin.x - cropRect.origin.x) * scale,
                y: (rect.origin.y - cropRect.origin.y) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
        self.visibleLayerIndices = visibleLayerIndices
    }

    private static func cropRect(for rects: [CGRect], visibleLayerIndices: [Int]) -> CGRect {
        guard let firstIndex = visibleLayerIndices.first, rects.indices.contains(firstIndex) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        var cropRect = rects[firstIndex]

        for index in visibleLayerIndices.dropFirst() {
            guard rects.indices.contains(index) else {
                continue
            }

            let rect = rects[index]
            let next = cropRect.intersection(rect)
            if next.isNull || next.width < 1 || next.height < 1 {
                continue
            }
            cropRect = next
        }

        return cropRect.integral
    }

    private static func exportScale(for size: CGSize, maxDimension: Int?) -> CGFloat {
        guard let maxDimension else {
            return 1
        }

        let largestSide = max(size.width, size.height)
        guard largestSide > 0 else {
            return 1
        }

        let target = CGFloat(maxDimension)
        guard largestSide > target else {
            return 1
        }

        return target / largestSide
    }
}
