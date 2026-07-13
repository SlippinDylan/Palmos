import Foundation

enum XPCContractVersion {
    static let currentMajor = 1
    static let currentMinor = 4
    static let completionAwareSMARTMinor = 4
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
}
