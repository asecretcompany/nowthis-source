import AVFoundation
import ImageIO
import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The editor root owns presentation and import work across recycled Form sections.
@MainActor
final class TaskPhotoEditorState: ObservableObject {
    @Published var showingCamera = false
    @Published var isImporting = false
    @Published var photoError: TaskPhotoUIError?
    var importTask: Task<Void, Never>?
    var isActive = true
    var onCameraCapture: ((TaskPhotoImage) -> Void)?

    func captured(_ image: TaskPhotoImage) {
        showingCamera = false
        onCameraCapture?(image)
        onCameraCapture = nil
    }

    func cancelCamera() {
        showingCamera = false
        onCameraCapture = nil
    }

    func cameraFailed() {
        cancelCamera()
        photoError = .invalidImage
    }

    func cancelImport() {
        isActive = false
        importTask?.cancel()
        onCameraCapture = nil
    }
}

@MainActor
struct TaskPhotosSection: View {
    @Bindable var task: TaskItem
    let onSelectPhoto: (String) -> Void
    @ObservedObject var editor: TaskPhotoEditorState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @AppStorage("shareFullResolutionPhotos") private var shareFullResolutionPhotos = false
    @ScaledMetric(relativeTo: .body) private var thumbnailSide = 96.0
    @ScaledMetric(relativeTo: .caption) private var statusHeight = 90.0
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photoAccessAllowed = true

    private var isLive: Bool {
        editor.isActive && task.modelContext != nil && !task.isDeletedLocally && photoAccessAllowed && task.taskList?.photoAccessRevoked != true
    }

    private var canEdit: Bool {
        isLive && task.taskList?.isReadOnly != true
    }

    private var photos: [TaskPhotoDisplay] {
        guard isLive else { return [] }
        return task.photos
            .filter { $0.modelContext != nil && $0.pendingOperation != "remove" }
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder { return lhs.id < rhs.id }
                return lhs.sortOrder < rhs.sortOrder
            }
            .map { TaskPhotoDisplay(photo: $0, isVault: task.taskList?.account?.mode == .vault) }
    }

    private func refreshPhotoAccess() {
        photoAccessAllowed = (try? TaskPhotoAccessMaintenance.canView(task: task, container: modelContext.container)) ?? false
    }

    private var remainingSlots: Int { max(0, 5 - photos.count) }

    private var cameraAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    var body: some View {
        Section {
            if !photos.isEmpty {
                thumbnails
            }
            if canEdit {
                importControls
            }
            if editor.isImporting {
                ProgressView("Adding photos…")
                    .accessibilityIdentifier("taskPhotos.importProgress")
            }
        } header: {
            Text("Photos").accessibilityIdentifier("taskPhotos.section")
        } footer: {
            if canEdit {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add up to five photos. Previews are saved on this device before syncing.")
                    Text("Older NowThis versions can remove photos when saving tasks. Update every device that edits tasks with photos.", comment: "Versions before task photo support omit ATTACH when rewriting tasks. Users should update all editing devices before sharing task photos.")
                }
            }
        }
        .task(id: task.taskList?.id) { refreshPhotoAccess() }
        .onChange(of: syncScheduler.dataRefreshToken) { _, _ in refreshPhotoAccess() }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty, !editor.isImporting else { return }
            beginLibraryImport(items)
        }

    }

    private var thumbnails: some View {
        let displayedPhotos = photos
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(displayedPhotos.enumerated()), id: \.element.id) { index, photo in
                    Button {
                        onSelectPhoto(photo.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            TaskPhotoThumbnail(data: photo.previewData)
                                .frame(width: thumbnailSide, height: thumbnailSide)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            if let status = photo.originalStatusText(locale: locale) {
                                Text(status)
                                    .font(.caption)
                                    .lineLimit(3)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(width: thumbnailSide, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(format: String(localized: "tasks.photo.a11y.position",
                        defaultValue: "Photo %1$lld of %2$lld", locale: locale,
                        comment: "VoiceOver ordinal label for a task photo thumbnail; first is its position, second the total. Neither number inflects the noun."),
                        locale: locale, Int64(index + 1), Int64(displayedPhotos.count)))
                    .accessibilityValue(photo.originalStatusText(locale: locale) ?? "")
                    .accessibilityHint("Opens the photo viewer.")
                    .accessibilityIdentifier("taskPhotos.photo.\(photo.id)")
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: thumbnailSide + statusHeight)
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $pickerItems, maxSelectionCount: max(1, remainingSlots),
                         matching: .images, preferredItemEncoding: .current) {
                Label("Choose Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(editor.isImporting || remainingSlots == 0)
            .accessibilityIdentifier("taskPhotos.picker")

            if cameraAvailable {
                Button {
                    Task { await openCamera() }
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(editor.isImporting || remainingSlots == 0)
                .accessibilityIdentifier("taskPhotos.camera")
            }
            if remainingSlots == 0 {
                Text("This task already has five photos. Remove a photo to add another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
    }

    private func openCamera() async {
        guard canEdit, remainingSlots > 0, !editor.isImporting, cameraAvailable else { return }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }
        guard authorized else { editor.photoError = .cameraAccess; return }
        // Permissions and task membership can change while the system prompt is open.
        guard canEdit, remainingSlots > 0, !editor.isImporting, cameraAvailable else { return }
        editor.onCameraCapture = { image in beginCameraImport(image) }
        editor.showingCamera = true
    }

    private func beginLibraryImport(_ items: [PhotosPickerItem]) {
        guard !editor.isImporting else { return }
        guard isLive else { editor.photoError = .taskUnavailable; pickerItems = []; return }
        guard canEdit else { editor.photoError = .readOnly; pickerItems = []; return }
        let taskID = task.id
        let keepOriginal = shareFullResolutionPhotos
        editor.isImporting = true
        editor.importTask = Task { @MainActor in
            defer { editor.isImporting = false; pickerItems = []; editor.importTask = nil }
            for item in items {
                do {
                    try validateImport(taskID: taskID)
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw TaskPhotoUIError.libraryLoad
                    }
                    try await importPhoto(data, keepOriginal: keepOriginal, taskID: taskID)
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    editor.photoError = (error as? TaskPhotoUIError) ?? .libraryLoad
                    return
                }
            }
        }
    }

    private func beginCameraImport(_ image: TaskPhotoImage) {
        guard !editor.isImporting else { return }
        guard isLive else { editor.photoError = .taskUnavailable; return }
        guard canEdit else { editor.photoError = .readOnly; return }
        let taskID = task.id
        let keepOriginal = shareFullResolutionPhotos
        editor.isImporting = true
        editor.importTask = Task { @MainActor in
            defer { editor.isImporting = false; editor.importTask = nil }
            do {
                // Encode the full originalImage at its native dimensions, never a resized thumbnail.
                let data = try await Task.detached(priority: .utility) {
                    guard let data = image.image.jpegData(compressionQuality: 1) else {
                        throw TaskPhotoUIError.invalidImage
                    }
                    return data
                }.value
                try await importPhoto(data, keepOriginal: keepOriginal, taskID: taskID)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                editor.photoError = (error as? TaskPhotoUIError) ?? .invalidImage
            }
        }
    }

    private func validateImport(taskID: String) throws {
        try Task.checkCancellation()
        guard isLive, task.id == taskID else { throw TaskPhotoUIError.taskUnavailable }
        guard canEdit else { throw TaskPhotoUIError.readOnly }
        guard remainingSlots > 0 else { throw TaskPhotoUIError.limit }
    }

    private func importPhoto(_ data: Data, keepOriginal: Bool, taskID: String) async throws {
        try validateImport(taskID: taskID)
        if keepOriginal && data.count > 25_000_000 { throw TaskPhotoUIError.originalTooLarge }
        let processed: ProcessedTaskPhoto
        do {
            processed = try await Task.detached(priority: .utility) {
                try TaskPhotoProcessor.process(data, keepOriginal: keepOriginal)
            }.value
        } catch {
            throw TaskPhotoUIError.invalidImage
        }
        try validateImport(taskID: taskID)
        let localPhotoID = UUID().uuidString
        var cachedOriginal = false
        do {
            if let original = processed.originalData {
                do {
                    // Cache keys are local model IDs, not wire UUIDs shared across accounts.
                    try await TaskPhotoOriginals.cache.store(original, photoID: localPhotoID)
                    cachedOriginal = true
                } catch {
                    throw TaskPhotoUIError.originalSave
                }
            }
            try validateImport(taskID: taskID)
            let wasDirty = task.isDirty
            let previousModified = task.lastModifiedDate
            let photo = try TaskPhotoMutations.add(preview: processed.previewData,
                originalRequested: keepOriginal, contentType: processed.originalContentType,
                to: task, in: modelContext, id: localPhotoID)
            do {
                try ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
            } catch {
                // Undo only this import; rolling back the whole context would discard other edits.
                task.photos.removeAll { $0 === photo }
                modelContext.delete(photo)
                task.isDirty = wasDirty
                task.lastModifiedDate = previousModified
                throw TaskPhotoUIError.previewSave
            }
            cachedOriginal = false // The saved photo now owns its cache entry.
            syncScheduler.syncAfterChange(modelContext: modelContext)
        } catch {
            if cachedOriginal {
                try? await TaskPhotoOriginals.cache.remove(photoID: localPhotoID)
            }
            if let mutationError = error as? TaskPhotoMutationError {
                switch mutationError {
                case .readOnly: throw TaskPhotoUIError.readOnly
                case .limit: throw TaskPhotoUIError.limit
                case .invalidPreview: throw TaskPhotoUIError.invalidImage
                }
            }
            throw error
        }
    }
}

struct TaskPhotoSelection: Identifiable {
    let id: String
}

/// Value snapshots keep thumbnail rendering away from models invalidated during account deletion.
private struct TaskPhotoDisplay: Sendable {
    let id: String
    let previewData: Data
    let originalRequested: Bool
    let originalStatus: String?
    let originalFileID: String?
    let isVault: Bool

    init(photo: TaskPhoto, isVault: Bool) {
        id = photo.id
        previewData = photo.previewData
        originalRequested = photo.originalRequested
        originalStatus = photo.originalStatus
        originalFileID = photo.originalFileID
        self.isVault = isVault
    }

    func originalStatusText(locale: Locale) -> String? {
        guard originalRequested, !isVault else { return nil }
        switch originalStatus.flatMap(TaskPhotoOriginalStatus.init(rawValue:)) {
        case .waiting:
            return String(localized: "Waiting for list owner setup", locale: locale,
                comment: "The list owner's app must provision Nextcloud Files sharing before an editor can share a photo original.")
        case .available:
            return String(localized: "Full resolution available", locale: locale,
                comment: "Status of a task photo whose original can be requested separately from its optimized preview.")
        case .unavailable:
            return String(localized: "Original unavailable", locale: locale,
                comment: "The original cannot currently be accessed; the optimized preview remains usable.")
        default:
            return String(localized: "Full resolution pending", locale: locale,
                comment: "The optimized preview is usable while the original awaits upload or sharing.")
        }
    }
}

// UIImage is immutable here. The wrapper permits background decoding/encoding; UI use stays on MainActor.
struct TaskPhotoImage: @unchecked Sendable {
    let image: UIImage
}

private struct TaskPhotoThumbnail: View {
    let data: Data
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .accessibilityHidden(true)
        .task(id: data) {
            image = nil
            let decoded = await Task.detached(priority: .utility) {
                TaskPhotoDisplayDecoder.decode(data,
                    maximumDimension: TaskPhotoDisplayDecoder.thumbnailMaximumDimension)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded?.image
        }
    }
}

@MainActor
struct TaskPhotoViewer: View {
    @Bindable var task: TaskItem
    let photoID: String
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @EnvironmentObject private var syncScheduler: SyncScheduler
    @State private var previewImage: UIImage?
    @State private var originalImage: UIImage?
    @State private var showingOriginal = false
    @State private var isLoadingOriginal = false
    @State private var originalFailed = false
    @State private var originalLoadTask: Task<Void, Never>?
    @State private var originalRequestID: UUID?
    @State private var confirmingRemoval = false
    @State private var photoError: TaskPhotoUIError?
    @State private var photoAccessAllowed = true

    private var livePhoto: TaskPhoto? {
        guard task.modelContext != nil, !task.isDeletedLocally,
              photoAccessAllowed, task.taskList?.photoAccessRevoked != true else { return nil }
        return task.photos.first {
            $0.modelContext != nil && $0.id == photoID && $0.pendingOperation != "remove"
        }
    }

    private var canEdit: Bool {
        livePhoto != nil && task.taskList?.isReadOnly != true
    }

    var body: some View {
        NavigationStack {
            if let photo = livePhoto {
                viewer(TaskPhotoDisplay(photo: photo, isVault: task.taskList?.account?.mode == .vault))
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .presentationDetents([.large])
        .task(id: task.taskList?.id) { refreshPhotoAccess() }
        .onChange(of: syncScheduler.dataRefreshToken) { _, _ in refreshPhotoAccess() }
        .onDisappear { originalLoadTask?.cancel() }
        .confirmationDialog("Remove this photo?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            if canEdit {
                Button("Remove Photo", role: .destructive) { removePhoto() }
                    .accessibilityIdentifier("taskPhotos.confirmRemove")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if task.modelContext != nil && task.taskList?.account?.mode == .vault {
                Text("The photo will be removed from this task on this device.", comment: "Removal confirmation for a Vault task, which is never synced or shared.")
            } else {
                Text("The photo will be removed from this task for everyone when it syncs.")
            }
        }
        .alert("Photo Error", isPresented: Binding(
            get: { photoError != nil }, set: { if !$0 { photoError = nil } }), presenting: photoError) { _ in
                Button("OK", role: .cancel) { photoError = nil }
        } message: { error in
            Text(error.message(locale: locale))
        }
    }

    private func viewer(_ photo: TaskPhotoDisplay) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Color.black
                if let image = showingOriginal ? originalImage : previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Task photo")
                        .accessibilityIdentifier("taskPhotos.viewer.image")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if photo.originalRequested {
                originalControls(photo)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .navigationTitle("Photo")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("taskPhotos.viewer.done")
            }
            if canEdit {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Remove Photo", systemImage: "trash") { confirmingRemoval = true }
                        .accessibilityIdentifier("taskPhotos.remove")
                }
            }
        }
        .task(id: photo.previewData) {
            let decoded = await Task.detached(priority: .utility) {
                TaskPhotoDisplayDecoder.decode(photo.previewData,
                    maximumDimension: TaskPhotoDisplayDecoder.viewerMaximumDimension)
            }.value
            guard !Task.isCancelled else { return }
            previewImage = decoded?.image
            if previewImage == nil { photoError = .invalidImage }
        }
        .onChange(of: photo.originalFileID) { _, _ in
            originalRequestID = nil
            originalLoadTask?.cancel()
            originalImage = nil
            showingOriginal = false
            isLoadingOriginal = false
            originalFailed = false
        }
    }

    private func refreshPhotoAccess() {
        photoAccessAllowed = (try? TaskPhotoAccessMaintenance.canView(task: task, container: modelContext.container)) ?? false
        if !photoAccessAllowed {
            originalLoadTask?.cancel(); originalImage = nil; previewImage = nil; dismiss()
        }
    }

    private func originalControls(_ photo: TaskPhotoDisplay) -> some View {
        VStack(spacing: 8) {
            if originalFailed {
                Text("Original unavailable. You can still view the preview.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("taskPhotos.originalError")
            } else if let status = photo.originalStatusText(locale: locale) {
                Text(status).foregroundStyle(.secondary)
                    .accessibilityIdentifier("taskPhotos.originalStatus")
            }
            if isLoadingOriginal {
                ProgressView("Loading full resolution…")
                    .accessibilityIdentifier("taskPhotos.originalProgress")
            }
            if showingOriginal {
                Button("View Preview") { showingOriginal = false }
                    .accessibilityIdentifier("taskPhotos.preview")
            } else {
                Button("View Full Resolution") { loadOriginal() }
                    .disabled(isLoadingOriginal)
                    .accessibilityIdentifier("taskPhotos.fullResolution")
            }
        }
        .font(.callout)
    }

    private func loadOriginal() {
        guard let photo = livePhoto, photo.originalRequested, !isLoadingOriginal else { return }
        if originalImage != nil {
            showingOriginal = true
            originalFailed = false
            return
        }
        let taskID = task.id
        let container = modelContext.container
        let requestID = UUID()
        originalRequestID = requestID
        isLoadingOriginal = true
        originalFailed = false
        originalLoadTask = Task { @MainActor in
            defer {
                if originalRequestID == requestID {
                    isLoadingOriginal = false
                    originalLoadTask = nil
                    originalRequestID = nil
                }
            }
            do {
                let data = try await TaskPhotoOriginals.load(photoID: photoID, taskID: taskID, container: container)
                try Task.checkCancellation()
                let decoded = await Task.detached(priority: .utility) {
                    TaskPhotoDisplayDecoder.decode(data,
                        maximumDimension: TaskPhotoDisplayDecoder.viewerMaximumDimension)
                }.value
                try Task.checkCancellation()
                guard originalRequestID == requestID, livePhoto != nil, task.id == taskID else { return }
                guard let decoded else { throw TaskPhotoUIError.invalidImage }
                originalImage = decoded.image
                showingOriginal = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, originalRequestID == requestID, livePhoto != nil else { return }
                showingOriginal = false
                originalFailed = true
            }
        }
    }

    private func removePhoto() {
        guard let photo = livePhoto else { dismiss(); return }
        guard canEdit else { photoError = .readOnly; return }
        let previousOperation = photo.pendingOperation
        let wasDirty = task.isDirty
        let previousModified = task.lastModifiedDate
        do {
            try TaskPhotoMutations.remove(photo, from: task, in: modelContext)
            do {
                try ReminderSchedulingJournal.saveTaskChanges(in: modelContext)
            } catch {
                photo.pendingOperation = previousOperation
                task.isDirty = wasDirty
                task.lastModifiedDate = previousModified
                throw TaskPhotoUIError.removalSave
            }
            let taskID = task.id
            let container = modelContext.container
            Task { try? await TaskPhotoLocalCleanup.run(photoID: photoID, taskID: taskID, container: container) }
            // Shared originals follow the durable sync cleanup path.
            syncScheduler.syncAfterChange(modelContext: modelContext)
            dismiss()
        } catch {
            photoError = (error as? TaskPhotoUIError) ?? .removalSave
        }
    }
}

@MainActor
struct TaskPhotoCamera: UIViewControllerRepresentable {
    let onCapture: (TaskPhotoImage) -> Void
    let onCancel: () -> Void
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: TaskPhotoCamera

        init(parent: TaskPhotoCamera) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { parent.onFailure(); return }
            parent.onCapture(TaskPhotoImage(image: image))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

enum TaskPhotoUIError: Error {
    case libraryLoad, invalidImage, originalTooLarge, originalSave, previewSave
    case removalSave, readOnly, limit, taskUnavailable, cameraAccess

    func message(locale: Locale) -> String {
        switch self {
        case .libraryLoad:
            String(localized: "The photo could not be loaded. Check your photo library access and try again.",
                locale: locale, comment: "Alert when loading a selected library photo fails, including an iCloud photo that cannot be downloaded.")
        case .invalidImage:
            String(localized: "This image could not be processed. Please choose another photo.",
                locale: locale, comment: "Alert for a corrupt image or an image that cannot be converted to an optimized preview.")
        case .originalTooLarge:
            String(localized: "This original is larger than 25 MB. Choose a smaller photo or turn off full-resolution sharing in Settings and try again.",
                locale: locale, comment: "Alert before importing an original that exceeds the 25 MB limit; the user's preference is not changed automatically.")
        case .originalSave:
            String(localized: "The original could not be saved on this device. Check available storage and try again.",
                locale: locale, comment: "Alert when the local original cache cannot be written; the requested original is not silently discarded.")
        case .previewSave:
            String(localized: "The photo could not be saved. Please try again.",
                locale: locale, comment: "Alert when saving an imported task photo to the local database fails.")
        case .removalSave:
            String(localized: "The photo could not be removed. Please try again.",
                locale: locale, comment: "Alert when saving a task photo removal fails; the photo remains visible.")
        case .readOnly:
            String(localized: "You can view photos in this list, but you no longer have permission to change them.",
                locale: locale, comment: "Alert when list edit permission is lost while adding or removing a task photo.")
        case .limit:
            String(localized: "This task already has five photos. Remove a photo to add another.",
                locale: locale, comment: "Five-photo limit, also checked after asynchronous image loading.")
        case .taskUnavailable:
            String(localized: "This task is no longer available. The photo was not added.",
                locale: locale, comment: "Alert when a task or its account disappears during asynchronous photo import.")
        case .cameraAccess:
            String(localized: "Camera access is unavailable. Allow access in Settings or choose a photo from your library.",
                locale: locale, comment: "Alert when camera access is denied or restricted.")
        }
    }
}
