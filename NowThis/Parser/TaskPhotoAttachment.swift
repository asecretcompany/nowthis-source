import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Sendable wire representation; no SwiftData model leaves its context owner.
struct TaskPhotoAttachment: Sendable, Equatable {
    var id: String
    var previewData: Data
    var originalFileID: String? = nil
    var folderFileID: String? = nil
    var originalRequested: Bool = false

    static func decode(_ line: String) throws -> Self? {
        var quoted = false
        var headerParts: [String] = []
        var part = ""
        var colon: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" { quoted.toggle() }
            if character == ":", !quoted { headerParts.append(part); colon = index; break }
            if character == ";", !quoted { headerParts.append(part); part = "" }
            else { part.append(character) }
        }
        guard let colon, headerParts.first?.uppercased() == "ATTACH" else { return nil }
        var parameters: [String: String] = [:]
        var duplicated = false
        for parameter in headerParts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].uppercased()
            var value = String(pair[1])
            if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if parameters.updateValue(value, forKey: key) != nil { duplicated = true }
        }
        guard let identity = parameters["X-NOWTHIS-PHOTO-ID"] else { return nil }
        guard !duplicated, let uuid = UUID(uuidString: identity),
              parameters["FMTTYPE"]?.lowercased() == "image/jpeg",
              parameters["ENCODING"]?.uppercased() == "BASE64",
              parameters["VALUE"]?.uppercased() == "BINARY" else { throw TaskPhotoAttachmentError.invalid }
        let value = String(line[line.index(after: colon)...])
        guard value.utf8.count <= 333_336,
              let bytes = Data(base64Encoded: value), validPreview(bytes),
              validFileID(parameters["X-NOWTHIS-ORIGINAL-ID"]),
              validFileID(parameters["X-NOWTHIS-FOLDER-ID"]) else { throw TaskPhotoAttachmentError.invalid }
        return Self(id: uuid.uuidString, previewData: bytes,
            originalFileID: parameters["X-NOWTHIS-ORIGINAL-ID"],
            folderFileID: parameters["X-NOWTHIS-FOLDER-ID"],
            originalRequested: parameters["X-NOWTHIS-ORIGINAL"] == "TRUE")
    }

    var contentLine: String? {
        guard let uuid = UUID(uuidString: id), Self.validPreview(previewData),
              Self.validFileID(originalFileID), Self.validFileID(folderFileID) else { return nil }
        var header = "ATTACH;FMTTYPE=image/jpeg;ENCODING=BASE64;VALUE=BINARY;X-NOWTHIS-PHOTO-ID=\(uuid.uuidString)"
        if originalRequested { header += ";X-NOWTHIS-ORIGINAL=TRUE" }
        if let originalFileID { header += ";X-NOWTHIS-ORIGINAL-ID=\(originalFileID)" }
        if let folderFileID { header += ";X-NOWTHIS-FOLDER-ID=\(folderFileID)" }
        return header + ":" + previewData.base64EncodedString()
    }

    static func validPreview(_ data: Data) -> Bool {
        guard data.count >= 4, data.count <= 250_000, data.starts(with: [0xff, 0xd8, 0xff]),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return (1...1600).contains(width.intValue) && (1...1600).contains(height.intValue)
    }

    private static func validFileID(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.count <= 30 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func safeOpaque(_ line: String) -> Bool {
        ICalendarParser.splitProperty(line).name == "ATTACH"
            && line.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    }
}

enum TaskPhotoAttachmentError: Error { case invalid, duplicateIdentity }
