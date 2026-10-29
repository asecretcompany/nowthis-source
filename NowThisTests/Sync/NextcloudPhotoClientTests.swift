import Foundation
import CryptoKit
import Testing
@testable import NowThis

@Suite("Nextcloud photo transport", .serialized)
struct NextcloudPhotoClientTests {
    private let access = PhotoServerAccess(baseURL: "https://cloud.invalid/nested/cloud", username: "alice", password: "secret")
    private let calendar = "/nested/cloud/remote.php/dav/calendars/alice/tasks/"
    private let filePath = "/nested/cloud/remote.php/dav/files/alice/Shared/photo"
    private let uuid = "3D2BD042-939D-416D-B3C5-242139F6BEE1"

    private func client(_ replies: [PhotoProtocol.Reply], configuration: NextcloudPhotoClient.Configuration = .init()) -> NextcloudPhotoClient {
        PhotoProtocol.install(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PhotoProtocol.self]
        return NextcloudPhotoClient(session: URLSession(configuration: config), configuration: configuration)
    }

    // Mirrors DAV Sharing/Xml/Invite.php: oc:user, DAV:href, oc:access.
    private func invitation(_ id: String, kind: String = "users", edit: Bool = false) -> String {
        "<o:user><d:href>principal:principals/\(kind)/\(id)</d:href><o:invite-accepted/><o:access><o:\(edit ? "read-write" : "read")/></o:access></o:user>"
    }
    private func calendarXML(_ invites: String? = "", extra: String = "", owner: String = "alice", status: Int = 200) -> String {
        let properties = "<o:owner-principal>principals/users/\(owner)</o:owner-principal>" + (invites.map { "<o:invite>\($0)</o:invite>" } ?? "") + extra
        return dav(calendar, properties: properties, status: status)
    }
    private func dav(_ href: String, properties: String, status: Int = 200) -> String {
        "<d:multistatus xmlns:d=\"DAV:\" xmlns:o=\"http://owncloud.org/ns\" xmlns:n=\"http://nextcloud.org/ns\" xmlns:i=\"http://inverse.ca/ns/\"><d:response><d:href>\(href)</d:href><d:propstat><d:prop>\(properties)</d:prop><d:status>HTTP/1.1 \(status) Status</d:status></d:propstat></d:response></d:multistatus>"
    }
    private func fileXML(_ id: String = "42", href: String? = nil, folder: Bool = false, owner: String? = nil) -> String {
        dav(href ?? filePath, properties: "<o:fileid>\(id)</o:fileid><d:resourcetype>\(folder ? "<d:collection/>" : "")</d:resourcetype>" + (owner.map { "<o:owner-id>\($0)</o:owner-id>" } ?? ""))
    }
    private func ocs(_ entries: String = "[]", code: Int = 100) -> String {
        "{\"ocs\":{\"meta\":{\"status\":\"\(code == 100 ? "ok" : "failure")\",\"statuscode\":\(code)},\"data\":\(entries)}}"
    }
    private func preparedReplies(_ invites: String = "", shares: String = "[]") -> [PhotoProtocol.Reply] {
        [.xml(calendarXML(invites)), .status(201), .xml(fileXML("8", href: "__REQUEST_HREF__", folder: true, owner: "alice")), .json(ocs()), .status(405), .xml(fileXML("9", href: "__REQUEST_HREF__", folder: true, owner: "alice")), .json(ocs(shares)), .json(ocs())]
    }

    @Test func invitationsProvideExactUserGroupPermissions() async throws {
        let c = client([.xml(calendarXML(invitation("bob") + invitation("team", kind: "groups", edit: true)))])
        let result = try await c.inspectCalendar(calendarHref: calendar, access: access)
        #expect(result == PhotoCalendarAccess(ownerID: "alice", sharees: [.init(id: "bob", kind: 0, canEdit: false), .init(id: "team", kind: 1, canEdit: true)]))
        let request = try #require(PhotoProtocol.requests.first)
        #expect(request.method == "PROPFIND")
        #expect(request.headers["Depth"] == "0")
        #expect(request.headers["Authorization"] == "Basic " + Data("alice:secret".utf8).base64EncodedString())
        #expect(request.body.contains("owner-principal"))
        #expect(request.body.contains("invite"))
    }

    @Test func explicitEmptyInvitationSetIsComplete() async throws {
        let c = client([.xml(calendarXML())])
        #expect(try await c.inspectCalendar(calendarHref: calendar, access: access).sharees.isEmpty)
    }

    @Test(arguments: ["missing", "failed", "wrongNamespace", "missingAccess", "partialSharees", "duplicate"])
    func incompleteCalendarNeverMutatesShares(_ scenario: String) async throws {
        let body: String
        switch scenario {
        case "missing": body = calendarXML(nil)
        case "failed": body = calendarXML("", status: 404)
        case "wrongNamespace": body = calendarXML(nil, extra: "<n:invite/>")
        case "missingAccess": body = calendarXML("<o:user><d:href>principal:principals/users/bob</d:href></o:user>")
        case "partialSharees": body = calendarXML(invitation("bob"), extra: "<n:sharees><n:sharee><n:id>other</n:id><n:type>0</n:type></n:sharee></n:sharees>")
        default: body = calendarXML(invitation("bob") + invitation("bob", edit: true))
        }
        let c = client([.xml(body)])
        await #expect(throws: NextcloudPhotoClient.Error.incompleteCalendarMetadata) {
            try await c.prepareFolder(calendarHref: calendar, access: access)
        }
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func unsupportedCalendarKindIsExplicit() async throws {
        let c = client([.xml(calendarXML(invitation("circle", kind: "circles")))])
        await #expect(throws: NextcloudPhotoClient.Error.unsupportedShareKind("circles")) {
            try await c.prepareFolder(calendarHref: calendar, access: access)
        }
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func sharedCalendarCannotProvisionOwnerFolder() async throws {
        let c = client([.xml(calendarXML("", owner: "bob"))])
        await #expect(throws: NextcloudPhotoClient.Error.notCalendarOwner) {
            try await c.prepareFolder(calendarHref: calendar, access: access)
        }
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func inverseSharedOwnerOverridesRecipientOwner() async throws {
        let c = client([.xml(calendarXML("", extra: "<d:owner><d:href>/nested/cloud/remote.php/dav/principals/users/alice/</d:href></d:owner><i:shared-owner><d:href>/nested/cloud/remote.php/dav/principals/users/bob/</d:href></i:shared-owner>", owner: "bob"))])
        let result = try await c.inspectCalendar(calendarHref: calendar, access: access)
        #expect(result.ownerID == "bob")
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func folderUsesStableDigestAndExplicitLeastPermissions() async throws {
        let invites = invitation("bob") + invitation("team", kind: "groups", edit: true)
        var replies = preparedReplies(invites)
        replies.insert(.json(ocs()), at: 7)
        replies.append(.json(ocs("[{\"id\":\"1\",\"share_type\":0,\"share_with\":\"bob\",\"permissions\":1,\"uid_owner\":\"alice\",\"file_source\":9},{\"id\":\"2\",\"share_type\":1,\"share_with\":\"team\",\"permissions\":15,\"uid_owner\":\"alice\",\"file_source\":9}]")))
        let c = client(replies)
        _ = try await c.prepareFolder(calendarHref: calendar, access: access)
        let requests = PhotoProtocol.requests
        let folderRequest = try #require(requests.first { $0.method == "MKCOL" && !$0.path.hasSuffix("NowThis Photos/") })
        let digest = folderRequest.path.split(separator: "/").last ?? ""
        #expect(digest.count == 64 && digest.allSatisfy { $0.isHexDigit })
        #expect(folderRequest.path.contains("/files/alice/NowThis Photos/"))
        let creates = requests.filter { $0.method == "POST" }
        #expect(creates.count == 2)
        #expect(creates.contains { $0.body.contains("permissions=1&") || $0.body.hasSuffix("permissions=1") })
        #expect(creates.contains { $0.body.contains("permissions=15") })
        #expect(creates.allSatisfy { $0.body.contains("sendMail=false") && !$0.body.contains("shareType=3") })
        #expect(requests.filter { $0.path.contains("/ocs/") }.allSatisfy { $0.headers["OCS-APIRequest"] == "true" })
    }

    @Test func reconcileUpdatesRemovesAndDeletesPublicLink() async throws {
        let existing = "[{\"id\":\"1\",\"share_type\":0,\"share_with\":\"bob\",\"permissions\":31,\"uid_owner\":\"alice\",\"file_source\":9},{\"id\":\"2\",\"share_type\":1,\"share_with\":\"old\",\"permissions\":15,\"uid_owner\":\"alice\",\"file_source\":9},{\"id\":\"3\",\"share_type\":3,\"permissions\":1,\"uid_owner\":\"alice\",\"file_source\":9}]"
        var replies = preparedReplies(invitation("bob"), shares: existing)
        replies.append(contentsOf: [.json(ocs()), .json(ocs()), .json(ocs("[{\"id\":\"1\",\"share_type\":0,\"share_with\":\"bob\",\"permissions\":1,\"uid_owner\":\"alice\",\"file_source\":9}]"))])
        let c = client(replies)
        _ = try await c.prepareFolder(calendarHref: calendar, access: access)
        #expect(PhotoProtocol.requests.filter { $0.method == "PUT" }.map(\.body) == ["permissions=1&sendMail=false"])
        #expect(PhotoProtocol.requests.filter { $0.method == "DELETE" }.map { $0.path.split(separator: "/").last! } == ["2", "3"])
    }

    @Test(arguments: ["missingOwner", "wrongFile", "unknownKind", "truncated", "foreignOwner"])
    func incompleteOCSListNeverRevokes(_ scenario: String) async throws {
        let entry: String
        switch scenario {
        case "missingOwner": entry = "[{\"id\":1,\"share_type\":0,\"share_with\":\"old\",\"permissions\":1,\"file_source\":9}]"
        case "wrongFile": entry = "[{\"id\":1,\"share_type\":0,\"share_with\":\"old\",\"permissions\":1,\"file_source\":99,\"uid_owner\":\"alice\"}]"
        case "unknownKind": entry = "[{\"id\":1,\"share_type\":6,\"share_with\":\"remote\",\"permissions\":1,\"file_source\":9,\"uid_owner\":\"alice\"}]"
        case "foreignOwner": entry = "[{\"id\":1,\"share_type\":0,\"share_with\":\"old\",\"permissions\":1,\"file_source\":9,\"uid_owner\":\"other\"}]"
        default: entry = "{}"
        }
        let c = client(preparedReplies(shares: entry))
        await #expect(throws: (any Swift.Error).self) { try await c.prepareFolder(calendarHref: calendar, access: access) }
        #expect(PhotoProtocol.requests.count == 7)
        #expect(!PhotoProtocol.requests.contains { ["DELETE", "PUT", "POST"].contains($0.method) })
    }

    @Test func resolveSearchesRecipientsFilesMount() async throws {
        let c = client([.xml(fileXML(folder: true))])
        let folder = try await c.resolveFolder(fileID: "42", access: access)
        #expect(folder.fileID == "42")
        #expect(folder.href == "https://cloud.invalid" + filePath)
        let request = try #require(PhotoProtocol.requests.first)
        #expect(request.method == "SEARCH")
        #expect(request.path == "/nested/cloud/remote.php/dav/")
        #expect(request.body.contains("<d:href>/files/alice</d:href>"))
        #expect(request.body.contains("<d:literal>42</d:literal>"))
    }

    @Test(arguments: ["https://evil.invalid/photo", "/nested/cloud/remote.php/dav/files/bob/photo", "/nested/cloud/remote.php/dav/files/alice/../bob/photo", "/nested/cloud/remote.php/dav/files/alice/%252e%252e/bob/photo", "/nested/cloud/remote.php/dav/files/alice/%2fetc", "https://user:pass@cloud.invalid/nested/cloud/remote.php/dav/files/alice/a", "/nested/cloud/remote.php/dav/files/alice/photo?token=x"])
    func hostileFileHrefIsRejected(_ href: String) async throws {
        let c = client([.xml(fileXML(href: href))])
        await #expect(throws: NextcloudPhotoClient.Error.unsafeURL) { try await c.download(fileID: "42", access: access) }
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func failedFileIDPropertyCannotBeUsed() async throws {
        let c = client([.xml(dav(filePath, properties: "<o:fileid>42</o:fileid>", status: 404))])
        await #expect(throws: NextcloudPhotoClient.Error.notFound) { try await c.download(fileID: "42", access: access) }
    }

    @Test func uploadRetriesSameUUIDWithoutOverwriteOn412() async throws {
        let c = client([.xml(fileXML("9", folder: true)), .status(412), .xml(fileXML("73", href: filePath + "/" + uuid.lowercased()))])
        let result = try await c.upload(data: Data([1, 2, 3]), contentType: "image/jpeg", photoID: uuid, folder: .init(fileID: "9", href: "https://evil.invalid/private"), access: access)
        #expect(result == "73")
        let request = try #require(PhotoProtocol.requests.first { $0.method == "PUT" })
        #expect(request.headers["If-None-Match"] == "*")
        #expect(request.path.hasSuffix(uuid.lowercased()))
        #expect(PhotoProtocol.requests.map(\.method) == ["SEARCH", "PUT", "PROPFIND"])
    }

    @Test func uploadReturnsIDAfterPut() async throws {
        let c = client([.xml(fileXML("9", folder: true)), .status(201), .xml(fileXML("73", href: filePath + "/" + uuid.lowercased()))])
        #expect(try await c.upload(data: Data([1]), contentType: "image/heic", photoID: uuid, folder: .init(fileID: "9", href: "ignored"), access: access) == "73")
    }

    @Test(arguments: ["image/avif", "image/x-adobe-dng", "application/octet-stream"])
    func uploadAcceptsOtherOriginalMIMETypes(_ type: String) async throws {
        let c = client([.xml(fileXML("9", folder: true)), .status(201), .xml(fileXML("73", href: filePath + "/" + uuid.lowercased()))])
        #expect(try await c.upload(data: Data([1]), contentType: type, photoID: uuid, folder: .init(fileID: "9", href: "ignored"), access: access) == "73")
        #expect(PhotoProtocol.requests.first { $0.method == "PUT" }?.headers["Content-Type"] == type)
    }

    @Test(arguments: ["image/jpeg\r\nInjected: bad", "", "image/jpeg; bad", "image/"])
    func invalidMIMETypeMakesNoRequest(_ type: String) async throws {
        let c = client([])
        await #expect(throws: NextcloudPhotoClient.Error.invalidResponse) { try await c.upload(data: Data([1]), contentType: type, photoID: uuid, folder: .init(fileID: "9", href: "ignored"), access: access) }
        #expect(PhotoProtocol.requests.isEmpty)
    }

    @Test func downloadAndDeleteResolveByID() async throws {
        let c = client([.xml(fileXML()), .init(status: 200, data: Data([1, 2, 3])), .xml(fileXML()), .status(204)])
        #expect(try await c.download(fileID: "42", access: access) == Data([1, 2, 3]))
        try await c.delete(fileID: "42", access: access)
        #expect(PhotoProtocol.requests.map(\.method) == ["SEARCH", "GET", "SEARCH", "DELETE"])
    }

    @Test(arguments: [401, 403, 404, 413, 507, 429, 500, 405])
    func statusesMapToTypedErrors(_ status: Int) async throws {
        let expected: NextcloudPhotoClient.Error = switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 413: .originalTooLarge
        case 507: .quotaExceeded
        case 405: .unsupportedAPI
        default: .httpStatus(status)
        }
        let c = client([.status(status)])
        await #expect(throws: expected) { try await c.download(fileID: "42", access: access) }
    }

    @Test(arguments: ["json", "xml"])
    func ocsErrorInsideHTTP200IsRejected(_ format: String) async throws {
        var replies = preparedReplies()
        replies[6] = format == "json" ? .json(ocs(code: 403)) : .xml("<ocs><meta><status>failure</status><statuscode>403</statuscode></meta><data/></ocs>", status: 200)
        let c = client(replies)
        await #expect(throws: NextcloudPhotoClient.Error.ocsStatus(403)) { try await c.prepareFolder(calendarHref: calendar, access: access) }
        #expect(PhotoProtocol.requests.count == 7)
    }

    @Test func xmlOCSAndVerifiedEmptySharesWork() async throws {
        var replies = preparedReplies()
        replies[6] = .xml("<ocs><meta><status>ok</status><statuscode>100</statuscode></meta><data/></ocs>", status: 200)
        replies[7] = replies[6]
        let c = client(replies)
        #expect(try await c.prepareFolder(calendarHref: calendar, access: access).fileID == "9")
    }

    @Test func uploadAndDownloadLimitsAreBounded() async throws {
        let c = client([], configuration: .init(maxOriginalBytes: 4, maxMetadataBytes: 500))
        await #expect(throws: NextcloudPhotoClient.Error.originalTooLarge) { try await c.upload(data: Data(repeating: 1, count: 5), contentType: "image/jpeg", photoID: uuid, folder: .init(fileID: "9", href: filePath), access: access) }
        #expect(PhotoProtocol.requests.isEmpty)
        let d = client([.xml(fileXML()), .init(status: 200, data: Data(repeating: 1, count: 5))], configuration: .init(maxOriginalBytes: 4, maxMetadataBytes: 2_000))
        await #expect(throws: NextcloudPhotoClient.Error.originalTooLarge) { try await d.download(fileID: "42", access: access) }
        let m = client([.init(status: 207, data: Data(repeating: 65, count: 501))], configuration: .init(maxMetadataBytes: 500))
        await #expect(throws: NextcloudPhotoClient.Error.responseTooLarge) { try await m.inspectCalendar(calendarHref: calendar, access: access) }
    }

    @Test func redirectsAreRefusedBeforeCredentialForwarding() async throws {
        let c = client([.init(status: 302, data: Data(), headers: ["Location": "https://evil.invalid/steal"])])
        await #expect(throws: NextcloudPhotoClient.Error.unsafeRedirect) { try await c.download(fileID: "42", access: access) }
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func unsupportedOptionalShareesDoesNotInvalidateCompleteInvitations() async throws {
        let xml = calendarXML(invitation("bob")).replacingOccurrences(of: "</d:response>", with: "<d:propstat><d:prop><n:sharees/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>")
        let c = client([.xml(xml)])
        #expect(try await c.inspectCalendar(calendarHref: calendar, access: access).sharees == [.init(id: "bob", kind: 0, canEdit: false)])
    }

    @Test func sharedParentFolderCannotLeakInheritedAccess() async throws {
        let rootShares = "[{\"id\":\"1\",\"share_type\":3,\"permissions\":1,\"uid_owner\":\"alice\",\"file_source\":8}]"
        let c = client([.xml(calendarXML()), .status(201), .xml(fileXML("8", href: "__REQUEST_HREF__", folder: true, owner: "alice")), .json(ocs(rootShares))])
        await #expect(throws: NextcloudPhotoClient.Error.unsafeFolder) { try await c.prepareFolder(calendarHref: calendar, access: access) }
        #expect(!PhotoProtocol.requests.contains { ["POST", "PUT", "DELETE"].contains($0.method) })
    }

    @Test func inversePropertyAloneCannotEstablishOwnership() async throws {
        let xml = calendarXML("", extra: "<i:shared-owner><d:href>/nested/cloud/remote.php/dav/principals/users/alice/</d:href></i:shared-owner>").replacingOccurrences(of: "<o:owner-principal>principals/users/alice</o:owner-principal>", with: "")
        let c = client([.xml(xml)])
        await #expect(throws: NextcloudPhotoClient.Error.incompleteCalendarMetadata) { try await c.prepareFolder(calendarHref: calendar, access: access) }
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func forgedInverseOwnerCannotElevateRecipient() async throws {
        let c = client([.xml(calendarXML("", extra: "<i:shared-owner><d:href>/nested/cloud/remote.php/dav/principals/users/alice/</d:href></i:shared-owner>", owner: "bob"))])
        await #expect(throws: NextcloudPhotoClient.Error.incompleteCalendarMetadata) { try await c.prepareFolder(calendarHref: calendar, access: access) }
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func partialOCSPaginationCannotRevoke() async throws {
        var replies = preparedReplies()
        replies[6] = .json("{\"ocs\":{\"meta\":{\"status\":\"ok\",\"statuscode\":100,\"totalitems\":2,\"itemsperpage\":1},\"data\":[]}}")
        let c = client(replies)
        await #expect(throws: NextcloudPhotoClient.Error.incompleteShareMetadata) { try await c.prepareFolder(calendarHref: calendar, access: access) }
        #expect(!PhotoProtocol.requests.contains { $0.method == "DELETE" })
    }

    @Test func unverifiedGrantsCannotReportPrepared() async throws {
        let c = client(preparedReplies(invitation("bob")) + [.json(ocs())])
        await #expect(throws: NextcloudPhotoClient.Error.shareVerificationFailed) { try await c.prepareFolder(calendarHref: calendar, access: access) }
    }

    @Test func ownedFolderIsRequiredEvenWhenCalendarIsOwned() async throws {
        var replies = preparedReplies()
        replies[5] = .xml(fileXML("9", href: "__REQUEST_HREF__", folder: true, owner: "bob"))
        let c = client(replies)
        await #expect(throws: NextcloudPhotoClient.Error.notCalendarOwner) { try await c.prepareFolder(calendarHref: calendar, access: access) }
        #expect(PhotoProtocol.requests.count == 6)
    }

    @Test func stableFolderDigestIsIdenticalAcrossRetries() async throws {
        let c = client(preparedReplies() + preparedReplies())
        let first = try await c.prepareFolder(calendarHref: calendar, access: access)
        let second = try await c.prepareFolder(calendarHref: "https://cloud.invalid" + calendar, access: access)
        #expect(first == second)
    }

    @Test(arguments: ["doctype", "duplicateResult", "noFileID", "foreignNamespace"])
    func invalidSearchResponsesAreRejected(_ scenario: String) async throws {
        let xml: String
        switch scenario {
        case "doctype": xml = "<!DOCTYPE root [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]>" + fileXML()
        case "duplicateResult": xml = fileXML().replacingOccurrences(of: "</d:multistatus>", with: String(fileXML().split(separator: ">", maxSplits: 1)[1]))
        case "noFileID": xml = fileXML().replacingOccurrences(of: "<o:fileid>42</o:fileid>", with: "")
        default: xml = fileXML().replacingOccurrences(of: "<o:fileid>42</o:fileid>", with: "<n:fileid>42</n:fileid>")
        }
        let c = client([.xml(xml)])
        await #expect(throws: (any Swift.Error).self) { try await c.download(fileID: "42", access: access) }
        #expect(PhotoProtocol.requests.count == 1)
    }

    @Test func deleteIsIdempotentAndNeverDeletesFolder() async throws {
        let c = client([.status(404)])
        try await c.delete(fileID: "42", access: access)
        #expect(PhotoProtocol.requests.count == 1)
        let d = client([.xml(fileXML(folder: true))])
        await #expect(throws: NextcloudPhotoClient.Error.invalidResponse) { try await d.delete(fileID: "42", access: access) }
        #expect(PhotoProtocol.requests.map(\.method) == ["SEARCH"])
    }

    @Test(arguments: [URLError.Code.userCancelledAuthentication.rawValue, URLError.Code.notConnectedToInternet.rawValue])
    func networkFailuresMapWithoutExposingCredentials(_ code: Int) async throws {
        let c = client([.init(status: 0, data: Data(), failure: code)])
        let expected: NextcloudPhotoClient.Error = code == URLError.Code.userCancelledAuthentication.rawValue ? .unauthorized : .transport(code)
        await #expect(throws: expected) { try await c.download(fileID: "42", access: access) }
    }

    @Test func credentialsNeverReachHostileCalendarURL() async throws {
        let c = client([])
        await #expect(throws: NextcloudPhotoClient.Error.unsafeURL) { try await c.inspectCalendar(calendarHref: "https://evil.invalid/remote.php/dav/calendars/alice/tasks/", access: access) }
        #expect(PhotoProtocol.requests.isEmpty)
    }

    @Test func oversizedDeclaredDownloadIsRefusedBeforeReadingBody() async throws {
        let c = client([.xml(fileXML()), .init(status: 200, data: Data(), headers: ["Content-Length": "25000001"])])
        await #expect(throws: NextcloudPhotoClient.Error.originalTooLarge) { try await c.download(fileID: "42", access: access) }
    }

    @Test func responseCacheIsDisabledForInjectedSession() async throws {
        PhotoProtocol.install([.xml(fileXML()), .init(status: 200, data: Data([1, 2]), headers: ["Cache-Control": "public, max-age=3600", "Content-Type": "image/jpeg"])])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PhotoProtocol.self]
        let cache = URLCache(memoryCapacity: 100_000, diskCapacity: 0)
        config.urlCache = cache
        let c = NextcloudPhotoClient(session: URLSession(configuration: config))
        _ = try await c.download(fileID: "42", access: access)
        #expect(cache.cachedResponse(for: URLRequest(url: URL(string: "https://cloud.invalid" + filePath)!)) == nil)
    }

    @Test(arguments: ["../bad", "not-a-uuid"])
    func unsafePhotoIDMakesNoRequest(_ id: String) async throws {
        let c = client([])
        await #expect(throws: NextcloudPhotoClient.Error.invalidPhotoID) { try await c.upload(data: Data([1]), contentType: "image/jpeg", photoID: id, folder: .init(fileID: "9", href: filePath), access: access) }
        #expect(PhotoProtocol.requests.isEmpty)
    }
    @Test func scopedOriginalReadRefusesAFileOutsideThePhotoFolder() async throws {
        let identity = "alice\n" + calendar.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = "/nested/cloud/remote.php/dav/files/alice/NowThis Photos/" + digest + "/"
        let c = client([.xml(calendarXML()), .xml(fileXML("9", href: path, folder: true, owner: "alice")),
            .xml(fileXML(href: "/nested/cloud/remote.php/dav/files/alice/private/photo", owner: "alice"))])
        await #expect(throws: NextcloudPhotoClient.Error.forbidden) {
            try await c.download(fileID: "42", folderFileID: "9", calendarHref: calendar, access: access)
        }
    }

    @Test func scopedOriginalReadAllowsThisListFolderOnly() async throws {
        let identity = "alice\n" + calendar.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = "/nested/cloud/remote.php/dav/files/alice/NowThis Photos/" + digest + "/"
        let c = client([.xml(calendarXML()), .xml(fileXML("9", href: path, folder: true, owner: "alice")),
            .xml(fileXML(href: path + uuid, owner: "alice")), .init(status: 200, data: Data([1, 2]))])
        #expect(try await c.download(fileID: "42", folderFileID: "9", calendarHref: calendar, access: access) == Data([1, 2]))
        #expect(PhotoProtocol.requests.map(\.method) == ["PROPFIND", "SEARCH", "SEARCH", "GET"])
    }

    @Test func scopedCleanupRefusesPrivateFileOutsideListFolder() async throws {
        let identity = "alice\n" + calendar.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = "/nested/cloud/remote.php/dav/files/alice/NowThis Photos/" + digest + "/"
        let c = client([.xml(calendarXML()), .xml(fileXML("9", href: path, folder: true, owner: "alice")),
            .xml(fileXML(href: "/nested/cloud/remote.php/dav/files/alice/private/photo", owner: "alice"))])
        await #expect(throws: NextcloudPhotoClient.Error.forbidden) {
            try await c.delete(fileID: "42", folderFileID: "9", calendarHref: calendar, access: access)
        }
        #expect(!PhotoProtocol.requests.contains { $0.method == "DELETE" })
    }
    @Test func scopedCleanupDeletesOnlyThisListOriginal() async throws {
        let identity = "alice\n" + calendar.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = "/nested/cloud/remote.php/dav/files/alice/NowThis Photos/" + digest + "/"
        let c = client([.xml(calendarXML()), .xml(fileXML("9", href: path, folder: true, owner: "alice")),
            .xml(fileXML(href: path + uuid, owner: "alice")), .status(204)])
        try await c.delete(fileID: "42", folderFileID: "9", calendarHref: calendar, access: access)
        #expect(PhotoProtocol.requests.map(\.method) == ["PROPFIND", "SEARCH", "SEARCH", "DELETE"])
    }

    @Test func expiredRunDeadlineRefusesNetworkWork() async throws {
        let c = client([])
        await c.setRunDeadline(Date().addingTimeInterval(-1))
        await #expect(throws: CancellationError.self) {
            try await c.inspectCalendar(calendarHref: calendar, access: access)
        }
        #expect(PhotoProtocol.requests.isEmpty)
    }

}

private final class PhotoProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var data: Data
        var headers: [String: String] = [:]
        var failure: Int?
        static func xml(_ body: String, status: Int = 207) -> Reply { .init(status: status, data: Data(body.utf8), headers: ["Content-Type": "application/xml"]) }
        static func json(_ body: String) -> Reply { .init(status: 200, data: Data(body.utf8), headers: ["Content-Type": "application/json"]) }
        static func status(_ code: Int) -> Reply { .init(status: code, data: Data()) }
    }
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: String
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Reply] = []
    nonisolated(unsafe) private static var recorded: [Request] = []
    static var requests: [Request] { lock.withLock { recorded } }
    static func install(_ replies: [Reply]) { lock.withLock { queue = replies; recorded = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var capturedBody = request.httpBody ?? Data()
        if capturedBody.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                capturedBody.append(contentsOf: buffer.prefix(count))
            }
        }
        let reply: Reply? = Self.lock.withLock {
            Self.recorded.append(.init(method: request.httpMethod ?? "", path: request.url?.path(percentEncoded: false) ?? "", headers: request.allHTTPHeaderFields ?? [:], body: String(data: capturedBody, encoding: .utf8) ?? ""))
            return Self.queue.isEmpty ? nil : Self.queue.removeFirst()
        }
        if let code = reply?.failure {
            client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code)))
            return
        }
        guard let reply, let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        let bytes = String(data: reply.data, encoding: .utf8).map { Data($0.replacingOccurrences(of: "__REQUEST_HREF__", with: request.url!.path).utf8) } ?? reply.data
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
