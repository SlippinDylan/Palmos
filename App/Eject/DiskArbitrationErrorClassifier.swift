import Darwin
import DiskArbitration

struct DiskArbitrationErrorClassifier: Sendable {
    private enum MachErrorLayout {
        static let systemMask: UInt32 = 0xFC00_0000
        static let systemShift: UInt32 = 26
        static let subsystemMask: UInt32 = 0x03FF_C000
        static let subsystemShift: UInt32 = 14
        static let codeMask: UInt32 = 0x0000_3FFF

        static let unixSystem: Int32 = 0
        static let unixSubsystem: Int32 = 3
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
        let fields = machFields(from: status)

        guard fields.system == MachErrorLayout.unixSystem,
              fields.subsystem == MachErrorLayout.unixSubsystem else {
            return nil
        }

        return fields.code
    }

    func machFields(from status: DAReturn) -> MachErrorFields {
        let bits = UInt32(bitPattern: status)
        return MachErrorFields(
            system: Int32((bits & MachErrorLayout.systemMask) >> MachErrorLayout.systemShift),
            subsystem: Int32((bits & MachErrorLayout.subsystemMask) >> MachErrorLayout.subsystemShift),
            code: Int32(bits & MachErrorLayout.codeMask)
        )
    }
}

struct MachErrorFields: Equatable, Sendable {
    let system: Int32
    let subsystem: Int32
    let code: Int32
}
