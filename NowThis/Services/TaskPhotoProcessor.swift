import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ProcessedTaskPhoto: Sendable {
    let previewData: Data
    let originalData: Data?
    let originalContentType: String?
}

enum TaskPhotoProcessor {
    private static let maximumPreviewDimension = 1600
    private static let maximumPreviewBytes = 250_000
    private static let maximumOriginalBytes = 25_000_000

    private enum ProcessingError: Error {
        case invalidImage
        case unsupportedImageType
        case originalTooLarge
        case couldNotEncodePreview
    }

    static func process(_ data: Data, keepOriginal: Bool) throws -> ProcessedTaskPhoto {
        if keepOriginal && data.count > maximumOriginalBytes {
            throw ProcessingError.originalTooLarge
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let sourceType = CGImageSourceGetType(source),
              let imageType = UTType(sourceType as String),
              imageType.conforms(to: .image),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPreviewDimension
                ] as CFDictionary
              ) else {
            throw ProcessingError.invalidImage
        }

        let previewData = try makePreview(from: thumbnail)
        return ProcessedTaskPhoto(
            previewData: previewData,
            originalData: keepOriginal ? data : nil,
            originalContentType: keepOriginal ? imageType.preferredMIMEType : nil
        )
    }

    private static func makePreview(from image: CGImage) throws -> Data {
        var currentImage = image
        while true {
            var quality = 0.82
            while quality >= 0.26 {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil
                ) else {
                    throw ProcessingError.couldNotEncodePreview
                }
                CGImageDestinationAddImage(
                    destination,
                    currentImage,
                    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
                )
                guard CGImageDestinationFinalize(destination) else {
                    throw ProcessingError.couldNotEncodePreview
                }
                if output.length <= maximumPreviewBytes {
                    return output as Data
                }
                quality -= 0.08
            }

            let nextWidth = max(1, Int(Double(currentImage.width) * 0.85))
            let nextHeight = max(1, Int(Double(currentImage.height) * 0.85))
            guard nextWidth < currentImage.width || nextHeight < currentImage.height,
                  let colorSpace = currentImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil,
                    width: nextWidth,
                    height: nextHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ),
                  let resized = draw(currentImage, in: context, width: nextWidth, height: nextHeight) else {
                throw ProcessingError.couldNotEncodePreview
            }
            currentImage = resized
        }
    }

    private static func draw(_ image: CGImage, in context: CGContext, width: Int, height: Int) -> CGImage? {
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
