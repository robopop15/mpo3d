import CoreImage
import CoreGraphics
import Foundation
import ImageIO

enum MPOImageLoaderError: LocalizedError {
    case invalidFile
    case notEnoughFrames
    case couldNotDecodeFrame

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "The MPO file could not be read."
        case .notEnoughFrames:
            return "The MPO file does not contain at least two images."
        case .couldNotDecodeFrame:
            return "The MPO images could not be decoded."
        }
    }
}

enum MPOImageLoader {
    static func loadFrameSequence(from source: MediaSource) throws -> FrameSequence {
        FrameSequence(images: try loadFrameImages(from: source))
    }

    static func loadFrameImages(from source: MediaSource) throws -> [CGImage] {
        switch source {
        case .layerStack(_, _, let layers, _):
            let images = try layers.map(loadLayerImage(from:))
            guard !images.isEmpty else {
                throw MPOImageLoaderError.notEnoughFrames
            }
            return images
        case .emptySequence:
            throw MPOImageLoaderError.notEnoughFrames
        }
    }

    private static func loadLayerImage(from source: LayerSource) throws -> CGImage {
        switch source {
        case .file(let url):
            return try loadStillImage(from: url)
        case .mpoFrame(let fileURL, let frameIndex):
            let frames = try loadMPOFrames(from: fileURL)
            guard frames.indices.contains(frameIndex) else {
                throw MPOImageLoaderError.couldNotDecodeFrame
            }
            return frames[frameIndex]
        }
    }

    private static func loadMPOFrames(from url: URL) throws -> [CGImage] {
        let data = try Data(contentsOf: url)

        if let frames = try loadUsingMPF(from: data) {
            return frames
        }

        if let frames = try loadUsingJPEGScan(from: data) {
            return frames
        }

        if let frames = try loadUsingImageIO(from: data) {
            return frames
        }

        throw MPOImageLoaderError.notEnoughFrames
    }

    private static func loadStillImage(from url: URL) throws -> CGImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = normalizedImage(from: source, index: 0)
        else {
            throw MPOImageLoaderError.invalidFile
        }

        return image
    }

    private static func loadUsingMPF(from data: Data) throws -> [CGImage]? {
        guard let parsedMPF = parseMPFEntries(from: data), parsedMPF.entries.count >= 2 else {
            return nil
        }

        let selectedEntries = parsedMPF.entries.prefix(2)
        let candidates = selectedEntries.enumerated().compactMap { index, entry -> DecodedFrameCandidate? in
            guard let start = resolveFrameStart(
                for: entry,
                entryIndex: index,
                tiffStart: parsedMPF.tiffStart,
                in: data
            ) else {
                return nil
            }
            let end = start + Int(entry.length)

            guard start >= 0, end <= data.count, end > start else {
                return nil
            }

            let frameData = data.subdata(in: start..<end)
            guard let source = CGImageSourceCreateWithData(frameData as CFData, nil) else {
                return nil
            }

            guard let image = normalizedImage(from: source, index: 0) else {
                return nil
            }

            return DecodedFrameCandidate(index: index, image: image)
        }

        guard candidates.count >= 2 else {
            return nil
        }

        return [candidates[0].image, candidates[1].image]
    }

    private static func loadUsingImageIO(from data: Data) throws -> [CGImage]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount >= 2 else {
            return nil
        }

        let candidates = decodeCandidates(from: source, frameCount: frameCount)
        guard candidates.count >= 2 else {
            throw MPOImageLoaderError.couldNotDecodeFrame
        }

        return selectBestStereoFrames(from: candidates)
    }

    private static func loadUsingJPEGScan(from data: Data) throws -> [CGImage]? {
        let frameData = extractJPEGFrames(from: data)
        guard frameData.count >= 2 else {
            return nil
        }

        let candidates = frameData.enumerated().compactMap { index, frame -> DecodedFrameCandidate? in
            guard let source = CGImageSourceCreateWithData(frame as CFData, nil) else {
                return nil
            }

            guard let image = normalizedImage(from: source, index: 0) else {
                return nil
            }

            return DecodedFrameCandidate(index: index, image: image)
        }

        guard candidates.count >= 2 else {
            return nil
        }

        return selectBestStereoFrames(from: candidates)
    }

    private static func extractJPEGFrames(from data: Data) -> [Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else {
            return []
        }

        var frames: [Data] = []
        var index = 0

        while index < bytes.count - 1 {
            if bytes[index] == 0xFF, bytes[index + 1] == 0xD8 {
                let start = index
                index += 2

                while index < bytes.count - 1 {
                    if bytes[index] == 0xFF, bytes[index + 1] == 0xD9 {
                        let end = index + 2
                        frames.append(data.subdata(in: start..<end))
                        index = end
                        break
                    }
                    index += 1
                }
            } else {
                index += 1
            }
        }

        return frames
    }

    private static func decodeCandidates(from source: CGImageSource, frameCount: Int) -> [DecodedFrameCandidate] {
        (0..<frameCount).compactMap { index in
            guard let image = normalizedImage(from: source, index: index) else {
                return nil
            }

            return DecodedFrameCandidate(index: index, image: image)
        }
    }

    private static func normalizedImage(from source: CGImageSource, index: Int) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let rawOrientation = properties?[kCGImagePropertyOrientation] as? UInt32
        guard
            let rawOrientation,
            let orientation = CGImagePropertyOrientation(rawValue: rawOrientation),
            orientation != .up
        else {
            return image
        }

        let ciImage = CIImage(cgImage: image).oriented(orientation)
        let rect = ciImage.extent.integral
        let ciContext = CIContext(options: nil)
        return ciContext.createCGImage(ciImage, from: rect) ?? image
    }

    private static func selectBestStereoFrames(from candidates: [DecodedFrameCandidate]) -> [CGImage] {
        candidates
            .sorted { lhs, rhs in
                if lhs.area == rhs.area {
                    return lhs.index < rhs.index
                }
                return lhs.area > rhs.area
            }
            .prefix(2)
            .sorted { $0.index < $1.index }
            .map(\.image)
    }

    private static func parseMPFEntries(from data: Data) -> ParsedMPF? {
        let reader = ByteReader(data: data)
        guard reader.readUInt16BE(at: 0) == 0xFFD8 else {
            return nil
        }

        var offset = 2
        while offset + 4 <= data.count {
            guard reader.uint8(at: offset) == 0xFF else {
                offset += 1
                continue
            }

            let marker = reader.uint8(at: offset + 1)
            if marker == 0xDA || marker == 0xD9 {
                break
            }

            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                offset += 2
                continue
            }

            let segmentLength = Int(reader.readUInt16BE(at: offset + 2))
            let segmentStart = offset + 4
            let segmentEnd = offset + 2 + segmentLength

            guard segmentLength >= 2, segmentEnd <= data.count else {
                return nil
            }

            if marker == 0xE2, reader.string(at: segmentStart, length: 4) == "MPF\0" {
                let tiffStart = segmentStart + 4
                return parseMPFDirectory(from: data, tiffStart: tiffStart, endOffset: segmentEnd)
            }

            offset = segmentEnd
        }

        return nil
    }

    private static func parseMPFDirectory(from data: Data, tiffStart: Int, endOffset: Int) -> ParsedMPF? {
        let headerReader = ByteReader(data: data)
        guard tiffStart + 8 <= endOffset else {
            return nil
        }

        let byteOrder = MPFByteOrder(rawValue: headerReader.string(at: tiffStart, length: 2)) ?? .little
        let reader = ByteReader(data: data, byteOrder: byteOrder)

        let ifdOffset = Int(reader.readUInt32(at: tiffStart + 4))
        let ifdStart = tiffStart + ifdOffset
        guard ifdStart + 2 <= endOffset else {
            return nil
        }

        let entryCount = Int(reader.readUInt16(at: ifdStart))
        var mpEntryDataOffset: Int?
        var mpEntryByteCount: Int?

        for index in 0..<entryCount {
            let entryOffset = ifdStart + 2 + (index * 12)
            guard entryOffset + 12 <= endOffset else {
                return nil
            }

            let tag = reader.readUInt16(at: entryOffset)
            let count = Int(reader.readUInt32(at: entryOffset + 4))
            let valueOffset = Int(reader.readUInt32(at: entryOffset + 8))

            if tag == 0xB002 {
                mpEntryDataOffset = valueOffset
                mpEntryByteCount = count
                break
            }
        }

        guard let mpEntryDataOffset, let mpEntryByteCount, mpEntryByteCount >= 32 else {
            return nil
        }

        let mpEntriesStart = tiffStart + mpEntryDataOffset
        guard mpEntriesStart + mpEntryByteCount <= endOffset else {
            return nil
        }

        let mpEntryCount = mpEntryByteCount / 16
        guard mpEntryCount >= 2 else {
            return nil
        }

        let entries: [MPFEntry] = (0..<mpEntryCount).compactMap { index -> MPFEntry? in
            let entryOffset = mpEntriesStart + (index * 16)
            guard entryOffset + 16 <= endOffset else {
                return nil
            }

            return MPFEntry(
                attribute: reader.readUInt32(at: entryOffset),
                length: reader.readUInt32(at: entryOffset + 4),
                dataOffset: reader.readUInt32(at: entryOffset + 8)
            )
        }

        guard entries.count >= 2 else {
            return nil
        }

        return ParsedMPF(tiffStart: tiffStart, entries: entries)
    }

    private static func resolveFrameStart(
        for entry: MPFEntry,
        entryIndex: Int,
        tiffStart: Int,
        in data: Data
    ) -> Int? {
        let rawOffset = Int(entry.dataOffset)
        let length = Int(entry.length)
        var candidates: [Int] = []

        // MPO costuma tratar a primeira imagem como o arquivo base inteiro e as demais
        // como offsets relativos ao cabecalho MPF.
        if entryIndex == 0, rawOffset == 0 {
            candidates.append(0)
        }

        if rawOffset > 0 {
            candidates.append(tiffStart + rawOffset)
        }

        candidates.append(rawOffset)

        let reader = ByteReader(data: data)
        return candidates.first { candidate in
            guard candidate >= 0, candidate + length <= data.count, candidate + 1 < data.count else {
                return false
            }

            return reader.readUInt16BE(at: candidate) == 0xFFD8
        }
    }
}

private struct DecodedFrameCandidate {
    let index: Int
    let image: CGImage

    var area: Int {
        image.width * image.height
    }
}

private struct MPFEntry {
    let attribute: UInt32
    let length: UInt32
    let dataOffset: UInt32
}

private struct ParsedMPF {
    let tiffStart: Int
    let entries: [MPFEntry]
}

private enum MPFByteOrder: String {
    case little = "II"
    case big = "MM"
}

private struct ByteReader {
    let data: Data
    let byteOrder: MPFByteOrder

    init(data: Data, byteOrder: MPFByteOrder = .big) {
        self.data = data
        self.byteOrder = byteOrder
    }

    func uint8(at offset: Int) -> UInt8 {
        data[data.startIndex + offset]
    }

    func string(at offset: Int, length: Int) -> String {
        guard offset + length <= data.count else {
            return ""
        }

        return String(data: data.subdata(in: offset..<(offset + length)), encoding: .ascii) ?? ""
    }

    func readUInt16(at offset: Int) -> UInt16 {
        switch byteOrder {
        case .little:
            return UInt16(uint8(at: offset)) | (UInt16(uint8(at: offset + 1)) << 8)
        case .big:
            return (UInt16(uint8(at: offset)) << 8) | UInt16(uint8(at: offset + 1))
        }
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        (UInt16(uint8(at: offset)) << 8) | UInt16(uint8(at: offset + 1))
    }

    func readUInt32(at offset: Int) -> UInt32 {
        switch byteOrder {
        case .little:
            return UInt32(uint8(at: offset))
                | (UInt32(uint8(at: offset + 1)) << 8)
                | (UInt32(uint8(at: offset + 2)) << 16)
                | (UInt32(uint8(at: offset + 3)) << 24)
        case .big:
            return (UInt32(uint8(at: offset)) << 24)
                | (UInt32(uint8(at: offset + 1)) << 16)
                | (UInt32(uint8(at: offset + 2)) << 8)
                | UInt32(uint8(at: offset + 3))
        }
    }
}
