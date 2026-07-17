import Foundation

enum XPCContractVersion {
    static let currentMajor = 1
    static let currentMinor = 5
    static let completionAwareSMARTMinor = 4
    static let smartCancellationMinor = 5
}

@objc protocol DrivePulseSMARTXPCProtocol {
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
    @objc optional func scanDiskOccupancy(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}
