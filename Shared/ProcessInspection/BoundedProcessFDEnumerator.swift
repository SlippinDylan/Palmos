import Darwin
import Foundation

struct ProcessInspectionLimits: Equatable, Sendable {
    private static let hardMaximum = 16_384

    /// The hard cap bounds the raw kernel buffer to 128 KiB on Darwin; converted values use at most another 128 KiB.
    let maxFileDescriptorsPerProcess: Int

    init(maxFileDescriptorsPerProcess: Int = 16_384) {
        self.maxFileDescriptorsPerProcess = min(max(0, maxFileDescriptorsPerProcess), Self.hardMaximum)
    }

    static let `default` = ProcessInspectionLimits(maxFileDescriptorsPerProcess: 16_384)
}

struct ProcessFileDescriptor: Equatable, Sendable {
    let number: Int32
    let type: UInt32
}

struct ProcessFileDescriptorEnumeration: Equatable, Sendable {
    let descriptors: [ProcessFileDescriptor]
    let isComplete: Bool
}

typealias ProcessFDListQuery = @Sendable (
    _ pid: Int32,
    _ buffer: UnsafeMutableRawPointer?,
    _ byteCount: Int32
) -> Int32

enum BoundedProcessFDEnumerator {
    static func enumerate(
        pid: Int32,
        limits: ProcessInspectionLimits = .default,
        while shouldContinue: @escaping @Sendable () -> Bool = { !Task.isCancelled },
        query: @escaping ProcessFDListQuery = Self.liveQuery
    ) -> ProcessFileDescriptorEnumeration {
        guard shouldContinue() else { return .init(descriptors: [], isComplete: false) }
        let reportedBytes = query(pid, nil, 0)
        guard reportedBytes >= 0 else { return .init(descriptors: [], isComplete: false) }
        guard shouldContinue() else { return .init(descriptors: [], isComplete: false) }
        guard reportedBytes > 0 else { return .init(descriptors: [], isComplete: true) }

        let stride = MemoryLayout<proc_fdinfo>.stride
        let reportedByteCount = Int(reportedBytes)
        guard reportedByteCount % stride == 0 else {
            return .init(descriptors: [], isComplete: false)
        }

        let reportedCount = reportedByteCount / stride
        let boundedCount = min(reportedCount, limits.maxFileDescriptorsPerProcess)
        guard boundedCount > 0 else { return .init(descriptors: [], isComplete: false) }
        let allocation = boundedCount.multipliedReportingOverflow(by: stride)
        guard !allocation.overflow,
              allocation.partialValue <= Int(Int32.max),
              shouldContinue()
        else { return .init(descriptors: [], isComplete: false) }
        let allocationBytes = allocation.partialValue

        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: boundedCount)
        let returnedBytes = descriptors.withUnsafeMutableBytes { rawBuffer in
            query(pid, rawBuffer.baseAddress, Int32(allocationBytes))
        }
        guard returnedBytes >= 0 else { return .init(descriptors: [], isComplete: false) }

        var complete = shouldContinue() && reportedCount <= limits.maxFileDescriptorsPerProcess
        let returnedByteCount = Int(returnedBytes)
        if returnedByteCount > allocationBytes { complete = false }
        if returnedByteCount % stride != 0 { complete = false }
        let readableBytes = min(returnedByteCount, allocationBytes)
        let readableCount = readableBytes / stride

        var values: [ProcessFileDescriptor] = []
        values.reserveCapacity(readableCount)
        for descriptor in descriptors.prefix(readableCount) {
            guard shouldContinue() else {
                complete = false
                break
            }
            values.append(ProcessFileDescriptor(number: descriptor.proc_fd, type: descriptor.proc_fdtype))
        }
        return ProcessFileDescriptorEnumeration(descriptors: values, isComplete: complete)
    }

    private static func liveQuery(
        _ pid: Int32,
        _ buffer: UnsafeMutableRawPointer?,
        _ byteCount: Int32
    ) -> Int32 {
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer, byteCount)
    }
}
