import Foundation
import ImageIO
import UIKit

/// A decoded display image that can cross from a detached decode task to the main actor.
struct TaskPhotoDisplayImage: @unchecked Sendable {
    let image: UIImage
}

enum TaskPhotoDisplayDecoder {
    static let thumbnailMaximumDimension = 320
    static let viewerMaximumDimension = 4096

    static func decode(_ data: Data, maximumDimension: Int) -> TaskPhotoDisplayImage? {
        guard maximumDimension > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
              ] as CFDictionary) else { return nil }
        return TaskPhotoDisplayImage(image: UIImage(cgImage: image))
    }
}
