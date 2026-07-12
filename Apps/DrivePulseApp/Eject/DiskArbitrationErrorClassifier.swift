import Darwin
import DiskArbitration

struct DiskArbitrationErrorClassifier: Sendable {
    private enum MachErrorLayout {
        static let subsystemMask: UInt32 = 0xFC00_0000
        static let subsystemShift: UInt32 = 26
        static let systemMask: UInt32 = 0x03FF_C000
        static let systemShift: UInt32 = 14
        static let codeMask: UInt32 = 0x0000_3FFF

        static let unixSystem: UInt32 = 3
        static let unixSubsystem: UInt32 = 0
    }

    func classify(_ status: DAReturn) -> EjectFailureCategory {
        switch status {
        case DAReturn(kDAReturnBusy):
            return .busy
        case DAReturn(kDAReturnExclusiveAccess):
            return .exclusiveAccess
        case DAReturn(kDAReturnNotFound):
            return .notFound
        case DAReturn(kDAReturnNotMounted):
            return .notMounted
        case DAReturn(kDAReturnNotPermitted), DAReturn(kDAReturnNotPrivileged):
            return .notPermitted
        case DAReturn(kDAReturnNotReady):
            return .notReady
        case DAReturn(kDAReturnError):
            return .io
        default:
            return unixErrno(from: status) == EBUSY ? .busy : .unknown
        }
    }

    func unixErrno(from status: DAReturn) -> Int32? {
        let bits = UInt32(bitPattern: status)
        let system = (bits & MachErrorLayout.systemMask) >> MachErrorLayout.systemShift
        let subsystem = (bits & MachErrorLayout.subsystemMask) >> MachErrorLayout.subsystemShift

        guard system == MachErrorLayout.unixSystem,
              subsystem == MachErrorLayout.unixSubsystem else {
            return nil
        }

        return Int32(bits & MachErrorLayout.codeMask)
    }
}
