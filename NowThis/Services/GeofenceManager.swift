@preconcurrency import CoreLocation
import UserNotifications
import UIKit
import SwiftData
import os

@MainActor
protocol GeofenceMonitoring: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var monitoredRegions: Set<CLRegion> { get }
    var maximumRegionMonitoringDistance: CLLocationDistance { get }
    var circularMonitoringAvailable: Bool { get }
    func requestWhenInUseAuthorization()
    func startMonitoring(for region: CLRegion)
    func stopMonitoring(for region: CLRegion)
}

extension CLLocationManager: GeofenceMonitoring {
    var circularMonitoringAvailable: Bool {
        CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }
}

/// Owns Core Location registration for the app and reads reminder locations from the saved store.
@MainActor
final class GeofenceManager: NSObject, ObservableObject {
    static let shared = GeofenceManager(locationManager: CLLocationManager())
    static let defaultRadius: Double = 100
    private static let maxRegions = 20

    enum Issue: Equatable {
        case denied
        case restricted
        case unavailable
        case updateFailed

        var message: LocalizedStringResource {
            switch self {
            case .denied:
                LocalizedStringResource("location.reminders.denied",
                       defaultValue: "Allow location access for NowThis in Settings to receive location reminders.",
                       comment: "Shown when the user has denied location access for task reminders. Settings is the Apple app.")
            case .restricted:
                LocalizedStringResource("location.reminders.restricted",
                       defaultValue: "Location access is restricted on this device.",
                       comment: "Shown when system restrictions block location access for task reminders.")
            case .unavailable:
                LocalizedStringResource("location.reminders.unavailable",
                       defaultValue: "Location reminders are unavailable on this device.",
                       comment: "Shown when the device does not support location region monitoring.")
            case .updateFailed:
                LocalizedStringResource("location.reminders.updateFailed",
                       defaultValue: "Couldn't update location reminders.",
                       comment: "Shown when a saved location reminder cannot be registered or refreshed.")
            }
        }
    }

    struct Region: Equatable, Sendable {
        let id: String
        let latitude: Double
        let longitude: Double
        let radius: Double

        init(id: String, center: CLLocationCoordinate2D, radius: Double) {
            self.id = id
            latitude = center.latitude
            longitude = center.longitude
            self.radius = radius
        }

        init?(_ region: CLRegion) {
            guard let circle = region as? CLCircularRegion else { return nil }
            self.init(id: circle.identifier, center: circle.center, radius: circle.radius)
        }

        func makeCircle() -> CLCircularRegion {
            let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let circle = CLCircularRegion(center: center, radius: radius, identifier: id)
            circle.notifyOnEntry = true
            circle.notifyOnExit = true
            return circle
        }
    }

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var pendingWork: Task<Void, Never>?

    private let locationManager: any GeofenceMonitoring
    private let debounce: Duration
    private let report: (Issue) -> Void
    private let notify: ((String, Bool) -> Void)?
    private let logger = Logger(subsystem: "com.nowthis", category: "geofence")

    private var container: ModelContainer?
    private var observation: CommitObservation?
    private var permissionRequestInFlight = false
    private var needsSnapshot = false
    private var desiredByID: [String: Region] = [:]
    private var pendingStarts: [String: Region] = [:]
    private var uncertainStartIDs = Set<String>()
    private var admittedUncertainCleanup = Set<String>()
    private var cancellingUncertainStarts = Set<String>()
    private var pendingStops = Set<String>()

    init(locationManager: any GeofenceMonitoring, debounce: Duration = .milliseconds(350),
         report: @escaping (Issue) -> Void = { ErrorState.shared.show(String(localized: $0.message)) },
         notify: ((String, Bool) -> Void)? = nil) {
        self.locationManager = locationManager
        self.debounce = debounce
        self.report = report
        self.notify = notify
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        (locationManager as? CLLocationManager)?.delegate = self
    }

    func configure(container: ModelContainer) {
        guard self.container !== container else { return }
        self.container = container
        let storeKey = CalendarMirrorState.storeKey(container)
        observation = CommitObservation(NotificationCenter.default.addObserver(
            forName: CalendarMirrorState.didCommit, object: nil, queue: nil
        ) { [weak self] notification in
            guard notification.object as? String == storeKey,
                  CalendarMirrorState.commitIncludesTaskChanges(notification) else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.requestReconciliation() }
            } else {
                Task { @MainActor [weak self] in self?.requestReconciliation() }
            }
        })
        requestReconciliation()
    }

    var permissionIssue: Issue? {
        switch authorizationStatus {
        case .denied: .denied
        case .restricted: .restricted
        case .authorizedWhenInUse, .authorizedAlways: locationManager.circularMonitoringAvailable ? nil : .unavailable
        default: nil
        }
    }

    /// Called by the location editor after a successful, intentional location save.
    func requestPermission() {
        if authorizationStatus != locationManager.authorizationStatus {
            authorizationChanged(to: locationManager.authorizationStatus)
        }
        if let permissionIssue {
            report(permissionIssue)
        } else if authorizationStatus == .notDetermined, !permissionRequestInFlight {
            permissionRequestInFlight = true
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func authorizationChanged(to status: CLAuthorizationStatus) {
        guard status != authorizationStatus else { return }
        authorizationStatus = status
        if status == .denied || status == .restricted {
            pendingStarts.removeAll()
            uncertainStartIDs.removeAll()
            admittedUncertainCleanup.removeAll()
            cancellingUncertainStarts.removeAll()
        }
        if status != .notDetermined, permissionRequestInFlight {
            permissionRequestInFlight = false
            if let permissionIssue { report(permissionIssue) }
        }
        requestReconciliation()
    }

    private var isAvailable: Bool {
        let status = locationManager.authorizationStatus
        return (status == .authorizedAlways || status == .authorizedWhenInUse)
            && locationManager.circularMonitoringAvailable
    }

    func requestReconciliation() {
        guard container != nil,
              isAvailable || !locationManager.monitoredRegions.isEmpty || !pendingStarts.isEmpty else { return }
        needsSnapshot = true
        guard pendingWork == nil else { return }
        pendingWork = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled else { return }
            defer {
                self.pendingWork = nil
                if self.needsSnapshot { self.requestReconciliation() }
            }
            // Core Location has no stop acknowledgment. Recheck capacity while an old
            // registration is still visible, then allow later commit or activation wakes.
            var desired: [Region] = []
            for delay in [Duration.zero, .milliseconds(100), .milliseconds(200), .milliseconds(400)] {
                if delay != .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled else { return }
                let receivedWake = self.needsSnapshot
                if receivedWake {
                    self.needsSnapshot = false
                    guard let savedRegions = self.readDesiredRegions() else { return }
                    desired = savedRegions
                }
                if !self.reconcile(desired, retryStops: delay == .zero, retryStarts: receivedWake),
                   !self.needsSnapshot { return }
            }
        }
    }

    private func readDesiredRegions() -> [Region]? {
        guard let container else { return nil }
        do {
            return try isAvailable ? desiredRegions(in: container) : []
        } catch {
            logger.error("Could not read saved geofences: \(String(describing: error), privacy: .private)")
            report(.updateFailed)
            return nil
        }
    }

    /// Returns whether a pending stop is currently holding a needed slot.
    private func reconcile(_ desired: [Region], retryStops: Bool, retryStarts: Bool) -> Bool {
        desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.id, $0) })
        var current = locationManager.monitoredRegions
        pendingStops.formIntersection(current.map(\.identifier))
        let completedStarts = pendingStarts.filter { _, region in
            current.contains { Region($0) == region }
        }
        for id in completedStarts.keys {
            settleStart(id)
        }

        let obsolete = current.compactMap { $0 as? CLCircularRegion }.filter {
            let isStopping = pendingStops.contains($0.identifier)
            return isStopping ? retryStops : desiredByID[$0.identifier] == nil
        }
        for region in obsolete {
            pendingStops.insert(region.identifier)
            locationManager.stopMonitoring(for: region)
        }
        if !obsolete.isEmpty { current = locationManager.monitoredRegions }

        let currentIDs = Set(current.map(\.identifier))
        pendingStops.formIntersection(currentIDs)
        reconcileUncertainStarts(activeIDs: currentIDs, retryStops: retryStops)
        var occupied = currentIDs.union(pendingStarts.keys)
        let waitingForStop = !pendingStops.isEmpty
        for region in desired {
            let id = region.id
            if pendingStops.contains(id) {
                continue
            }
            if pendingStarts[id] != nil {
                if current.contains(where: { Region($0) == region }) {
                    settleStart(id)
                    continue
                }
                // A general failure cannot free a slot. Retry the current geometry
                // under the same identifier and reservation.
                guard retryStarts, uncertainStartIDs.remove(id) != nil else { continue }
            }
            guard !current.contains(where: { Region($0) == region }) else { continue }
            guard occupied.contains(id) || occupied.count < Self.maxRegions else {
                continue
            }
            occupied.insert(id)
            admittedUncertainCleanup.remove(id)
            pendingStarts[id] = region
            // The native API replaces a circular region with the same identifier.
            locationManager.startMonitoring(for: region.makeCircle())
        }
        return waitingForStop
    }

    /// A general error cannot identify which start failed. Ask Core Location to
    /// cancel the obsolete request by ID. Absence alone does not free its slot:
    /// the native API has no cancellation acknowledgment.
    private func reconcileUncertainStarts(activeIDs: Set<String>, retryStops: Bool) {
        for id in uncertainStartIDs where desiredByID[id] == nil && !activeIDs.contains(id) {
            guard let pending = pendingStarts[id] else { continue }
            if cancellingUncertainStarts.insert(id).inserted || retryStops {
                locationManager.stopMonitoring(for: pending.makeCircle())
            }
        }
    }

    private func settleStart(_ id: String) {
        pendingStarts.removeValue(forKey: id)
        uncertainStartIDs.remove(id)
        admittedUncertainCleanup.remove(id)
        cancellingUncertainStarts.remove(id)
    }

    private func desiredRegions(in container: ModelContainer) throws -> [Region] {
        let maximumRadius = locationManager.maximumRegionMonitoringDistance
        guard maximumRadius.isFinite, maximumRadius > 0 else { return [] }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate {
            $0.latitude != nil && $0.longitude != nil && !$0.isDeletedLocally
        })
        descriptor.includePendingChanges = false
        let candidates = try context.fetch(descriptor).compactMap { task -> (TaskItem, Region)? in
            guard task.status != .completed, task.status != .cancelled,
                  let latitude = task.latitude, let longitude = task.longitude else { return nil }
            let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            let radius = task.geofenceRadius ?? Self.defaultRadius
            guard CLLocationCoordinate2DIsValid(center), radius.isFinite, radius > 0 else { return nil }
            return (task, Region(id: task.id, center: center, radius: min(radius, maximumRadius)))
        }
        return candidates.sorted { lhs, rhs in
            switch (lhs.0.dueDate, rhs.0.dueDate) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if lhs.0.createdDate != rhs.0.createdDate { return lhs.0.createdDate > rhs.0.createdDate }
            return lhs.0.id < rhs.0.id
        }.prefix(Self.maxRegions).map { $0.1 }
    }

    func monitoringStarted(_ region: Region?) {
        guard let region else { return }
        guard let pending = pendingStarts[region.id] else {
            if desiredByID[region.id] != region { requestReconciliation() }
            return
        }
        guard pending == region else { return }
        if locationManager.monitoredRegions.contains(where: { Region($0) == region }) {
            settleStart(region.id)
        }
        if desiredByID[region.id] != region { requestReconciliation() }
    }

    func monitoringFailed(_ region: Region?, error: Error) {
        if (error as? CLError)?.code == .regionMonitoringResponseDelayed { return }
        logger.error("Geofence registration failed: \(String(describing: error), privacy: .private)")
        guard let region else {
            uncertainStartIDs.formUnion(pendingStarts.keys)
            report(.updateFailed)
            // Admit cleanup once per obsolete reservation. A visible older
            // geometry can delay the exact cancellation but cannot rearm this wake.
            let obsolete = pendingStarts.keys.filter { desiredByID[$0] == nil }
            let newlyAdmitted = Set(obsolete).subtracting(admittedUncertainCleanup)
            if !newlyAdmitted.isEmpty {
                admittedUncertainCleanup.formUnion(newlyAdmitted)
                requestReconciliation()
            }
            return
        }
        let settled = pendingStarts[region.id] == region
        if settled { settleStart(region.id) }
        do {
            let eligible = try isAvailable ? container.map { try desiredRegions(in: $0) } ?? [] : []
            if eligible.contains(region) {
                report(.updateFailed)
            } else if settled {
                requestReconciliation()
            }
        } catch {
            logger.error("Could not confirm the failed geofence: \(String(describing: error), privacy: .private)")
            if settled { requestReconciliation() }
        }
    }

    func handleRegionEvent(_ region: Region?, entering: Bool) {
        guard let region, isAvailable, let container, !pendingStops.contains(region.id) else { return }
        do {
            // Delivery can beat the next reconciliation, including on a background launch.
            let eligible = try desiredRegions(in: container)
            guard eligible.contains(region) else { return }
            if let notify { notify(region.id, entering) }
            else { fireNotification(taskID: region.id, entering: entering) }
        } catch {
            logger.error("Could not confirm the saved location reminder: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: - Notification (P13-4)

    /// Requests notification permission for geofence alerts.
    func requestNotificationPermission() {
        guard NotificationPrompt.isAllowed(applicationIsActive: UIApplication.shared.applicationState == .active) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [logger] granted, error in
            if let error {
                logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    private func fireNotification(taskID: String, entering: Bool) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        content.title = entering
            ? String(localized: "notification.geofence.arrived.title",
                     defaultValue: "📍 You've arrived",
                     comment: "Title of the notification sent on entering a task's location. The pin emoji is part of the string; keep it at the start.")
            : String(localized: "notification.geofence.leaving.title",
                     defaultValue: "📍 You're leaving",
                     comment: "Title of the notification sent on leaving a task's location. The pin emoji is part of the string; keep it at the start.")
        content.body = entering
            ? String(localized: "notification.geofence.arrived.body",
                     defaultValue: "You have a task nearby. Open NowThis to see details.",
                     comment: "Body of the notification sent on entering a task's location. NowThis is the product name and is not translated.")
            : String(localized: "notification.geofence.leaving.body",
                     defaultValue: "Reminder: you're leaving a task location.",
                     comment: "Body of the notification sent on leaving a task's location.")
        content.userInfo = ["taskID": taskID]

        let request = UNNotificationRequest(
            identifier: "geofence-\(taskID)-\(entering ? "enter" : "exit")",
            content: content,
            trigger: nil // fire immediately
        )

        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("Failed to fire geofence notification: \(error.localizedDescription)")
            }
        }
    }
}

private final class CommitObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

extension GeofenceManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { authorizationChanged(to: status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let event = Region(region)
        MainActor.assumeIsolated { handleRegionEvent(event, entering: true) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let event = Region(region)
        MainActor.assumeIsolated { handleRegionEvent(event, entering: false) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        let started = Region(region)
        MainActor.assumeIsolated { monitoringStarted(started) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let failed = region.flatMap(Region.init)
        MainActor.assumeIsolated { monitoringFailed(failed, error: error) }
    }
}
