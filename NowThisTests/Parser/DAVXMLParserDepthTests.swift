import Foundation
import Testing

@testable import NowThis

@Suite("DAV XML nesting depth")
struct DAVXMLParserDepthTests {
    private func multistatus(totalDepth: Int, precedingResponse: Bool = false) -> String {
        let responsePrefix = """
        <d:response><d:href>/c/task.ics</d:href><d:propstat><d:prop>
        """
        let prefixDepth = 4
        let nestedCount = totalDepth - prefixDepth
        let nestedOpen = (0..<nestedCount).map { "<x:n\($0)>" }.joined()
        let nestedClose = (0..<nestedCount).reversed().map { "</x:n\($0)>" }.joined()
        let deepResponse = responsePrefix
            + "<d:getetag>\"deep\"</d:getetag>"
            + nestedOpen + nestedClose
            + "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        let firstResponse = """
        <d:response><d:href>/c/first.ics</d:href><d:propstat><d:prop><d:getetag>"first"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        """
        return """
        <d:multistatus xmlns:d="DAV:" xmlns:x="urn:example:depth">
        \(precedingResponse ? firstResponse : "")\(deepResponse)
        </d:multistatus>
        """
    }

    private func expectInvalidResponse(_ xml: String, strictPropertyEvidence: Bool = false,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try DAVXMLParser().parse(data: Data(xml.utf8), strictPropertyEvidence: strictPropertyEvidence)
            Issue.record("Expected CalDAVError.invalidResponse", sourceLocation: sourceLocation)
        } catch CalDAVError.invalidResponse {
            // Expected parser failure.
        } catch {
            Issue.record("Expected CalDAVError.invalidResponse, got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("Exactly 64 nested XML elements are accepted")
    func acceptsMaximumDepth() throws {
        let resources = try DAVXMLParser().parse(data: Data(multistatus(totalDepth: 64).utf8))
        #expect(resources.count == 1)
        #expect(resources.first?.etag == "deep")
    }

    @Test("65 nested XML elements throw invalidResponse")
    func rejectsDepthOverLimit() {
        expectInvalidResponse(multistatus(totalDepth: 65))
    }

    @Test("A normal six-element multistatus still parses")
    func acceptsNormalDepth() throws {
        let resources = try DAVXMLParser().parse(data: Data(multistatus(totalDepth: 6).utf8))
        #expect(resources.count == 1)
        #expect(resources.first?.etag == "deep")
    }

    @Test("Excessive nesting after a valid response aborts the whole result")
    func rejectsWholeDocumentAfterEarlierResponse() {
        expectInvalidResponse(multistatus(totalDepth: 65, precedingResponse: true))
    }

    @Test("Strict evidence rejects malformed status lines and responses inside nested multistatus", arguments: [
        "nested", "HTTP/not-a-version 200 OK", "HTTP/1.11 200 OK", "HTTP/1.1\t200 OK"
    ])
    func strictEvidenceRejectsMalformedResponse(fixture: String) throws {
        let xml = multistatus(totalDepth: 6)
        let malformed = fixture == "nested"
            ? xml.replacingOccurrences(of: "<d:response>", with: "<d:multistatus><d:response>")
                .replacingOccurrences(of: "</d:response>", with: "</d:response></d:multistatus>")
            : xml.replacingOccurrences(of: "HTTP/1.1 200 OK", with: fixture)
        let data = Data(malformed.utf8)
        #expect(try DAVXMLParser().parse(data: data).first?.etag == "deep")
        expectInvalidResponse(malformed, strictPropertyEvidence: true)
    }
}
