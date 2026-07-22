import Foundation

enum XPCContractVersion {
    static let currentMajor = 1
    static let currentMinor = 7
    static let completionAwareSMARTMinor = 4
    static let legacySMARTCancellationMinor = 5
    static let smartCancellationMinor = 6
    static let observableSMARTFailuresMinor = 6
    static let smartctlCompanionInstallationMinor = 7
}

@objc protocol PalmosSMARTXPCProtocol {
    func fetchHelperHandshake(withReply reply: @escaping (Data?, NSError?) -> Void)
    func readSMARTData(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    func readSMARTDataWithCompletion(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    @objc optional func cancelSMARTData(for requestID: String)
    @objc optional func cancelSMARTDataRequest(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    @objc optional func installSmartctlCompanion(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
    @objc optional func scanDiskOccupancy(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}
