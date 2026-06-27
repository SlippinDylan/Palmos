import Foundation

public enum SmartSnapshot: Equatable, Sendable {
    case notRequested
    case loading
    case available(SmartData)
    case unsupported
    case helperNotInstalled
    case permissionRequired
    case transportUnsupported
    case deviceUnavailable
    case updateRequired
    case failed(String)
}
