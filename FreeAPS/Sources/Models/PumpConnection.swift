import Foundation

/// Tracks real pump communication for the pumpLastConnection automation metric.
/// lastCommunicationAt advances whenever the pump manager reports an update,
/// which only happens after a successful round trip to the pump. awakeSince marks
/// the start of the current active app session, so time the app spent suspended
/// in the background is not counted as a lost pump connection.
struct PumpConnection: JSON, Equatable {
    var lastCommunicationAt: Date?
    var awakeSince: Date?
}
