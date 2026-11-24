import Foundation

/// The only VEVENT representation the Nextcloud recovery path can attribute to a retained operation.
enum NextcloudEventBody {
    static let maximumBytes = 256 * 1_024
    private static let operationProperty = "X-NOWTHIS-MIRROR-OPERATION"
    private static let requiredProperties: Set<String> = [
        "UID", "DTSTAMP", "DTSTART", "DTEND", "SUMMARY", "STATUS", "RELATED-TO", operationProperty
    ]
    private static let supportedProperties = requiredProperties.union(["DESCRIPTION", "PRIORITY", "LOCATION", "URL"])

    static func make(task: TaskItem, uid: String, operation: UUID, stamp: Date) throws -> String {
        guard [task.uid, task.url ?? ""].allSatisfy({ !$0.utf8.contains(13) && !$0.utf8.contains(10) }),
              [task.title, task.descriptionText ?? "", task.locationName ?? ""].allSatisfy({ !$0.utf8.contains(13) }),
              var body = VEventSerializer.serialize(task: task, eventUID: uid, stamp: stamp),
              let component = body.range(of: "\r\nBEGIN:VEVENT\r\n") else { throw CalDAVError.invalidResponse }
        body.insert(contentsOf: "\(operationProperty):\(operation.uuidString)\r\n", at: component.upperBound)
        guard evidence(body, uid: uid)?.operation == operation else { throw CalDAVError.invalidResponse }
        return body
    }

    static func evidence(_ body: String, uid: String) -> (operation: UUID, proof: String)? {
        guard body.utf8.count <= maximumBytes else { return nil }
        let normalized = SyncResourceState.unfoldedUTF8(body)
        guard normalized.allSatisfy({ $0 == 9 || $0 == 10 || ($0 >= 32 && $0 != 127) }) else { return nil }
        var lines = normalized.split(separator: 10, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 6, line(lines[0]) == "BEGIN:VCALENDAR", line(lines[1]) == "VERSION:2.0",
              line(lines[2]).hasPrefix("PRODID:"), line(lines[3]) == "BEGIN:VEVENT",
              line(lines[lines.count - 2]) == "END:VEVENT", line(lines[lines.count - 1]) == "END:VCALENDAR" else { return nil }
        var properties: [String: String] = [:]
        for bytes in lines.dropFirst(4).dropLast(2) {
            let value = line(bytes)
            guard let separator = value.firstIndex(of: ":") else { return nil }
            let name = String(value[..<separator])
            guard supportedProperties.contains(name), properties[name] == nil else { return nil }
            properties[name] = String(value[value.index(after: separator)...])
        }
        guard requiredProperties.isSubset(of: properties.keys),
              properties["UID"]?.utf8.elementsEqual(uid.utf8) == true,
              let token = properties[operationProperty], let operation = UUID(uuidString: token),
              operation.uuidString == token else { return nil }
        return (operation, SyncResourceState.fingerprint(body))
    }

    private static func line(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
}
