import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import NowThis

struct TaskPhotoProcessorTests {
    @Test func previewIsBoundedJPEGWithOrientationAppliedAndMetadataRemoved() throws {
        let source = try makeJPEG(width: 2400, height: 1200, orientation: 6, location: true)
        let result = try TaskPhotoProcessor.process(source, keepOriginal: false)
        let image = try #require(CGImageSourceCreateWithData(result.previewData as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(result.previewData.count <= 250_000)
        #expect(max(width, height) <= 1600)
        #expect(width == 800)
        #expect(height == 1600)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(properties[kCGImagePropertyOrientation] == nil || (properties[kCGImagePropertyOrientation] as? Int) == 1)
        #expect(result.previewData.starts(with: [0xFF, 0xD8]))
        #expect(result.originalData == nil)
        #expect(result.originalContentType == nil)
    }

    @Test func keepOriginalReturnsExactBytesAndDetectedContentType() throws {
        let source = try makeJPEG(width: 64, height: 48, orientation: 1, location: true)
        let result = try TaskPhotoProcessor.process(source, keepOriginal: true)
        #expect(result.originalData == source)
        #expect(result.originalContentType == "image/jpeg")
    }

    @Test func rejectsCorruptInput() {
        #expect(throws: (any Error).self) {
            try TaskPhotoProcessor.process(Data("not an image".utf8), keepOriginal: false)
        }
    }

    @Test func rejectsOriginalLargerThanTwentyFiveMegabytes() {
        let oversized = Data(repeating: 0, count: 25_000_001)
        #expect(throws: (any Error).self) {
            try TaskPhotoProcessor.process(oversized, keepOriginal: true)
        }
    }

    private func makeJPEG(width: Int, height: Int, orientation: Int, location: Bool) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if location {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.3317,
                kCGImagePropertyGPSLongitude: -122.0301
            ] as [CFString: Any]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:08 12:30:00"
            ] as [CFString: Any]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "Camera Maker"
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
