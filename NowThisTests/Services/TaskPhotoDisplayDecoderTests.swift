import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit

@testable import NowThis

struct TaskPhotoDisplayDecoderTests {
    @Test func boundsViewerDecodeTo4096Pixels() throws {
        let data = try jpeg(width: 5000, height: 2000)

        let decoded = try #require(TaskPhotoDisplayDecoder.decode(
            data, maximumDimension: TaskPhotoDisplayDecoder.viewerMaximumDimension))

        #expect(decoded.image.cgImage?.width == 4096)
        #expect(decoded.image.cgImage?.height == 1638)
    }

    @Test func boundsThumbnailDecodeTo320Pixels() throws {
        let data = try jpeg(width: 2000, height: 1000)

        let decoded = try #require(TaskPhotoDisplayDecoder.decode(
            data, maximumDimension: TaskPhotoDisplayDecoder.thumbnailMaximumDimension))

        #expect(decoded.image.cgImage?.width == 320)
        #expect(decoded.image.cgImage?.height == 160)
    }

    @Test func appliesExifOrientationToDisplayDimensions() throws {
        let data = try jpeg(width: 80, height: 40, orientation: 6)

        let decoded = try #require(TaskPhotoDisplayDecoder.decode(data, maximumDimension: 4096))

        #expect(decoded.image.cgImage?.width == 40)
        #expect(decoded.image.cgImage?.height == 80)
    }

    @Test func rejectsCorruptImageData() {
        #expect(TaskPhotoDisplayDecoder.decode(Data([0, 1, 2, 3]), maximumDimension: 320) == nil)
    }

    private func jpeg(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
