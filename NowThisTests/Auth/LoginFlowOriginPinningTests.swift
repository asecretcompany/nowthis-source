import Foundation
import Testing
@testable import NowThis

@Suite("Login Flow origin pinning")
struct LoginFlowOriginPinningTests {
    private func fixture(poll: String? = nil, login: String? = nil, token: String = "secret",
                         server: String? = nil, status: Int = 200,
                         basePath: String = "") -> (LoginFlowClient, String, String) {
        let host = "login-\(UUID().uuidString.lowercased()).invalid"
        let base = "https://\(host)\(basePath)"
        return (client(host: host, base: base, poll: poll, login: login, token: token,
                       server: server, status: status), base, host)
    }

    private func client(host: String, base: String, poll: String? = nil, login: String? = nil,
                        token: String = "secret", server: String? = nil, status: Int = 200) -> LoginFlowClient {
        let initiation: [String: Any] = [
            "poll": ["token": token, "endpoint": poll ?? "\(base)/poll"],
            "login": login ?? "\(base)/browser"
        ]
        let result = ["server": server ?? base, "loginName": "alice", "appPassword": "app-secret"]
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 200, body: String(data: try! JSONSerialization.data(withJSONObject: initiation), encoding: .utf8)!),
            .init(status: status, body: String(data: try! JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
        ])
        return LoginFlowClient(configuration: config)
    }

    @Test("Login initiation rejects oversized bodies before decoding", arguments: [false, true])
    func oversizedInitiation(declared: Bool) async throws {
        let host = "login-limit-\(UUID().uuidString.lowercased()).invalid"
        let size = 1_048_577
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 200, body: String(repeating: "x", count: size),
                  headers: declared ? ["Content-Length": "\(size)"] : [:])
        ])
        do {
            _ = try await LoginFlowClient(configuration: config).initiate(serverURL: "https://\(host)")
            Issue.record("Accepted oversized initiation")
        } catch let error as DAVResponseLimitError {
            #expect(error.limit == 1_048_576)
        } catch {
            Issue.record("Expected size rejection before JSON decoding: \(error)")
        }
    }

    @Test("Login polling bounds granted, pending and rejected replies", arguments: [200, 404, 500], [false, true])
    func oversizedPolling(status: Int, declared: Bool) async throws {
        let host = "poll-limit-\(UUID().uuidString.lowercased()).invalid"
        let base = "https://\(host)"
        let size = 1_048_577
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: status, body: String(repeating: "x", count: size),
                  headers: declared ? ["Content-Length": "\(size)"] : [:])
        ])
        let client = LoginFlowClient(configuration: config)
        let session = LoginFlowClient.LoginFlowSession(pollToken: "secret",
            pollEndpoint: URL(string: "\(base)/poll")!, loginURL: URL(string: "\(base)/browser")!,
            serverBaseURL: URL(string: base)!)
        do {
            _ = try await client.poll(session: session)
            Issue.record("Accepted oversized poll reply")
        } catch let error as DAVResponseLimitError {
            #expect(error.limit == 1_048_576)
        } catch {
            Issue.record("Expected size rejection before poll status/JSON handling: \(error)")
        }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test("A limit-sized valid login response succeeds after overflow on the same client")
    func responseBoundaryAndReuse() async throws {
        let host = "login-boundary-\(UUID().uuidString.lowercased()).invalid"
        let base = "https://\(host)"
        let json = "{\"poll\":{\"token\":\"secret\",\"endpoint\":\"\(base)/poll\"},\"login\":\"\(base)/browser\"}"
        let exact = json + String(repeating: " ", count: 1_048_576 - json.utf8.count)
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 200, body: String(repeating: "x", count: 1_048_577)),
            .init(status: 200, body: exact, headers: ["Content-Length": "1048576"]),
            .init(status: 404, body: "pending"),
            .init(status: 200, body: "{\"server\":\"\(base)\",\"loginName\":\"alice\",\"appPassword\":\"secret\"}")
        ])
        let client = LoginFlowClient(configuration: config)
        await #expect(throws: DAVResponseLimitError.self) {
            try await client.initiate(serverURL: base)
        }
        let session = try await client.initiate(serverURL: base)
        #expect(session.pollToken == "secret")
        let result = try await client.poll(session: session)
        #expect(result.loginName == "alice")
        #expect(ScriptedDAVProtocol.requests(host: host).count == 4)
    }

    @Test("Injected login cap bounds both phases", arguments: [false, true], [200, 404, 500])
    func injectedLoginLimit(declared: Bool, status: Int) async throws {
        let host = "tiny-login-\(UUID().uuidString.lowercased()).invalid"
        let base = "https://\(host)"
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: status, body: String(repeating: "x", count: 1025),
                  headers: declared ? ["Content-Length": "1025"] : [:]),
            .init(status: status, body: String(repeating: "x", count: 1025),
                  headers: declared ? ["Content-Length": "1025"] : [:])
        ])
        let client = LoginFlowClient(configuration: config, maxResponseBytes: 1024)
        await #expect(throws: DAVResponseLimitError.self) {
            try await client.initiate(serverURL: base)
        }
        let session = LoginFlowClient.LoginFlowSession(pollToken: "secret",
            pollEndpoint: URL(string: "\(base)/poll")!, loginURL: URL(string: "\(base)/browser")!,
            serverBaseURL: URL(string: base)!)
        await #expect(throws: DAVResponseLimitError.self) {
            try await client.poll(session: session)
        }
    }

    @Test("Cancelling a bounded login request leaves its session reusable")
    func boundedLoginCancellation() async throws {
        let host = "cancel-login-\(UUID().uuidString.lowercased()).invalid"
        let base = "https://\(host)"
        let gate = ScriptedDAVProtocol.Gate()
        defer { gate.release() }
        let json = "{\"poll\":{\"token\":\"secret\",\"endpoint\":\"\(base)/poll\"},\"login\":\"\(base)/browser\"}"
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 200, body: json, gate: gate), .init(status: 200, body: json)
        ])
        let client = LoginFlowClient(configuration: config, maxResponseBytes: 1024)
        let operation = Task { try await client.initiate(serverURL: base) }
        for _ in 0..<100 where ScriptedDAVProtocol.requests(host: host).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(try await client.initiate(serverURL: base).pollToken == "secret")
    }

    @Test("Hostile poll URLs are rejected before token transmission", arguments: [
        "https://evil.invalid/poll", "http://evil.invalid/poll",
        "https://user:secret@evil.invalid/poll", "https://evil.invalid/poll?query=1",
        "https://evil.invalid/poll#fragment"
    ])
    func hostilePollEndpoint(endpoint: String) async throws {
        let (client, base, host) = fixture(poll: endpoint)
        do {
            _ = try await client.initiate(serverURL: base)
            Issue.record("Accepted hostile poll endpoint: \(endpoint)")
        } catch is LoginFlowError {}
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
    }

    @Test("Returned server cannot replace the entered origin", arguments: [
        "https://evil.invalid", "http://evil.invalid", "https://evil.invalid:444",
        "https://user:secret@evil.invalid", "https://evil.invalid?query=1", "https://evil.invalid#fragment"
    ])
    func hostileReturnedServer(server: String) async throws {
        let (client, base, _) = fixture(server: server)
        let session = try await client.initiate(serverURL: base)
        do {
            _ = try await client.poll(session: session)
            Issue.record("Accepted hostile returned server: \(server)")
        } catch is LoginFlowError {}
    }

    @Test("Same-host poll URL changes are rejected", arguments: ["downgrade", "port", "query", "fragment", "userinfo"])
    func sameHostPollURL(change: String) async throws {
        let host = "login-\(UUID().uuidString.lowercased()).invalid"
        let base = "https://\(host)"
        let endpoint = changedURL(base: base, host: host, change: change)
        let client = client(host: host, base: base, poll: endpoint)
        do {
            _ = try await client.initiate(serverURL: base)
            Issue.record("Accepted poll endpoint \(change)")
        } catch is LoginFlowError {}
    }

    @Test("Same-host result requires matching scheme, port and case-sensitive path", arguments: [
        "downgrade", "port", "path-case", "path-prefix", "query", "fragment", "userinfo"
    ])
    func sameHostMismatch(change: String) async throws {
        let host = "login-\(UUID().uuidString.lowercased()).invalid"
        let base = "https://\(host)/Nextcloud"
        let client = client(host: host, base: base, server: changedURL(base: base, host: host, change: change))
        let session = try await client.initiate(serverURL: base)
        do {
            _ = try await client.poll(session: session)
            Issue.record("Accepted returned server \(change)")
        } catch is LoginFlowError {}
    }

    private func changedURL(base: String, host: String, change: String) -> String {
        switch change {
        case "downgrade": return base.replacingOccurrences(of: "https:", with: "http:")
        case "port": return base.replacingOccurrences(of: host, with: "\(host):444")
        case "path-case": return "https://\(host)/nextcloud"
        case "path-prefix": return "https://\(host)"
        case "query": return "\(base)?query=1"
        case "fragment": return "\(base)#fragment"
        default: return base.replacingOccurrences(of: "https://", with: "https://user:secret@")
        }
    }

    @Test("Host and default port normalize while entered subdirectory is retained")
    func sameOriginSuccess() async throws {
        let host = "login-\(UUID().uuidString.lowercased()).invalid"
        let base = "https://\(host)/Nextcloud"
        let client = client(host: host, base: base, poll: "https://\(host):443/Nextcloud/poll",
                            login: "https://sso.invalid/login?redirect=nextcloud#step",
                            server: "HTTPS://\(host.uppercased()):443/Nextcloud/")
        let session = try await client.initiate(serverURL: "\(base)///")
        #expect(session.loginURL.absoluteString == "https://sso.invalid/login?redirect=nextcloud#step")
        let result = try await client.poll(session: session)
        #expect(result.server == base)
        #expect(result.loginName == "alice")
        #expect(result.appPassword == "app-secret")
        #expect(ScriptedDAVProtocol.requests(host: host).first?.path == "/Nextcloud/index.php/login/v2")
    }

    @Test("Poll token form encoding preserves special characters")
    func tokenEncoding() async throws {
        let (client, base, host) = fixture(token: "a+b&c=d café")
        let session = try await client.initiate(serverURL: base)
        _ = try await client.poll(session: session)
        let body = try #require(ScriptedDAVProtocol.requests(host: host).last?.body)
        #expect(String(decoding: body, as: UTF8.self) == "token=a%2Bb%26c%3Dd%20caf%C3%A9")
    }

    @Test("Only 404 is a pending grant status", arguments: [401, 403, 500, 302])
    func rejectedPollStatus(status: Int) async throws {
        let (client, base, _) = fixture(status: status)
        let session = try await client.initiate(serverURL: base)
        do {
            _ = try await client.poll(session: session)
            Issue.record("Unexpected poll success")
        } catch let error as LoginFlowError {
            if case .serverRejected = error {} else { Issue.record("Wrong poll error: \(error)") }
        } catch { Issue.record("Continued polling after rejected status: \(error)") }
    }

    @Test("Browser URL must use HTTPS without userinfo", arguments: [
        "http://sso.invalid/login", "javascript:alert(1)", "https://user:secret@sso.invalid/login"
    ])
    func unsafeBrowserURL(login: String) async throws {
        let (client, base, _) = fixture(login: login)
        do {
            _ = try await client.initiate(serverURL: base)
            Issue.record("Accepted unsafe browser URL")
        } catch is LoginFlowError {}
    }

    @Test("Redirect delegate blocks cross-origin POST bodies", arguments: [
        "https://evil.invalid/poll", "http://login.invalid/poll", "https://login.invalid:444/poll",
        "https://user:secret@login.invalid/poll", "https://login.invalid/poll?query=1", "https://login.invalid/poll#fragment"
    ])
    func blockedRedirect(destination: String) async {
        let redirected = await redirect(to: destination)
        #expect(redirected == nil, "Redirect forwarded the secret token")
    }

    @Test("Redirect delegate follows same HTTPS origin including default port")
    func allowedRedirect() async throws {
        let redirected = try #require(await redirect(to: "HTTPS://LOGIN.invalid:443/next/poll"))
        #expect(redirected.httpMethod == "POST")
        #expect(redirected.httpBody == Data("token=secret".utf8))
    }

    private func redirect(to destination: String) async -> URLRequest? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var original = URLRequest(url: URL(string: "https://login.invalid/poll")!)
        original.httpMethod = "POST"
        original.httpBody = Data("token=secret".utf8)
        let task = session.dataTask(with: original)
        var proposed = original
        proposed.url = URL(string: destination)!
        let response = HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: nil)!
        return await withCheckedContinuation { continuation in
            LoginFlowRedirectDelegate().urlSession(session, task: task,
                willPerformHTTPRedirection: response, newRequest: proposed) { request in
                continuation.resume(returning: request)
            }
        }
    }
    @Test(arguments: [false, true])
    func blockedTransportRedirectHasAddressGuidance(polling: Bool) async throws {
        let host = "login-vpn-" + UUID().uuidString.lowercased() + ".invalid"
        let target = "internal-" + UUID().uuidString.lowercased() + ".invalid"
        let base = "https://\(host)"
        _ = ScriptedDAVProtocol.install(host: target, responses: [.init(body: "")])
        let config = ScriptedDAVProtocol.install(host: host, responses: [
            .init(status: 307, body: "", redirectURL: URL(string: "https://\(target)/poll"))
        ])
        let client = LoginFlowClient(configuration: config)
        do {
            if polling {
                _ = try await client.poll(session: .init(pollToken: "secret", pollEndpoint: URL(string: base + "/poll")!,
                    loginURL: URL(string: base + "/browser")!, serverBaseURL: URL(string: base)!))
            } else { _ = try await client.initiate(serverURL: base) }
            Issue.record("Cross-origin login redirect accepted")
        } catch let error as LoginFlowError {
            guard case .untrustedEndpoint = error else { Issue.record("Wrong login error: \(error)"); return }
        } catch { Issue.record("Expected address guidance, received \(error)") }
        #expect(ScriptedDAVProtocol.requests(host: host).count == 1)
        #expect(ScriptedDAVProtocol.requests(host: target).isEmpty)
    }

}
