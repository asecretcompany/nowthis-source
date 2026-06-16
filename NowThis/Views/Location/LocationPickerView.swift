import SwiftUI
import MapKit

/// Location picker for setting a task's geofence location.
///
/// Provides a search field that geocodes addresses, a map preview
/// showing the pin and geofence radius, and a radius slider.
/// Used from TaskDetailView's DetailsSection.
struct LocationPickerView: View {

    @Bindable var task: TaskItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var radius: Double
    @State private var cameraPosition: MapCameraPosition = .automatic
    @StateObject private var geofenceManager = GeofenceManager.shared

    init(task: TaskItem) {
        self.task = task
        _radius = State(initialValue: task.geofenceRadius ?? GeofenceManager.defaultRadius)
    }

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                if selectedCoordinate != nil || task.latitude != nil {
                    mapSection
                    radiusSection
                }
                if task.latitude != nil {
                    removeSection
                }
            }
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
            .onAppear { loadExisting() }
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
                            Text(item.name ?? "Unknown")
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

    private var mapSection: some View {
        Section("Preview") {
            let coord = selectedCoordinate ?? CLLocationCoordinate2D(
                latitude: task.latitude ?? 0,
                longitude: task.longitude ?? 0
            )
            Map(position: $cameraPosition) {
                Marker(task.locationName ?? "Task", coordinate: coord)
                MapCircle(center: coord, radius: radius)
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
                    Text("\(Int(radius))m")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $radius, in: 50...1000, step: 25)
                    .accessibilityLabel("Geofence radius, \(Int(radius)) meters")
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
        selectedCoordinate = coord
        task.locationName = item.name ?? searchText
        task.latitude = coord.latitude
        task.longitude = coord.longitude
        searchResults = []
        searchText = item.name ?? ""
        cameraPosition = .region(MKCoordinateRegion(
            center: coord,
            latitudinalMeters: radius * 3,
            longitudinalMeters: radius * 3
        ))
    }

    private func clearLocation() {
        GeofenceManager.shared.stopMonitoring(taskID: task.id)
        task.locationName = nil
        task.latitude = nil
        task.longitude = nil
        task.geofenceRadius = nil
        selectedCoordinate = nil
        task.isDirty = true
        task.lastModifiedDate = Date()
        try? modelContext.save()
        dismiss()
    }

    private func save() {
        task.geofenceRadius = radius
        task.isDirty = true
        task.lastModifiedDate = Date()

        if task.latitude != nil {
            GeofenceManager.shared.startMonitoring(task: task, radius: radius)
        }

        try? modelContext.save()
        dismiss()
    }

    private func loadExisting() {
        if let name = task.locationName {
            searchText = name
        }
        if let lat = task.latitude, let lon = task.longitude {
            let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            selectedCoordinate = coord
            cameraPosition = .region(MKCoordinateRegion(
                center: coord,
                latitudinalMeters: radius * 3,
                longitudinalMeters: radius * 3
            ))
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
