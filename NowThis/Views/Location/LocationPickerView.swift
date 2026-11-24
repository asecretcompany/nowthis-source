import SwiftUI
import MapKit
import SwiftData
import os

/// Location picker for setting a task's geofence location.
///
/// Provides a search field that geocodes addresses, a map preview
/// showing the pin and geofence radius, and a radius slider.
/// Used from TaskDetailView's DetailsSection.
struct LocationPickerView: View {

    let task: TaskItem
    let onSave: (LocationDraft.Fields) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var errorState = ErrorState()

    @State private var searchText: String
    @State private var searchResults: [MKMapItem] = []
    @State private var draft: LocationDraft
    @State private var cameraPosition: MapCameraPosition = .automatic

    init(task: TaskItem, draft: LocationDraft, onSave: @escaping (LocationDraft.Fields) -> Void) {
        self.task = task
        self.onSave = onSave
        _draft = State(initialValue: draft)
        _searchText = State(initialValue: draft.name ?? "")
        if let coordinate = draft.coordinate {
            _cameraPosition = State(initialValue: Self.camera(at: coordinate, radius: draft.radius))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                if let coordinate = draft.coordinate {
                    mapSection(coordinate)
                    radiusSection
                }
                if draft.hasLocation {
                    removeSection
                }
            }
            .environment(\.saveErrorState, errorState)
            .errorBanner(errorState)
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Search

    private var searchSection: some View {
        Section("Search Location") {
            TextField("Address or place name", text: $searchText)
                .textInputAutocapitalization(.words)
                .onSubmit { geocode() }
                .accessibilityLabel("Location search")

            if !searchResults.isEmpty {
                ForEach(searchResults, id: \.self) { item in
                    Button {
                        selectResult(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? String(localized: "location.result.unnamed", defaultValue: "Unnamed location", comment: "Name shown for a MapKit search result that has no name; copy changed from the previous Unknown since the location is not unknown, it is simply unnamed"))
                                .font(.subheadline)
                            if let address = item.placemark.formattedAddress {
                                Text(address)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    // MARK: - Map Preview

    private func mapSection(_ coordinate: CLLocationCoordinate2D) -> some View {
        Section("Preview") {
            Map(position: $cameraPosition) {
                Marker(draft.name ?? "Task", coordinate: coordinate)
                MapCircle(center: coordinate, radius: draft.radius)
                    .foregroundStyle(.blue.opacity(0.15))
                    .stroke(.blue, lineWidth: 1)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
    }

    // MARK: - Radius

    private var radiusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Geofence Radius", systemImage: "circle.dashed")
                    Spacer()
                    Text(Measurement(value: draft.radius, unit: UnitLength.meters),
                         format: .measurement(width: .narrow))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $draft.radius, in: LocationDraft.radiusRange, step: 25)
                    .accessibilityLabel("Geofence radius, \(Int(draft.radius)) meters")
            }
        }
    }

    // MARK: - Remove

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                clearLocation()
            } label: {
                Label("Remove Location", systemImage: "trash")
            }
        }
    }

    // MARK: - Actions

    private func geocode() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            searchResults = response?.mapItems ?? []
        }
    }

    private func selectResult(_ item: MKMapItem) {
        let coord = item.placemark.coordinate
        draft.select(name: item.name ?? searchText, latitude: coord.latitude, longitude: coord.longitude)
        searchResults = []
        searchText = item.name ?? ""
        cameraPosition = Self.camera(at: coord, radius: draft.radius)
    }

    private func clearLocation() {
        draft.clear()
        searchText = ""
        searchResults = []
        cameraPosition = .automatic
    }

    private func save() {
        guard draft.save(to: task, in: modelContext, errorState: errorState, onSave: onSave) else { return }
        dismiss()
    }

    private static func camera(at coordinate: CLLocationCoordinate2D, radius: Double) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: radius * 3,
                                   longitudinalMeters: radius * 3))
    }
}

@MainActor
struct LocationDraft {
    static let radiusRange = 50.0...1_000.0

    struct Fields: Equatable {
        var name: String?
        var latitude: Double?
        var longitude: Double?
        var radius: Double?

        init() {}

        init(_ task: TaskItem) {
            name = task.locationName
            latitude = task.latitude
            longitude = task.longitude
            radius = task.geofenceRadius
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.hasSamePlace(as: rhs) && lhs.radius?.bitPattern == rhs.radius?.bitPattern
        }

        func hasSamePlace(as other: Self) -> Bool {
            name == other.name && latitude?.bitPattern == other.latitude?.bitPattern
                && longitude?.bitPattern == other.longitude?.bitPattern
        }

        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
        }

        func applyChanges(from previous: Self, to task: TaskItem) {
            if name != previous.name { task.locationName = name }
            if latitude?.bitPattern != previous.latitude?.bitPattern { task.latitude = latitude }
            if longitude?.bitPattern != previous.longitude?.bitPattern { task.longitude = longitude }
            if radius?.bitPattern != previous.radius?.bitPattern { task.geofenceRadius = radius }
        }
    }

    private let original: Fields
    private var fields: Fields

    enum SaveFailure: Error { case taskUnavailable }

    var savedFields: Fields { original }
    var name: String? { fields.name }
    var hasLocation: Bool { fields != Fields() }
    var coordinate: CLLocationCoordinate2D? { fields.coordinate }

    var radius: Double {
        get {
            guard let radius = fields.radius, radius.isFinite, radius > 0 else {
                return GeofenceManager.defaultRadius
            }
            return min(Self.radiusRange.upperBound, max(Self.radiusRange.lowerBound, radius))
        }
        set { fields.radius = newValue }
    }

    private init(fields: Fields) {
        self.original = fields
        self.fields = fields
    }

    static func open(task: TaskItem, in context: ModelContext, errorState: ErrorState? = nil) -> Self? {
        do {
            return try Self(fields: committedFields(for: task, in: context))
        } catch {
            ViewPersistence.report(error, to: errorState)
            return nil
        }
    }

    private static func ownedContext(for context: ModelContext) -> ModelContext {
        let owned = ModelContext(context.container)
        owned.autosaveEnabled = false
        return owned
    }

    private static func resolve(_ task: TaskItem, from context: ModelContext, in owned: ModelContext) throws -> TaskItem {
        guard task.modelContext === context else { throw SaveFailure.taskUnavailable }
        let id = task.persistentModelID
        guard !context.deletedModelsArray.contains(where: { $0.persistentModelID == id }) else {
            throw SaveFailure.taskUnavailable
        }
        guard let stored = try savedTask(id, in: owned), !stored.isDeletedLocally else {
            throw SaveFailure.taskUnavailable
        }
        return stored
    }

    private static func savedTask(_ id: PersistentIdentifier, in context: ModelContext) throws -> TaskItem? {
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.includePendingChanges = false
        descriptor.fetchLimit = 1
        guard let stored = try context.fetch(descriptor).first, stored.persistentModelID == id else { return nil }
        return stored
    }

    static func committedFields(for task: TaskItem, in context: ModelContext) throws -> Fields {
        let owned = ownedContext(for: context)
        return try Fields(resolve(task, from: context, in: owned))
    }

    mutating func select(name: String, latitude: Double, longitude: Double) {
        fields.name = name
        fields.latitude = latitude
        fields.longitude = longitude
        let existingRadius = fields.radius ?? 0
        if !existingRadius.isFinite || existingRadius <= 0 {
            fields.radius = GeofenceManager.defaultRadius
        }
    }

    mutating func clear() { fields = Fields() }

    func save(to task: TaskItem, in context: ModelContext, errorState: ErrorState? = nil,
              save: (() throws -> Void)? = nil,
              onSave: (Fields) -> Void = { _ in },
              onLocationSaved: () -> Void = { GeofenceManager.shared.requestPermission() }) -> Bool {
        guard fields != original else { return true }
        do {
            let owned = Self.ownedContext(for: context)
            let stored = try Self.resolve(task, from: context, in: owned)
            if context.changedModelsArray.contains(where: { $0 === task }), task.isDeletedLocally {
                throw SaveFailure.taskUnavailable
            }
            let previous = Fields(stored)
            var updated = fields
            if fields.hasSamePlace(as: original) {
                // Moving only the slider must preserve a place updated while the sheet was open.
                updated = previous
                if previous.coordinate != nil { updated.radius = fields.radius }
            }
            guard previous != updated else {
                return true
            }
            let changesPlace = !updated.hasSamePlace(as: previous)
            if changesPlace {
                // The editor can hold a pending local change while the owned context
                // reads committed state. Check both owners before staging the location.
                _ = try TaskWriteEligibility(writingIn: context).task(.retained(task))
                _ = try TaskWriteEligibility(writingIn: owned).task(.retained(stored))
            }
            updated.applyChanges(from: previous, to: stored)
            if changesPlace {
                stored.isDirty = true
                stored.lastModifiedDate = Date()
            }
            let retainedStamp = SaveHandoff.Stamp(task)
            let committedStamp = SaveHandoff.Stamp(stored)
            guard ViewPersistence.saveOrReport(in: owned, errorState: errorState, save: save) else { return false }
            SaveHandoff.shared.track(task, committed: updated, retainedStamp: retainedStamp, committedStamp: committedStamp)
            onSave(updated)
            if updated.coordinate != nil { onLocationSaved() }
            return true
        } catch {
            ViewPersistence.reportTaskWriteRefusal(error, to: errorState)
            return false
        }
    }

    /// The picker writes in its own context. Rebase the retained editor only if
    /// it is actually being saved later, before SwiftData captures its row.
    @MainActor
    private final class SaveHandoff {
        static let shared = SaveHandoff()

        struct Stamp: Equatable {
            let isDirty: Bool
            let modifiedAt: Date?

            init(_ task: TaskItem) {
                isDirty = task.isDirty
                modifiedAt = task.lastModifiedDate
            }

            func apply(to task: TaskItem) {
                if task.isDirty != isDirty { task.isDirty = isDirty }
                if task.lastModifiedDate != modifiedAt { task.lastModifiedDate = modifiedAt }
            }
        }

        private final class Entry {
            weak var task: TaskItem?
            weak var context: ModelContext?
            var committed: Fields
            var retainedStamp: Stamp
            var committedStamp: Stamp
            var retainedETag: String?

            init(task: TaskItem, context: ModelContext, committed: Fields, retainedStamp: Stamp, committedStamp: Stamp) {
                self.task = task
                self.context = context
                self.committed = committed
                self.retainedStamp = retainedStamp
                self.committedStamp = committedStamp
                retainedETag = task.etag
            }
        }

        private var entries: [ObjectIdentifier: Entry] = [:]
        private var observers: [ObjectIdentifier: ContextObservation] = [:]
        private let logger = Logger(subsystem: "com.nowthis", category: "location-save")

        private struct ContextObservation {
            let willSave: any NSObjectProtocol
            let didSave: any NSObjectProtocol

            func remove() {
                NotificationCenter.default.removeObserver(willSave)
                NotificationCenter.default.removeObserver(didSave)
            }
        }

        func track(_ task: TaskItem, committed: Fields, retainedStamp: Stamp, committedStamp: Stamp) {
            guard let context = task.modelContext else { return }
            prune()
            entries[ObjectIdentifier(task)] = Entry(task: task, context: context, committed: committed,
                                                    retainedStamp: retainedStamp, committedStamp: committedStamp)
            let contextID = ObjectIdentifier(context)
            guard observers[contextID] == nil else { return }
            let willSave = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) { [weak self] _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.rebase(in: contextID) }
            }
            let didSave = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { [weak self] note in
                guard Thread.isMainThread,
                      let updated = note.userInfo?[ModelContext.NotificationKey.updatedIdentifiers.rawValue] as? [PersistentIdentifier],
                      !updated.isEmpty else { return }
                MainActor.assumeIsolated { self?.recordCommittedStamps(in: contextID, updated: Set(updated)) }
            }
            observers[contextID] = ContextObservation(willSave: willSave, didSave: didSave)
        }

        private func rebase(in contextID: ObjectIdentifier) {
            prune()
            guard let context = entries.values.lazy.compactMap(\.context)
                .first(where: { ObjectIdentifier($0) == contextID }) else { return }
            let pending = context.changedModelsArray.compactMap { $0 as? TaskItem }
                .filter { entries[ObjectIdentifier($0)]?.task === $0 }
            guard !pending.isEmpty else { return }
            let reader = LocationDraft.ownedContext(for: context)
            let deleted = Set(context.deletedModelsArray.map(\.persistentModelID))
            for task in pending {
                let key = ObjectIdentifier(task)
                guard let entry = entries[key], task.modelContext === context else { continue }
                if deleted.contains(task.persistentModelID) {
                    entries.removeValue(forKey: key)
                    continue
                }
                do {
                    guard let stored = try LocationDraft.savedTask(task.persistentModelID, in: reader) else {
                        entries.removeValue(forKey: key)
                        continue
                    }
                    entry.committed = Fields(stored)
                    entry.committedStamp = Stamp(stored)
                    // The accepted revision belongs to this exact server resource.
                    if task.etag == entry.retainedETag, task.uid == stored.uid,
                       let href = task.remoteHref, !href.isEmpty, href == stored.remoteHref,
                       let scope = TaskPhotoOwnership.Scope(list: task.taskList), scope.matches(stored.taskList),
                       task.etag != stored.etag {
                        task.etag = stored.etag
                        entry.retainedETag = stored.etag
                    }
                } catch {
                    // SwiftData has already begun saving. Use the last committed
                    // value we could verify, and try the fresh read on the next save.
                    logger.error("Could not refresh the committed location before saving: \(String(describing: error), privacy: .private)")
                }
                entry.committed.applyChanges(from: Fields(task), to: task)
                let pendingStamp = Stamp(task)
                // An unchanged stamp is only the editor's stale copy. A newer
                // intentional edit owns its own stamp and dirty state.
                if pendingStamp == entry.retainedStamp {
                    entry.committedStamp.apply(to: task)
                    entry.retainedStamp = entry.committedStamp
                }
            }
        }

        private func recordCommittedStamps(in contextID: ObjectIdentifier, updated: Set<PersistentIdentifier>) {
            for entry in entries.values {
                guard let task = entry.task, let context = entry.context, ObjectIdentifier(context) == contextID,
                      updated.contains(task.persistentModelID), task.modelContext === context else { continue }
                entry.retainedStamp = Stamp(task)
                entry.retainedETag = task.etag
            }
        }

        private func prune() {
            entries = entries.filter { $0.value.task != nil && $0.value.context != nil }
            let trackedContexts = Set(entries.values.compactMap { $0.context.map(ObjectIdentifier.init) })
            for id in Array(observers.keys) where !trackedContexts.contains(id) {
                observers.removeValue(forKey: id)?.remove()
            }
        }
    }
}

// MARK: - Placemark Helpers

private extension CLPlacemark {
    var formattedAddress: String? {
        let parts = [subThoroughfare, thoroughfare, locality, administrativeArea].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
