import AppIntents
import CoreSpotlight

extension TaskEntity: IndexedEntity {}

enum SpotlightEntityLink {
    static func apply(taskID: String, to attributes: CSSearchableItemAttributeSet) {
        if #available(iOS 27.0, *) {
            attributes.relatedAppEntityIdentifier = EntityIdentifier(for: TaskEntity.self, identifier: taskID)
        } else {
            attributes.relatedUniqueIdentifier = taskID
        }
    }
}
