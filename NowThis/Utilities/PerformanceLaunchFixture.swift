import Foundation
import SwiftData
#if NOWTHIS_PERFORMANCE_FIXTURES && targetEnvironment(simulator)
import AuthenticationServices
import Security
import SwiftUI
import Synchronization
import UIKit
#endif

/// Opens a deterministic, app-local store for Release UI performance journeys.
/// The app calls this before opening its regular store; a `nil` result keeps the
/// existing store path unchanged.
@MainActor
enum PerformanceLaunchFixture {
    private static let taskCountArgument = "-performance-task-count"
    private static let listCountArgument = "-performance-list-count"
    private static let resetArgument = "-performance-fixture-reset"
    private static let missingCredentialsArgument = "-performance-missing-credentials"

    static var isEnabled: Bool {
        #if NOWTHIS_PERFORMANCE_FIXTURES
        ProcessInfo.processInfo.arguments.contains(taskCountArgument)
        #else
        false
        #endif
    }

    private static var loginIsEnabled: Bool {
        #if NOWTHIS_PERFORMANCE_FIXTURES && targetEnvironment(simulator)
        isEnabled && ProcessInfo.processInfo.arguments.contains("-performance-login-fixture")
        #else
        false
        #endif
    }

    static var calendarProbeRun: String? {
        #if NOWTHIS_PERFORMANCE_FIXTURES && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        guard isEnabled, let index = arguments.firstIndex(of: "-performance-calendar-probe"),
              arguments.indices.contains(index + 1), UUID(uuidString: arguments[index + 1]) != nil else { return nil }
        return arguments[index + 1]
        #else
        return nil
        #endif
    }

    #if NOWTHIS_PERFORMANCE_FIXTURES && targetEnvironment(simulator)
    static func calendarProbeManager(run: String) -> AppleCalendarSyncManager {
        AppleCalendarSyncManager(store: EventKitCalendarStore(localSourceOnly: true), makeJournal: { container in
            AppleCalendarOwnershipJournal(container: container, selector: "calendar-probe/" + run)
        })
    }
    #endif

    static func makeLoginCoordinator() -> LoginFlowCoordinator {
        #if NOWTHIS_PERFORMANCE_FIXTURES && targetEnvironment(simulator)
        if loginIsEnabled {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PerformanceLoginProtocol.self]
            return LoginFlowCoordinator(
                client: LoginFlowClient(configuration: configuration),
                makeBrowser: { url, coordinator, completion in
                    PerformanceLoginBrowser(loginURL: url, window: coordinator.presentationWindow(), completion: completion)
                })
        }
        #endif
        return LoginFlowCoordinator()
    }

    static func loginAccountManager(in context: ModelContext) -> AccountManager {
        #if NOWTHIS_PERFORMANCE_FIXTURES && targetEnvironment(simulator)
        if loginIsEnabled {
            return AccountManager(modelContext: context, keychainManager: PerformanceLoginCredentials.keychain)
        }
        #endif
        return AccountManager(modelContext: context)
    }

    static func syncCommands(_ commands: SyncCommands) -> SyncCommands {
        guard loginIsEnabled else { return commands }
        var commands = commands
        commands.syncAfterAccountAdded = { _ in }
        return commands
    }

    static func openIfRequested() throws -> ModelContainer? {
        #if NOWTHIS_PERFORMANCE_FIXTURES
        guard isEnabled else { return nil }
        return try openFixtureStore()
        #else
        return nil
        #endif
    }

    #if NOWTHIS_PERFORMANCE_FIXTURES
    private static func openFixtureStore() throws -> ModelContainer {
        let arguments = ProcessInfo.processInfo.arguments
        let taskCount = try integerArgument(taskCountArgument, in: arguments, default: 10_000)
        let listCount = try integerArgument(listCountArgument, in: arguments, default: 100)
        let missingCredentials = arguments.contains(missingCredentialsArgument)
        let moveHolds = arguments.contains("-performance-move-holds")
        let filterRepair = arguments.contains("-performance-filter-repair-fixture")
        let sectionedSearch = arguments.contains("-performance-sectioned-search-fixture")
        let readOnlyTask = arguments.contains("-performance-read-only-task-fixture")
        guard (1...50_000).contains(taskCount), (1...100).contains(listCount) else {
            throw FixtureError.invalidCounts(taskCount: taskCount, listCount: listCount)
        }

        let fileManager = FileManager.default
        let documentsURL = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let profile = "PerformanceFixture-\(taskCount)-\(listCount)"
            + (missingCredentials ? "-missing-credentials" : "")
            + (moveHolds ? "-move-holds" : "")
            + (loginIsEnabled ? "-login" : "")
            + (calendarProbeRun.map { "-calendar-" + $0 } ?? "")
            + (arguments.contains("-performance-calendar-draft-fixture") ? "-calendar-draft" : "")
            + (filterRepair ? "-filter-repair" : "")
            + (sectionedSearch ? "-sectioned-search" : "")
            + (readOnlyTask ? "-read-only-task" : "")
        let profileDirectory = documentsURL.appendingPathComponent(profile, isDirectory: true)
        let storeURL = profileDirectory.appendingPathComponent("Performance.store")
        let seedMarkerURL = profileDirectory.appendingPathComponent("seed-complete")

        if arguments.contains(resetArgument) {
            try removeItemIfExists(profileDirectory, using: fileManager)
        } else if fileManager.fileExists(atPath: storeURL.path),
                  !fileManager.fileExists(atPath: seedMarkerURL.path) {
            // Recover cleanly from an interrupted first seed.
            try removeItemIfExists(profileDirectory, using: fileManager)
        }
        try fileManager.createDirectory(
            at: profileDirectory,
            withIntermediateDirectories: true
        )

        let schema = Schema(SchemaV2.models)
        let configuration = ModelConfiguration(
            "PerformanceFixture",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])

        if !fileManager.fileExists(atPath: seedMarkerURL.path) {
            try seed(container: container, taskCount: taskCount, listCount: listCount)
            if missingCredentials {
                let context = container.mainContext
                context.insert(ServerAccount(displayName: "Fixture Nextcloud", serverBaseURL: "https://fixture.invalid", username: "fixture"))
                try context.save()
            }
            if moveHolds { try seedMoveHolds(container: container) }
            if filterRepair { try seedFilterRepair(in: container.mainContext) }
            if sectionedSearch { try seedSectionedSearch(in: container.mainContext) }
            if readOnlyTask { try seedReadOnlyTask(in: container.mainContext) }
            try Data("ready".utf8).write(to: seedMarkerURL, options: .atomic)
        }
        return container
    }

    private static func seedReadOnlyTask(in context: ModelContext) throws {
        let account = ServerAccount(id: "performance-read-only-account", displayName: "Fixture shared account",
                                    serverBaseURL: "https://fixture-read-only.invalid", username: "fixture")
        let list = TaskList(id: "performance-read-only-list", serverURL: "/dav/calendars/fixture/shared/",
                            name: "Fixture read-only list", colorHex: "#007AFF")
        list.account = account
        list.isReadOnly = true
        let task = TaskItem(id: "performance-read-only-task", title: "Read-only due-date target")
        task.taskList = list
        task.isLocalOnly = false
        context.insert(account)
        context.insert(list)
        context.insert(task)
        try context.save()
    }

    private static func seedFilterRepair(in context: ModelContext) throws {
        let list = try context.fetch(FetchDescriptor<TaskList>()).first
        let calendar = Calendar.current
        let now = Date()
        let high = TaskItem(title: "Filter expected priority")
        high.priority = .high
        high.dueDate = calendar.date(byAdding: .day, value: 5, to: now)
        let past = TaskItem(title: "Filter unrelated past")
        past.priority = .low
        past.dueDate = calendar.date(byAdding: .day, value: -5, to: now)
        let undated = TaskItem(title: "Filter unrelated undated")
        undated.priority = .low
        for task in [high, past, undated] {
            task.taskList = list
            context.insert(task)
        }
        let corrupt = SavedFilter(id: "filter-corrupt", name: "Legacy damaged filter", sortOrder: 1)
        corrupt.rulesData = Data("{broken".utf8)
        context.insert(corrupt)
        context.insert(SavedFilter(id: "filter-invalid-or", name: "Legacy invalid OR", sortOrder: 2, rules: [
            FilterRule(field: .priority, comparison: .equals, value: "high"),
            FilterRule(field: .hasDueDate, comparison: .equals, value: "maybe")
        ], logicOperator: .or))
        context.insert(SavedFilter(id: "filter-editable", name: "Existing editable filter", sortOrder: 3, rules: [
            FilterRule(field: .priority, comparison: .equals, value: "Low")
        ]))
        try context.save()
    }

    private static func seedSectionedSearch(in context: ModelContext) throws {
        let list = try context.fetch(FetchDescriptor<TaskList>()).first
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
        let tag = Tag(name: "Quasar")
        context.insert(tag)
        for (title, days, usesTag, status) in [
            ("Search location future", 5, false, TaskStatus.needsAction),
            ("Search location past", -5, false, .needsAction),
            ("Search tag future", 5, true, .needsAction),
            ("Search tag past", -5, true, .needsAction),
            ("Search completed control", 6, true, .completed),
            ("Search distant control", 40, false, .needsAction),
        ] {
            let task = TaskItem(title: title)
            task.taskList = list
            task.dueDate = calendar.date(byAdding: .day, value: days, to: now)
            task.status = status
            if usesTag {
                task.tags = [tag]
            } else {
                task.locationName = "Café annex"
            }
            context.insert(task)
        }
        try context.save()
    }

    /// Credential-free account IDs are fresh for this isolated fixture profile.
    private static func seedMoveHolds(container: ModelContainer) throws {
        let context = container.mainContext
        let account = ServerAccount(displayName: "Move Fixture Server", serverBaseURL: "https://move-fixture.invalid", username: "fixture")
        let list = TaskList(serverURL: "/one/", name: "Move Fixture Source", colorHex: "#007AFF")
        context.insert(account); context.insert(list); list.account = account
        for unsupported in [false, true] {
            let uid = unsupported ? "unsupported" : "missing"
            let task = TaskItem(uid: uid, title: unsupported ? "Fixture unsupported proof" : "Fixture missing proof")
            context.insert(task); task.taskList = list
            task.remoteHref = "/one/" + uid + ".ics"; task.etag = "e1"
            task.isLocalOnly = false; task.isDirty = unsupported; task.attachmentStateKnown = true
            task.dueDate = Calendar.current.startOfDay(for: Date()); task.isDueDateOnly = true
            try VTODOOpaqueState.empty.store(taskID: task.id, in: context)
            if unsupported {
                let body = "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VTODO\nUID:unsupported\nSUMMARY:Master\nRRULE:FREQ=DAILY\nEND:VTODO\nBEGIN:VTODO\nUID:unsupported\nRECURRENCE-ID:20261111T120000Z\nSUMMARY:Exception\nEND:VTODO\nEND:VCALENDAR"
                let parsed = try SyncBodyValidation.parse(.init(href: task.remoteHref!, etag: "e1", icsData: body), using: .init())
                guard let scope = TaskPhotoOwnership.Scope(list: list) else { throw CalDAVError.invalidResponse }
                try SyncResourceState.observe(parsed, scope: scope, in: context)
            }
        }
        try context.save()
    }

    private static func removeItemIfExists(_ url: URL, using fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private static func integerArgument(
        _ name: String,
        in arguments: [String],
        default defaultValue: Int
    ) throws -> Int {
        guard let position = arguments.firstIndex(of: name) else { return defaultValue }
        guard arguments.indices.contains(position + 1),
              let value = Int(arguments[position + 1]) else {
            throw FixtureError.invalidArgument(name)
        }
        return value
    }

    private static func seed(
        container: ModelContainer,
        taskCount: Int,
        listCount: Int
    ) throws {
        let context = ModelContext(container)
        let account = ServerAccount(vaultDisplayName: "Performance Vault")
        context.insert(account)

        var lists: [TaskList] = []
        lists.reserveCapacity(listCount)
        for index in 0..<listCount {
            let list = TaskList(
                id: "performance-fixture-list-\(index)",
                serverURL: "nowthis://performance-fixture/\(index)",
                name: String(format: "Fixture list %03d", index),
                colorHex: "#007AFF"
            )
            list.account = account
            context.insert(list)
            lists.append(list)
        }

        let today = Calendar.current.startOfDay(for: Date())
        let statuses: [TaskStatus] = [.needsAction, .inProcess, .completed]
        let priorities: [TaskPriority] = [.high, .medium, .low, .none]
        for index in 0..<taskCount {
            let task = TaskItem(
                id: String(format: "performance-fixture-task-%08d", index),
                uid: "performance-fixture-uid-\(index)",
                title: String(format: "Fixture task %05d", index)
            )
            task.taskList = lists[index % listCount]
            task.createdDate = today
            task.lastModifiedDate = today
            task.status = statuses[index % statuses.count]
            task.priority = priorities[(index / 2) % priorities.count]
            if index.isMultiple(of: 2) {
                task.dueDate = Calendar.current.date(byAdding: .hour, value: 12, to: today)
            } else {
                let daysAhead = 1 + ((index / 2) % 7)
                task.dueDate = Calendar.current.date(byAdding: .day, value: daysAhead, to: today)
            }
            task.isDueDateOnly = true
            if task.status == .completed {
                task.percentComplete = 100
                task.completedDate = today
            }
            context.insert(task)

            if (index + 1).isMultiple(of: 1_000) {
                try context.save()
            }
        }

        let journal = JournalEntry(
            id: "performance-fixture-journal-00000",
            uid: "performance-fixture-journal-uid-00000",
            title: "Fixture journal 00000",
            content: "Deterministic performance fixture journal entry."
        )
        journal.taskList = lists[0]
        context.insert(journal)
        try context.save()
    }

    private enum FixtureError: Error {
        case invalidArgument(String)
        case invalidCounts(taskCount: Int, listCount: Int)
    }

    #endif
}

#if NOWTHIS_PERFORMANCE_FIXTURES && targetEnvironment(simulator)
private enum PerformanceLoginCredentials {
    private static let values = Mutex([String: Data]())

    static let keychain = KeychainManager(operations: .init(
        add: { query in
            guard let id = accountID(query), let value = (query as NSDictionary)[kSecValueData] as? Data
            else { return errSecParam }
            return values.withLock {
                guard $0[id] == nil else { return errSecDuplicateItem }
                $0[id] = value
                return errSecSuccess
            }
        },
        update: { query, attributes in
            guard let id = accountID(query), let value = (attributes as NSDictionary)[kSecValueData] as? Data
            else { return errSecParam }
            return values.withLock {
                guard $0[id] != nil else { return errSecItemNotFound }
                $0[id] = value
                return errSecSuccess
            }
        },
        copyMatching: { query in
            guard let id = accountID(query) else { return (errSecParam, nil) }
            return values.withLock {
                guard let value = $0[id] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, value as NSData)
            }
        },
        delete: { query in
            guard let id = accountID(query) else { return errSecParam }
            return values.withLock { $0.removeValue(forKey: id) == nil ? errSecItemNotFound : errSecSuccess }
        }))

    private static func accountID(_ query: CFDictionary) -> String? {
        (query as NSDictionary)[kSecAttrAccount] as? String
    }
}

private enum PerformanceLoginServer {
    static let baseURL = "https://login-fixture.invalid"

    private struct Attempt {
        let token = UUID().uuidString
        var granted = false
    }

    private struct State {
        var nextID = 0
        var attempts: [Int: Attempt] = [:]
    }

    private static let state = Mutex(State())

    static func initiate() -> [String: Any] {
        state.withLock {
            $0.nextID += 1
            let id = $0.nextID
            let attempt = Attempt()
            $0.attempts[id] = attempt
            return [
                "poll": ["token": attempt.token, "endpoint": baseURL + "/login/v2/poll"],
                "login": baseURL + "/browser/\(id)"
            ]
        }
    }

    static func grant(_ id: Int) {
        state.withLock { $0.attempts[id]?.granted = true }
    }

    static func cancel(_ id: Int) {
        _ = state.withLock { $0.attempts.removeValue(forKey: id) }
    }

    static func poll(token: String) -> [String: String]? {
        state.withLock {
            guard let (id, attempt) = $0.attempts.first(where: { $0.value.token == token }),
                  attempt.granted else { return nil }
            $0.attempts.removeValue(forKey: id)
            return ["server": baseURL, "loginName": "Login Fixture", "appPassword": UUID().uuidString]
        }
    }
}

/// Handles all requests in the fixture client so an unexpected address never
/// falls through to a network transport.
private final class PerformanceLoginProtocol: URLProtocol, @unchecked Sendable {
    private let operation = Mutex<Task<Void, Never>?>(nil)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, request.httpMethod == "POST",
              url.absoluteString == PerformanceLoginServer.baseURL + url.path else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch url.path {
        case "/index.php/login/v2":
            operation.withLock {
                $0 = Task { @Sendable [self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard !Task.isCancelled else { return }
                    reply(url: url, status: 200, json: PerformanceLoginServer.initiate())
                }
            }
        case "/login/v2/poll":
            guard let body = formBody(), body.hasPrefix("token=") else {
                reply(url: url, status: 400)
                return
            }
            let token = String(body.dropFirst("token=".count))
            if let result = PerformanceLoginServer.poll(token: token) {
                reply(url: url, status: 200, json: result)
            } else {
                reply(url: url, status: 404)
            }
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {
        operation.withLock {
            $0?.cancel()
            $0 = nil
        }
    }

    private func formBody() -> String? {
        if let body = request.httpBody {
            return body.count < 256 ? String(data: body, encoding: .utf8) : nil
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0, bytes.count + count < 256 else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return String(data: bytes, encoding: .utf8)
    }

    private func reply(url: URL, status: Int, json: [String: Any] = [:]) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]),
              let data = try? JSONSerialization.data(withJSONObject: json) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotDecodeContentData))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private final class PerformanceLoginBrowser: LoginBrowserSession {
    private let id: Int?
    private weak var window: UIWindow?
    private weak var modal: UIViewController?
    private let completion: LoginFlowCoordinator.BrowserCompletion

    init(loginURL: URL, window: UIWindow?, completion: @escaping LoginFlowCoordinator.BrowserCompletion) {
        id = Int(loginURL.lastPathComponent)
        self.window = window
        self.completion = completion
    }

    func start() -> Bool {
        guard let id, var presenter = window?.rootViewController else { return false }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else { return false }
        let view = PerformanceLoginBrowserView(cancel: { [weak self] in
            self?.returnToApp(cancelled: true)
        }, grant: {
            PerformanceLoginServer.grant(id)
        }, returnToApp: { [weak self] in
            self?.returnToApp(cancelled: false)
        })
        let controller = UIHostingController(rootView: view)
        controller.modalPresentationStyle = .overFullScreen
        controller.modalTransitionStyle = .crossDissolve
        controller.view.backgroundColor = .clear
        controller.view.accessibilityViewIsModal = true
        modal = controller
        presenter.present(controller, animated: true)
        return true
    }

    func cancel() {
        if let id { PerformanceLoginServer.cancel(id) }
        modal?.dismiss(animated: true)
        modal = nil
    }

    private func returnToApp(cancelled: Bool) {
        guard let modal else { return }
        self.modal = nil
        modal.dismiss(animated: true) { [completion] in
            if cancelled {
                completion(nil, ASWebAuthenticationSessionError(.canceledLogin))
            } else {
                completion(URL(string: LoginFlowCoordinator.callbackURLScheme + "://fixture"), nil)
            }
        }
    }
}

private struct PerformanceLoginBrowserView: View {
    let cancel: () -> Void
    let grant: () -> Void
    let returnToApp: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().accessibilityHidden(true)
            VStack(spacing: 16) {
                Text(verbatim: "Mock Nextcloud login")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Button(action: grant) { Text(verbatim: "Grant access") }
                    .buttonStyle(.borderedProminent)
                Button(action: returnToApp) { Text(verbatim: "Return to NowThis") }
                Button(action: cancel) { Text(verbatim: "Cancel") }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20))
            .padding(24)
        }
    }
}
#endif
