import SwiftUI
import SwiftData
import UIKit
import Testing
@testable import NowThis

@MainActor
private final class RefreshProofControl: ObservableObject {
    @Published var revision: UInt64 = 0
    var values: [String: String] = [:]
    var identities: [UUID] = []
    var states: [[String]] = []
}

private struct RefreshProofHost: View {
    @ObservedObject var control: RefreshProofControl
    @State private var tasks: [TaskItem] = []
    @State private var identity = UUID()
    @State private var search = "Dragon"
    @State private var expanded = "parent"
    @State private var editor = "draft"
    @State private var anchor = "middle"

    var body: some View {
        Text(verbatim: "Query proof")
            .background(CommittedQueryReader(descriptor: FetchDescriptor<TaskItem>(), revision: control.revision) { rows in
                tasks = rows
                control.values = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.title) })
                control.identities.append(identity)
                control.states.append([search, expanded, editor, anchor])
            })
    }
}

@Suite("Stable inbound query hosting", .serialized)
@MainActor
struct InboundRefreshStateTests {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "Query reader did not deliver the committed snapshot")
    }

    @Test("Background inserts, updates and deletes refresh values without replacing host state")
    func committedDataKeepsHostState() async throws {
        let container = try DAVSyncScenario.container()
        let main = container.mainContext
        let original = TaskItem(id: "original", title: "Before")
        let remove = TaskItem(id: "remove", title: "Remove")
        main.insert(original); main.insert(remove); try main.save()
        let control = RefreshProofControl()
        let controller = UIHostingController(rootView: RefreshProofHost(control: control).modelContainer(container))
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { control.values["original"] == "Before" }
        let firstIdentity = try #require(control.identities.first)
        let background = ModelContext(container)
        let saved = try background.fetch(FetchDescriptor<TaskItem>())
        saved.first { $0.id == "original" }?.title = "Server updated"
        if let row = saved.first(where: { $0.id == "remove" }) { background.delete(row) }
        background.insert(TaskItem(id: "new", title: "New")); try background.save()
        control.revision += 1
        try await waitUntil { control.values == ["original": "Server updated", "new": "New"] }
        #expect(control.identities.allSatisfy { $0 == firstIdentity })
        #expect(control.states.allSatisfy { $0 == ["Dragon", "parent", "draft", "middle"] })
        // Pending local edits and inserts remain authoritative while unrelated remote work arrives.
        original.title = "Local unsaved"
        main.insert(TaskItem(id: "pending", title: "Pending"))
        background.insert(TaskItem(id: "unrelated", title: "Unrelated")); try background.save()
        control.revision += 1
        try await waitUntil { control.values["pending"] == "Pending" && control.values["original"] == "Local unsaved" }
        #expect(main.hasChanges)
        withExtendedLifetime(container) {}
    }
}
