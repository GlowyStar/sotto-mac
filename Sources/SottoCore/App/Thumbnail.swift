import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The image size and the thumbnail of a picture (section 32.1), made and read with ImageIO.
public enum Thumbnail {
    /// Longest sides tried in turn until the JPEG fits `Envelope.maxThumbnailBytes`.
    static let sides = [160, 120, 90, 60, 40]

    /// The pixel size of the picture at `url` as it is shown (its orientation applied) and a
    /// JPEG thumbnail of at most `Envelope.maxThumbnailBytes`; nil when it is not a picture.
    public static func make(_ url: URL) -> (width: Int, height: Int, jpeg: Data)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            var width = properties[kCGImagePropertyPixelWidth] as? Int,
            var height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else {
            return nil
        }
        // Orientations 5 to 8 turn the picture a quarter.
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
            swap(&width, &height)
        }
        for side in sides {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            if let jpeg = jpeg(image), jpeg.count <= Envelope.maxThumbnailBytes {
                return (width, height, jpeg)
            }
        }
        return nil
    }

    /// A received thumbnail as an image of at most `sides[0]` on its longest side, whatever
    /// size its header claims; nil unless it decodes as a JPEG (section 32.2).
    public static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetType(source) as String? == UTType.jpeg.identifier
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: sides[0],
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.7) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
