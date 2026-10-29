import CloudKit
import CoreData
import Foundation

/// Says why iCloud sync failed, record by record, in Seek's own log (`devicectl … --console`
/// shows it on a device, where the framework's own logs don't come through).
enum SyncReport {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil, !event.succeeded, let error = event.error else { return }
            let kind = switch event.type {
            case .setup: "setup"
            case .import: "import"
            case .export: "export"
            @unknown default: "event"
            }
            Log.debug("icloud \(kind) failed: \(describe(error))")
        }
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        guard let ck = error as? CKError ?? (error.domain == CKError.errorDomain ? CKError(_nsError: error) : nil) else {
            return "\(error.domain) \(error.code) \(error.localizedDescription)"
        }
        guard ck.code == .partialFailure, let items = ck.partialErrorsByItemID else {
            // Everything it says, including the errors underneath.
            return "CKError \(ck.code.rawValue) \(error.userInfo)"
        }
        // The reasons, each with how many records failed for it and one record's name.
        var reasons: [String: (count: Int, example: String)] = [:]
        for (item, itemError) in items {
            let e = itemError as NSError
            let reason = "\(e.domain) \(e.code): \(e.localizedDescription) \(e.userInfo[NSUnderlyingErrorKey] ?? "")"
            let name = (item as? CKRecord.ID)?.recordName ?? (item as? CKRecordZone.ID)?.zoneName ?? "\(item)"
            reasons[reason] = (reasons[reason]?.count ?? 0) + 1 == 1 ? (1, name) : ((reasons[reason]!.count + 1), reasons[reason]!.example)
        }
        return "partial failure, \(items.count) records: " + reasons.map { "\($0.value.count)× \($0.key) (e.g. \($0.value.example))" }
            .sorted().joined(separator: " | ")
    }
}
