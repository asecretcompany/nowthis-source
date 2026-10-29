import Foundation
import CryptoKit
import CoreFoundation

struct PhotoServerAccess: Sendable {
    let baseURL: String
    let username: String
    let password: String
}

struct PhotoCalendarAccess: Sendable, Equatable {
    let ownerID: String
    let sharees: [PhotoSharee]
}

struct PhotoSharee: Sendable, Equatable {
    let id: String
    let kind: Int
    let canEdit: Bool
}

struct PhotoFolder: Sendable, Equatable {
    let fileID: String
    let href: String
    var ownerID: String? = nil
}

actor NextcloudPhotoClient {
    private var runDeadline: Date?
    func setRunDeadline(_ deadline: Date?) async { runDeadline = deadline }

    struct Configuration: Sendable {
        var maxOriginalBytes: Int = 25_000_000
        var maxMetadataBytes: Int = 2_000_000
    }
    enum Error: Swift.Error, Sendable, Equatable {
        case incompleteCalendarMetadata, unsupportedShareKind(String), notCalendarOwner
        case unsafeURL, unsafeRedirect, invalidPhotoID, invalidFileID, invalidResponse
        case notFound, unauthorized, forbidden, originalTooLarge, responseTooLarge
        case quotaExceeded, unsupportedAPI, httpStatus(Int), ocsStatus(Int)
        case incompleteShareMetadata, shareVerificationFailed, unsafeFolder, transport(Int)
    }
    private let session: URLSession
    private let configuration: Configuration
    private static let dav = "DAV:"
    private static let oc = "http://owncloud.org/ns"
    private static let nc = "http://nextcloud.org/ns"
    private static let inverse = "http://inverse.ca/ns/"

    init(session: URLSession = .shared, configuration: Configuration = .init()) {
        self.session = session
        self.configuration = configuration
    }

    init(configuration: URLSessionConfiguration, limits: Configuration = .init()) {
        self.session = URLSession(configuration: configuration)
        self.configuration = limits
    }

    /// Successful oc:invite is the complete invitation set. nc:sharees, when
    /// supplied, must agree with it; it cannot supply missing permissions.
    func inspectCalendar(calendarHref: String, access: PhotoServerAccess) async throws -> PhotoCalendarAccess {
        let server = try Server(access)
        let url = try server.calendarURL(calendarHref)
        let body = propfind("<o:owner-principal/><d:owner/><i:shared-owner/><o:invite/><n:sharees/>")
        let data = try await request(url, method: "PROPFIND", body: Data(body.utf8), access: access, headers: ["Depth": "0"], accepted: [207])
        let response = try responseNode(data, url: url, server: server)
        let properties = try successfulProperties(response)
        let ownerProperty = properties[PhotoXML.key(Self.oc, "owner-principal")]
        let davOwner = properties[PhotoXML.key(Self.dav, "owner")]
        let inverseOwner = properties[PhotoXML.key(Self.inverse, "shared-owner")]
        guard let ownerNode = ownerProperty ?? davOwner else { throw Error.incompleteCalendarMetadata }
        let ownerID = try principal(ownerNode.hrefOrText, server: server).id
        if let inverseOwner {
            guard try principal(inverseOwner.hrefOrText, server: server).id == ownerID else {
                throw Error.incompleteCalendarMetadata
            }
        }
        // Treat a legacy inverse property as corroboration only; it cannot
        // authorize ownership without the server's owner principal property.
        if inverseOwner == nil, let ownerProperty, let davOwner {
            guard try principal(ownerProperty.hrefOrText, server: server).id == principal(davOwner.hrefOrText, server: server).id else {
                throw Error.incompleteCalendarMetadata
            }
        }
        guard let invite = properties[PhotoXML.key(Self.oc, "invite")] else { throw Error.incompleteCalendarMetadata }
        var sharees: [PhotoSharee] = []
        var identities = Set<String>()
        for child in invite.children {
            if child.key == PhotoXML.key(Self.oc, "organizer") { continue }
            guard child.key == PhotoXML.key(Self.oc, "user"),
                  let href = child.only(Self.dav, "href"),
                  let permission = child.only(Self.oc, "access"), permission.children.count == 1,
                  child.only(Self.oc, "invite-accepted") != nil else { throw Error.incompleteCalendarMetadata }
            let identity = try principal(href.text, server: server, allowGroup: true)
            let canEdit: Bool
            switch permission.children[0].key {
            case PhotoXML.key(Self.oc, "read"): canEdit = false
            case PhotoXML.key(Self.oc, "read-write"): canEdit = true
            default: throw Error.incompleteCalendarMetadata
            }
            guard identities.insert(identity.token).inserted else { throw Error.incompleteCalendarMetadata }
            sharees.append(.init(id: identity.id, kind: identity.kind, canEdit: canEdit))
        }
        if let listing = properties[PhotoXML.key(Self.nc, "sharees")] {
            var listed = Set<String>()
            for item in listing.children {
                // The Files serializer uses .org; historical wiki examples use .com.
                let namespace = item.namespace
                guard [Self.nc, "http://nextcloud.com/ns"].contains(namespace), item.name == "sharee",
                      let id = item.only(namespace, "id")?.text, !id.isEmpty,
                      let kindText = item.only(namespace, "type")?.text, let kind = Int(kindText) else {
                    throw Error.incompleteCalendarMetadata
                }
                guard [0, 1].contains(kind) else { throw Error.unsupportedShareKind(kindText) }
                guard listed.insert("\(kind):\(id)").inserted else { throw Error.incompleteCalendarMetadata }
            }
            guard listed == identities else { throw Error.incompleteCalendarMetadata }
        }
        // A failed invite is never empty. Optional Files sharees may be unsupported
        // on calendar collections, but a denied/partial property is refused.
        for block in response.elements(Self.dav, "propstat") where !isSuccessful(block) {
            if let prop = block.only(Self.dav, "prop") {
                if prop.children.contains(where: { $0.key == PhotoXML.key(Self.oc, "invite") }) {
                    throw Error.incompleteCalendarMetadata
                }
                if prop.children.contains(where: { $0.key == PhotoXML.key(Self.nc, "sharees") }),
                   block.only(Self.dav, "status")?.text.split(separator: " ").dropFirst().first != "404" {
                    throw Error.incompleteCalendarMetadata
                }
            }
        }
        return .init(ownerID: ownerID, sharees: sharees)
    }

    /// Reconciliation is confined to this owner's dedicated calendar folder.
    /// No mutation is attempted until the calendar's full invitation set parses.
    func prepareFolder(calendarHref: String, access: PhotoServerAccess) async throws -> PhotoFolder {
        let server = try Server(access)
        let calendarURL = try server.calendarURL(calendarHref)
        let calendar = try await inspectCalendar(calendarHref: calendarHref, access: access)
        guard calendar.ownerID == access.username else { throw Error.notCalendarOwner }
        let identity = calendar.ownerID + "\n" + calendarURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let relative = "/NowThis Photos/" + digest
        let root = server.filesURL.appendingPathComponent("NowThis Photos", isDirectory: true)
        let url = root.appendingPathComponent(digest, isDirectory: true)
        _ = try await request(root, method: "MKCOL", access: access, accepted: [201, 405])
        let rootResource = try await propertiesAt(root, access: access, server: server)
        guard rootResource.isFolder, rootResource.ownerID == calendar.ownerID else { throw Error.unsafeFolder }
        let parentGrants = try await shares(relativePath: "/NowThis Photos", fileID: rootResource.fileID, access: access, server: server)
        // An inherited grant cannot be revoked on a child. Refuse shared parent
        // folders rather than falsely claiming exact calendar access on the leaf.
        guard parentGrants.isEmpty else { throw Error.unsafeFolder }
        _ = try await request(url, method: "MKCOL", access: access, accepted: [201, 405])
        let resource = try await propertiesAt(url, access: access, server: server)
        guard resource.isFolder, resource.ownerID == calendar.ownerID else { throw Error.notCalendarOwner }
        let existing = try await shares(relativePath: relative, fileID: resource.fileID, access: access, server: server)
        var desired: [String: Int] = [:]
        for sharee in calendar.sharees { desired["\(sharee.kind):\(sharee.id)"] = sharee.canEdit ? 15 : 1 }
        // Validate the entire OCS list before deleting even the first grant.
        var kept = Set<String>()
        for share in existing {
            if let wanted = desired[share.token], kept.insert(share.token).inserted {
                if share.permissions != wanted {
                    try await mutateShare(id: share.id, method: "PUT", fields: [("permissions", String(wanted)), ("sendMail", "false")], access: access, server: server)
                }
            } else {
                try await mutateShare(id: share.id, method: "DELETE", fields: [], access: access, server: server)
            }
        }
        for sharee in calendar.sharees where !kept.contains("\(sharee.kind):\(sharee.id)") {
            try await mutateShare(id: nil, method: "POST", fields: [("path", relative), ("shareType", String(sharee.kind)), ("shareWith", sharee.id), ("permissions", sharee.canEdit ? "15" : "1"), ("sendMail", "false")], access: access, server: server)
        }
        let verified = try await shares(relativePath: relative, fileID: resource.fileID, access: access, server: server)
        guard verified.count == desired.count, Set(verified.map(\.token)).count == verified.count,
              verified.allSatisfy({ desired[$0.token] == $0.permissions }) else { throw Error.shareVerificationFailed }
        return .init(fileID: resource.fileID, href: url.absoluteString, ownerID: resource.ownerID)
    }

    func resolveFolder(fileID: String, access: PhotoServerAccess) async throws -> PhotoFolder {
        let resource = try await resolve(fileID: fileID, access: access)
        guard resource.isFolder else { throw Error.invalidResponse }
        return .init(fileID: resource.fileID, href: resource.url.absoluteString, ownerID: resource.ownerID)
    }

    /// A supplied href is advisory only. Resolve the ID in the caller's mount,
    /// then use an opaque UUID name and refuse to overwrite an existing original.
    func upload(data: Data, contentType: String, photoID: String, folder: PhotoFolder, access: PhotoServerAccess) async throws -> String {
        guard let uuid = UUID(uuidString: photoID) else { throw Error.invalidPhotoID }
        guard data.count <= originalLimit else { throw Error.originalTooLarge }
        let mediaTokens = contentType.split(separator: "/", omittingEmptySubsequences: false)
        let tokenCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'+-.^_`|~".utf8)
        guard mediaTokens.count == 2, mediaTokens.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 127 && $0.utf8.allSatisfy(tokenCharacters.contains) }) else {
            throw Error.invalidResponse
        }
        let server = try Server(access)
        let mounted = try await resolveFolder(fileID: folder.fileID, access: access)
        let folderURL = try server.fileURL(mounted.href)
        let url = folderURL.appendingPathComponent(uuid.uuidString.lowercased())
        _ = try await request(url, method: "PUT", body: data, access: access, headers: ["Content-Type": contentType, "If-None-Match": "*"], accepted: [201, 204, 412])
        let existing = try await propertiesAt(url, access: access, server: server)
        guard !existing.isFolder else { throw Error.invalidResponse }
        return existing.fileID
    }

    func download(fileID: String, access: PhotoServerAccess) async throws -> Data {
        let resource = try await resolve(fileID: fileID, access: access)
        guard !resource.isFolder else { throw Error.invalidResponse }
        return try await request(resource.url, method: "GET", access: access, accepted: [200], original: true)
    }

    /// Scoped reads must prove the original belongs to the calendar owner's photo folder.
    func download(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) async throws -> Data {
        let folder = try await validatedFolder(fileID: folderFileID, calendarHref: calendarHref, access: access)
        let original = try await resolve(fileID: fileID, access: access)
        guard !original.isFolder, original.ownerID == folder.ownerID,
              original.url.deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == folder.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw Error.forbidden }
        return try await request(original.url, method: "GET", access: access, accepted: [200], original: true)
    }

    func resolveFolder(fileID: String, calendarHref: String, access: PhotoServerAccess) async throws -> PhotoFolder {
        let resource = try await validatedFolder(fileID: fileID, calendarHref: calendarHref, access: access)
        return .init(fileID: resource.fileID, href: resource.url.absoluteString, ownerID: resource.ownerID)
    }

    private func validatedFolder(fileID: String, calendarHref: String, access: PhotoServerAccess) async throws -> Resource {
        let membership = try await inspectCalendar(calendarHref: calendarHref, access: access)
        let server = try Server(access)
        let calendarURL = try server.calendarURL(calendarHref)
        let prefix = server.davURL.path + "/calendars/"
        let components = calendarURL.path.dropFirst(prefix.count).split(separator: "/")
        guard components.count == 2 else { throw Error.incompleteCalendarMetadata }
        var name = String(components[1])
        if String(components[0]) != membership.ownerID {
            // Nextcloud's backend exposes recipient URIs as original + _shared_by_ + owner.
            // Refuse an unknown URI form instead of binding another list's private folder.
            let suffix = "_shared_by_" + membership.ownerID
            guard String(components[0]) == access.username, name.hasSuffix(suffix) else { throw Error.incompleteCalendarMetadata }
            name = String(name.dropLast(suffix.count))
            guard !name.isEmpty else { throw Error.incompleteCalendarMetadata }
        }
        let ownerCalendar = server.davURL.appendingPathComponent("calendars", isDirectory: true)
            .appendingPathComponent(membership.ownerID, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let identity = membership.ownerID + "\n" + ownerCalendar.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = try await resolve(fileID: fileID, access: access)
        guard folder.isFolder, folder.ownerID == membership.ownerID else { throw Error.forbidden }
        if membership.ownerID == access.username {
            let expected = server.filesURL.appendingPathComponent("NowThis Photos", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
            guard folder.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == expected.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw Error.forbidden }
        } else {
            let mountName = folder.url.lastPathComponent
            let duplicateSuffix = mountName.dropFirst(digest.count)
            let duplicate = duplicateSuffix.hasPrefix(" (") && duplicateSuffix.hasSuffix(")")
                && Int(duplicateSuffix.dropFirst(2).dropLast()).map { $0 > 0 } == true
            guard mountName == digest || (mountName.hasPrefix(digest) && duplicate) else { throw Error.forbidden }
        }
        return folder
    }

    func delete(fileID: String, folderFileID: String, calendarHref: String, access: PhotoServerAccess) async throws {
        let folder = try await validatedFolder(fileID: folderFileID, calendarHref: calendarHref, access: access)
        let original: Resource
        do { original = try await resolve(fileID: fileID, access: access) }
        catch Error.notFound { return }
        guard !original.isFolder, original.ownerID == folder.ownerID,
              original.url.deletingLastPathComponent().path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == folder.url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw Error.forbidden }
        _ = try await request(original.url, method: "DELETE", access: access, accepted: [204, 404])
    }

    func delete(fileID: String, access: PhotoServerAccess) async throws {
        let resource: Resource
        do { resource = try await resolve(fileID: fileID, access: access) }
        catch Error.notFound { return } // Durable cleanup is safe to retry.
        guard !resource.isFolder else { throw Error.invalidResponse }
        _ = try await request(resource.url, method: "DELETE", access: access, accepted: [204, 404])
    }

    private var originalLimit: Int { max(0, min(configuration.maxOriginalBytes, 25_000_000)) }
    private var metadataLimit: Int { max(0, min(configuration.maxMetadataBytes, 2_000_000)) }

    private struct Resource {
        let fileID: String
        let url: URL
        let isFolder: Bool
        let ownerID: String?
    }

    private func resolve(fileID: String, access: PhotoServerAccess) async throws -> Resource {
        try validID(fileID)
        let server = try Server(access)
        let xml = """
        <d:searchrequest xmlns:d="DAV:" xmlns:o="http://owncloud.org/ns"><d:basicsearch>
        <d:select><d:prop><o:fileid/><d:resourcetype/><o:owner-id/></d:prop></d:select>
        <d:from><d:scope><d:href>/files/\(PhotoXML.escape(server.encodedUsername))</d:href><d:depth>infinity</d:depth></d:scope></d:from>
        <d:where><d:eq><d:prop><o:fileid/></d:prop><d:literal>\(fileID)</d:literal></d:eq></d:where>
        <d:limit><d:nresults>2</d:nresults></d:limit></d:basicsearch></d:searchrequest>
        """
        let data = try await request(server.davURL, method: "SEARCH", body: Data(xml.utf8), access: access, accepted: [207])
        let root = try PhotoXML.parse(data)
        guard root.key == PhotoXML.key(Self.dav, "multistatus") else { throw Error.invalidResponse }
        let responses = root.elements(Self.dav, "response")
        var found: [Resource] = []
        for response in responses {
            let props = try successfulProperties(response)
            guard let id = props[PhotoXML.key(Self.oc, "fileid")]?.text else { continue }
            try validID(id)
            guard id == fileID else { throw Error.invalidResponse }
            guard let href = response.only(Self.dav, "href")?.text else { throw Error.invalidResponse }
            let url = try server.fileURL(href)
            guard let type = props[PhotoXML.key(Self.dav, "resourcetype")] else { throw Error.invalidResponse }
            found.append(.init(fileID: id, url: url, isFolder: type.only(Self.dav, "collection") != nil, ownerID: props[PhotoXML.key(Self.oc, "owner-id")]?.text))
        }
        guard !found.isEmpty else { throw Error.notFound }
        guard found.count == 1 else { throw Error.invalidResponse }
        return found[0]
    }

    private func propertiesAt(_ url: URL, access: PhotoServerAccess, server: Server) async throws -> Resource {
        let xml = propfind("<o:fileid/><d:resourcetype/><o:owner-id/>")
        let data = try await request(url, method: "PROPFIND", body: Data(xml.utf8), access: access, headers: ["Depth": "0"], accepted: [207])
        let response = try responseNode(data, url: url, server: server)
        let properties = try successfulProperties(response)
        guard let id = properties[PhotoXML.key(Self.oc, "fileid")]?.text,
              let type = properties[PhotoXML.key(Self.dav, "resourcetype")] else { throw Error.invalidResponse }
        try validID(id)
        return .init(fileID: id, url: url, isFolder: type.only(Self.dav, "collection") != nil, ownerID: properties[PhotoXML.key(Self.oc, "owner-id")]?.text)
    }

    private func validID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 20, id.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let number = UInt64(id), number > 0 else { throw Error.invalidFileID }
    }

    private func propfind(_ properties: String) -> String {
        "<d:propfind xmlns:d=\"DAV:\" xmlns:o=\"http://owncloud.org/ns\" xmlns:n=\"http://nextcloud.org/ns\" xmlns:i=\"http://inverse.ca/ns/\"><d:prop>" + properties + "</d:prop></d:propfind>"
    }

    private func responseNode(_ data: Data, url: URL, server: Server) throws -> PhotoXML.Node {
        let root = try PhotoXML.parse(data)
        guard root.key == PhotoXML.key(Self.dav, "multistatus"), root.elements(Self.dav, "response").count == 1,
              let response = root.only(Self.dav, "response"), let href = response.only(Self.dav, "href")?.text else { throw Error.invalidResponse }
        let responseURL = try server.url(href)
        guard responseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else {
            throw Error.invalidResponse
        }
        return response
    }

    private func isSuccessful(_ propstat: PhotoXML.Node) -> Bool {
        guard let status = propstat.only(Self.dav, "status")?.text.split(separator: " "), status.count >= 2, status[0].hasPrefix("HTTP/"), let code = Int(status[1]) else { return false }
        return code == 200
    }

    private func successfulProperties(_ response: PhotoXML.Node) throws -> [String: PhotoXML.Node] {
        var result: [String: PhotoXML.Node] = [:]
        for block in response.elements(Self.dav, "propstat") where isSuccessful(block) {
            guard let prop = block.only(Self.dav, "prop") else { throw Error.invalidResponse }
            for child in prop.children {
                guard result[child.key] == nil else { throw Error.invalidResponse }
                result[child.key] = child
            }
        }
        return result
    }

    private struct Principal {
        let id: String
        let kind: Int
        var token: String { "\(kind):\(id)" }
    }

    private func principal(_ href: String, server: Server, allowGroup: Bool = false) throws -> Principal {
        let path: String
        if href.hasPrefix("principal:") {
            path = String(href.dropFirst("principal:".count))
        } else if href.hasPrefix("principals/") {
            path = href
        } else {
            let url = try server.url(href)
            guard url.path.hasPrefix(server.davURL.path + "/") else { throw Error.incompleteCalendarMetadata }
            path = String(url.path.dropFirst(server.davURL.path.count + 1))
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "principals" else { throw Error.incompleteCalendarMetadata }
        let kind: Int
        switch parts[1] {
        case "users": kind = 0
        case "groups" where allowGroup: kind = 1
        default: throw Error.unsupportedShareKind(String(parts[1]))
        }
        let id = String(parts[2]).removingPercentEncoding ?? String(parts[2])
        guard Server.safeSegment(id) else { throw Error.incompleteCalendarMetadata }
        return .init(id: id, kind: kind)
    }

    private struct Share {
        let id: String
        let kind: Int
        let recipient: String
        let permissions: Int
        var token: String { "\(kind):\(recipient)" }
    }

    private func shares(relativePath: String, fileID: String, access: PhotoServerAccess, server: Server) async throws -> [Share] {
        var components = URLComponents(url: server.ocsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "path", value: relativePath), .init(name: "reshares", value: "false"), .init(name: "subfiles", value: "false"), .init(name: "format", value: "json")]
        let data = try await request(components.url!, method: "GET", access: access, headers: ocsHeaders, accepted: [200])
        let entries = try ocsEntries(data, requireList: true)
        var seen = Set<String>()
        return try entries.map { fields in
            guard let id = fields["id"], let kindText = fields["share_type"], let kind = Int(kindText),
                  let permissionsText = fields["permissions"], let permissions = Int(permissionsText), permissions >= 1, permissions <= 31,
                  fields["uid_owner"] == access.username, fields["file_source"] == fileID,
                  fields["uid_file_owner"] == nil || fields["uid_file_owner"] == access.username,
                  fields["path"] == nil || fields["path"] == relativePath,
                  seen.insert(id).inserted else { throw Error.incompleteShareMetadata }
            try validID(id)
            guard [0, 1, 3].contains(kind) else { throw Error.unsupportedShareKind(kindText) }
            let recipient = fields["share_with"] ?? ""
            if kind != 3, recipient.isEmpty { throw Error.incompleteShareMetadata }
            return .init(id: id, kind: kind, recipient: recipient, permissions: permissions)
        }
    }

    private var ocsHeaders: [String: String] { ["OCS-APIRequest": "true", "Accept": "application/json"] }

    private func mutateShare(id: String?, method: String, fields: [(String, String)], access: PhotoServerAccess, server: Server) async throws {
        var url = server.ocsURL
        if let id { try validID(id); url.appendPathComponent(id) }
        var headers = ocsHeaders
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        let form = fields.map { Server.encode($0.0) + "=" + Server.encode($0.1) }.joined(separator: "&")
        let data = try await request(url, method: method, body: fields.isEmpty ? nil : Data(form.utf8), access: access, headers: headers, accepted: [200])
        _ = try ocsEntries(data, requireList: false)
    }

    /// HTTP success is insufficient: both JSON and XML OCS envelopes carry
    /// a separate status code. A list must have an explicit complete data set.
    private func ocsEntries(_ data: Data, requireList: Bool) throws -> [[String: String]] {
        if data.first(where: { ![9, 10, 13, 32].contains($0) }) == 123 {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ocs = root["ocs"] as? [String: Any], let meta = ocs["meta"] as? [String: Any],
                  let codeText = scalar(meta["statuscode"]), let code = Int(codeText), let status = meta["status"] as? String else { throw Error.invalidResponse }
            guard [100, 200].contains(code), status == "ok" else { throw Error.ocsStatus(code) }
            guard let payload = ocs["data"] else { throw Error.incompleteShareMetadata }
            if !requireList { return [] }
            guard let list = payload as? [[String: Any]] else { throw Error.incompleteShareMetadata }
            if let total = meta["totalitems"] {
                guard let text = scalar(total), Int(text) == list.count else { throw Error.incompleteShareMetadata }
            }
            return list.map { $0.compactMapValues { scalar($0) } }
        }
        let root = try PhotoXML.parse(data)
        guard root.key == PhotoXML.key("", "ocs"), let meta = root.only("", "meta"),
              let codeText = meta.only("", "statuscode")?.text, let code = Int(codeText),
              let status = meta.only("", "status")?.text else { throw Error.invalidResponse }
        guard [100, 200].contains(code), status == "ok" else { throw Error.ocsStatus(code) }
        guard let payload = root.only("", "data") else { throw Error.incompleteShareMetadata }
        if !requireList { return [] }
        guard payload.text.isEmpty else { throw Error.incompleteShareMetadata }
        if let total = meta.only("", "totalitems") {
            guard Int(total.text) == payload.children.count else { throw Error.incompleteShareMetadata }
        }
        return try payload.children.map { entry in
            guard entry.key == PhotoXML.key("", "element") else { throw Error.incompleteShareMetadata }
            var fields: [String: String] = [:]
            for child in entry.children {
                guard child.namespace.isEmpty, fields[child.name] == nil else { throw Error.incompleteShareMetadata }
                fields[child.name] = child.text
            }
            return fields
        }
    }

    private func scalar(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    private func request(_ url: URL, method: String, body: Data? = nil, access: PhotoServerAccess, headers: [String: String] = [:], accepted: Set<Int>, original: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        let remaining = runDeadline?.timeIntervalSinceNow ?? 60
        guard remaining > 0 else { throw CancellationError() }
        let server = try Server(access)
        _ = try server.url(url.absoluteString, allowQuery: true)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(60, remaining))
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("Basic " + Data((access.username + ":" + access.password).utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let delegate = PhotoRequestDelegate()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do { (bytes, response) = try await session.bytes(for: request, delegate: delegate) }
        catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw transportError(error)
        }
        guard let http = response as? HTTPURLResponse, let responseURL = http.url else { bytes.task.cancel(); throw Error.invalidResponse }
        do { _ = try server.url(responseURL.absoluteString, allowQuery: true) } catch { bytes.task.cancel(); throw error }
        guard responseURL == url else { bytes.task.cancel(); throw Error.unsafeRedirect }
        guard !(300..<400).contains(http.statusCode) else { bytes.task.cancel(); throw Error.unsafeRedirect }
        guard accepted.contains(http.statusCode) else { bytes.task.cancel(); throw statusError(http.statusCode) }
        if method == "GET", url.path == server.ocsURL.path,
           http.value(forHTTPHeaderField: "Link")?.lowercased().contains("rel=\"next\"") == true {
            bytes.task.cancel()
            throw Error.incompleteShareMetadata
        }
        let limit = original ? originalLimit : metadataLimit
        guard response.expectedContentLength <= Int64(limit) else { bytes.task.cancel(); throw original ? Error.originalTooLarge : Error.responseTooLarge }
        var data = Data()
        data.reserveCapacity(min(limit, 64_000))
        do {
            for try await byte in bytes {
                if data.count & 0x3fff == 0 {
                    try Task.checkCancellation()
                    if let runDeadline, runDeadline <= Date() { throw CancellationError() }
                }
                guard data.count < limit else { bytes.task.cancel(); throw original ? Error.originalTooLarge : Error.responseTooLarge }
                data.append(byte)
            }
        } catch let error as URLError {
            bytes.task.cancel()
            if Task.isCancelled { throw CancellationError() }
            throw transportError(error)
        } catch { bytes.task.cancel(); throw error }
        return data
    }

    private func transportError(_ error: URLError) -> Error {
        switch error.code {
        case .userAuthenticationRequired, .userCancelledAuthentication: .unauthorized
        default: .transport(error.code.rawValue)
        }
    }

    private func statusError(_ status: Int) -> Error {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 413: .originalTooLarge
        case 507: .quotaExceeded
        case 405, 501: .unsupportedAPI
        default: .httpStatus(status)
        }
    }

    private struct Server {
        let base: URL
        let davURL: URL
        let filesURL: URL
        let ocsURL: URL
        let encodedUsername: String

        init(_ access: PhotoServerAccess) throws {
            guard Self.safeSegment(access.username), !access.username.contains(":"),
                  let components = URLComponents(string: access.baseURL), components.scheme?.lowercased() == "https",
                  components.host != nil, components.user == nil, components.password == nil,
                  components.query == nil, components.fragment == nil, let base = components.url else { throw Error.unsafeURL }
            try Self.safePath(components.percentEncodedPath)
            self.base = base
            self.davURL = base.appendingPathComponent("remote.php/dav", isDirectory: true)
            self.filesURL = davURL.appendingPathComponent("files", isDirectory: true).appendingPathComponent(access.username, isDirectory: true)
            self.ocsURL = base.appendingPathComponent("ocs/v2.php/apps/files_sharing/api/v1/shares")
            self.encodedUsername = Self.encode(access.username)
        }

        static func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
        }

        static func safeSegment(_ value: String) -> Bool {
            !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\") && !value.contains("%") && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }

        static func safePath(_ encoded: String) throws {
            for part in encoded.split(separator: "/", omittingEmptySubsequences: false) where !part.isEmpty {
                guard let decoded = String(part).removingPercentEncoding, safeSegment(decoded) else { throw Error.unsafeURL }
            }
            guard !encoded.contains("//") else { throw Error.unsafeURL }
        }

        func url(_ href: String, allowQuery: Bool = false) throws -> URL {
            // Validate before Foundation can normalize traversal away.
            guard !href.contains("\\"), !href.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let raw = URLComponents(string: href), raw.user == nil, raw.password == nil, (allowQuery || raw.query == nil), raw.fragment == nil else { throw Error.unsafeURL }
            try Self.safePath(raw.percentEncodedPath)
            guard let url = URL(string: href, relativeTo: base.appendingPathComponent("", isDirectory: true))?.absoluteURL,
                  let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  parts.scheme?.lowercased() == base.scheme?.lowercased(), parts.host?.lowercased() == base.host?.lowercased(),
                  (parts.port ?? 443) == (base.port ?? 443) else { throw Error.unsafeURL }
            let basePath = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !basePath.isEmpty { guard url.path.hasPrefix("/" + basePath + "/") else { throw Error.unsafeURL } }
            return url
        }

        func calendarURL(_ href: String) throws -> URL {
            let result = try url(href)
            guard result.path.hasPrefix(davURL.path + "/calendars/"), result.path.split(separator: "/").count >= davURL.path.split(separator: "/").count + 3 else { throw Error.unsafeURL }
            return result
        }

        func fileURL(_ href: String) throws -> URL {
            let result = try url(href)
            guard result.path.hasPrefix(filesURL.path + "/") else { throw Error.unsafeURL }
            return result
        }
    }
}

/// Per-task delegate also applies to injected sessions. Refusing every redirect
/// prevents Authorization/body forwarding and method downgrades on DAV writes.
private final class PhotoRequestDelegate: NSObject, URLSessionDataDelegate, Sendable {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping @Sendable (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Deliberately separate from the app's calendar parser: namespaced, bounded,
/// no DTD/entity expansion, and properties only from successful DAV propstats.
private final class PhotoXML: NSObject, XMLParserDelegate {
    final class Node {
        let namespace: String
        let name: String
        var text = ""
        var children: [Node] = []
        var key: String { PhotoXML.key(namespace, name) }
        var hrefOrText: String { only("DAV:", "href")?.text ?? text }
        init(namespace: String, name: String) { self.namespace = namespace; self.name = name }
        func elements(_ namespace: String, _ name: String) -> [Node] { children.filter { $0.key == PhotoXML.key(namespace, name) } }
        func only(_ namespace: String, _ name: String) -> Node? {
            let matches = elements(namespace, name)
            return matches.count == 1 ? matches[0] : nil
        }
    }
    private var stack: [Node] = []
    private var root: Node?
    private var count = 0
    static func key(_ namespace: String, _ name: String) -> String { "{\(namespace)}\(name)" }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func parse(_ data: Data) throws -> Node {
        guard let text = String(data: data, encoding: .utf8), !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw NextcloudPhotoClient.Error.invalidResponse }
        let delegate = PhotoXML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, delegate.stack.isEmpty else { throw NextcloudPhotoClient.Error.invalidResponse }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        count += 1
        guard count <= 20_000, stack.count < 64 else { parser.abortParsing(); return }
        let node = Node(namespace: namespaceURI ?? "", name: elementName)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.last?.text = stack.last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = stack.popLast()
    }
}
