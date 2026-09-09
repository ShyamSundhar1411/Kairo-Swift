import Foundation
import KairoKit
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Delivers an allocated nudge as a local notification.
///
/// NFR8's ceiling is enforced by the arbiter, not here — a channel that silently
/// dropped nudges would corrupt the outcome history the receptivity model learns
/// from. This channel delivers whatever it is handed, or reports why it could not.
public final class NotificationNudgeChannel: NudgeChannel, @unchecked Sendable {
    public let kind: NudgeChannelKind

    public init(kind: NudgeChannelKind = .push) { self.kind = kind }

    /// NFR11: a channel declares what it can actually render.
    public func canRender(_ bid: NudgeBid, for profile: CapabilityProfile) -> Bool {
        switch kind {
        case .watchHaptic: return true                    // haptics need no sense in particular
        case .push, .inApp: return profile.available.contains(.vision)
                                || profile.available.contains(.hearing)
        case .silentHold: return true
        }
    }

    public enum ChannelError: Error, CustomStringConvertible {
        case notAuthorised
        public var description: String { "notifications are not authorised" }
    }

    public func deliver(_ nudge: Nudge) throws {
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title(for: nudge.bid.nudgeClass)
        content.body = nudge.bid.text
        content.sound = .default
        content.userInfo = [
            "bidID": nudge.bid.id,
            "class": nudge.bid.nudgeClass,
            "originAgent": nudge.bid.originAgent,
        ]
        // Categories give the user accept / snooze / dismiss straight from the
        // notification, which is where most outcomes are actually recorded.
        content.categoryIdentifier = "KAIRO_NUDGE"

        let request = UNNotificationRequest(
            identifier: nudge.bid.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    private func title(for nudgeClass: String) -> String {
        switch nudgeClass {
        case "hydration":   "Water"
        case "sedentary":   "Move"
        case "bedtimePrep": "Wind down"
        default:            "Kairo"
        }
    }

    public static func registerCategories() {
        #if canImport(UserNotifications)
        let accept = UNNotificationAction(identifier: "ACCEPT", title: "Done", options: [])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Later", options: [])
        let dismiss = UNNotificationAction(identifier: "DISMISS", title: "Not now",
                                           options: [.destructive])
        let category = UNNotificationCategory(
            identifier: "KAIRO_NUDGE", actions: [accept, snooze, dismiss],
            intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
        #endif
    }

    public static func requestAuthorization() async -> Bool {
        #if canImport(UserNotifications)
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        #else
        false
        #endif
    }
}
