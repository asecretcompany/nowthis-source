@preconcurrency import CoreLocation
import UserNotifications
import SwiftData
import os

/// Manages geofence monitoring for location-based task reminders.
///
/// Wraps `CLLocationManager` to register/unregister circular regions
/// around task locations. Fires local notifications when the user
/// enters or exits a monitored region.
///
/// **iOS Limits:** Maximum 20 monitored regions. When exceeding this,
/// regions are prioritized by task due date proximity.
///
/// **Permissions:** Requests `.authorizedWhenInUse` first, then
/// escalates to `.authorizedAlways` for background monitoring.
@MainActor
final class GeofenceManager: NSObject, ObservableObject {

    static let shared = GeofenceManager()

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let locationManager = CLLocationManager()
    private let logger = Logger(subsystem: "com.nowthis", category: "geofence")
    private static let maxRegions = 20
    static let defaultRadius: Double = 100 // meters

    override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Permission Handling

    /// Requests location permission with graceful escalation.
    ///
    /// First requests When In Use, which is sufficient for geofence
    /// monitoring on iOS 13+. Background delivery happens automatically.
    func requestPermission() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// Whether geofencing is available (authorized + monitoring supported).
    var isAvailable: Bool {
        let status = locationManager.authorizationStatus
        let authorized = status == .authorizedAlways || status == .authorizedWhenInUse
        return authorized && CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)
    }

    // MARK: - Region Management

    /// Registers a geofence for a task with location coordinates.
    ///
    /// - Parameters:
    ///   - task: The task to monitor. Must have `latitude`, `longitude` set.
    ///   - radius: Geofence radius in meters. Defaults to `task.geofenceRadius ?? 100`.
    func startMonitoring(task: TaskItem, radius: Double? = nil) {
        guard let lat = task.latitude, let lon = task.longitude else {
            logger.debug("Skipping geofence for \(task.id): no coordinates")
            return
        }
        guard isAvailable else {
            logger.info("Geofencing unavailable, status: \(self.locationManager.authorizationStatus.rawValue)")
            return
        }

        let effectiveRadius = min(
            radius ?? task.geofenceRadius ?? Self.defaultRadius,
            locationManager.maximumRegionMonitoringDistance
        )

        let region = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            radius: effectiveRadius,
            identifier: task.id
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true

        locationManager.startMonitoring(for: region)
        logger.info("Started monitoring region for task \(task.id) at (\(lat),\(lon)) r=\(effectiveRadius)m")
    }

    /// Stops monitoring a task's geofence.
    func stopMonitoring(taskID: String) {
        for region in locationManager.monitoredRegions {
            if region.identifier == taskID {
                locationManager.stopMonitoring(for: region)
                logger.info("Stopped monitoring region for task \(taskID)")
                return
            }
        }
    }

    /// Re-evaluates which tasks to monitor based on the 20-region iOS limit.
    ///
    /// Prioritizes tasks by:
    /// 1. Has a due date (sooner due dates first)
    /// 2. No due date (by creation date, newest first)
    ///
    /// Call this after task changes (add/edit/delete/complete).
    @MainActor
    func refreshMonitoredRegions(modelContext: ModelContext) {
        // Fetch tasks with coordinates that aren't deleted
        let predicate = #Predicate<TaskItem> {
            $0.latitude != nil &&
            $0.longitude != nil &&
            !$0.isDeletedLocally
        }
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: predicate
        )
        guard let candidates = try? modelContext.fetch(descriptor) else { return }

        let activeCandidates = candidates.filter {
            $0.status != .completed && $0.status != .cancelled
        }

        // Sort: due date ascending (nil = end), then created date descending
        let sorted = activeCandidates.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (ad?, bd?): return ad < bd
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.createdDate > b.createdDate
            }
        }

        let toMonitor = Array(sorted.prefix(Self.maxRegions))
        let monitorIDs = Set(toMonitor.map(\.id))

        // Stop monitoring tasks no longer in the top 20
        for region in locationManager.monitoredRegions {
            if !monitorIDs.contains(region.identifier) {
                locationManager.stopMonitoring(for: region)
            }
        }

        // Start monitoring new tasks
        let currentIDs = Set(locationManager.monitoredRegions.map(\.identifier))
        for task in toMonitor where !currentIDs.contains(task.id) {
            startMonitoring(task: task)
        }

        logger.info("Refreshed geofences: \(toMonitor.count) of \(activeCandidates.count) candidates")
    }

    // MARK: - Notification

    /// Requests notification permission for geofence alerts.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [logger] granted, error in
            if let error {
                logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    private func fireNotification(taskID: String, entering: Bool) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        // Try to include task title from the region identifier
        content.title = entering ? "📍 You've arrived" : "📍 You're leaving"
        content.body = entering
            ? "You have a task nearby. Open NowThis to see details."
            : "Reminder: you're leaving a task location."
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

// MARK: - CLLocationManagerDelegate

extension GeofenceManager: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.authorizationStatus = status
        }
        logger.info("Location authorization changed to: \(status.rawValue)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        logger.info("Entered region: \(region.identifier)")
        MainActor.assumeIsolated {
            fireNotification(taskID: region.identifier, entering: true)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        logger.info("Exited region: \(region.identifier)")
        MainActor.assumeIsolated {
            fireNotification(taskID: region.identifier, entering: false)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        logger.error("Monitoring failed for \(region?.identifier ?? "unknown"): \(error.localizedDescription)")
    }
}
