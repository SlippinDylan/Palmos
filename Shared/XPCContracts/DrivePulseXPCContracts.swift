import Foundation

enum XPCContractVersion {
    static let currentMajor = 1
    static let currentMinor = 3
}

@objc protocol DrivePulseSMARTXPCProtocol {
    func fetchHelperHandshake(withReply reply: @escaping (Data?, NSError?) -> Void)
    func readSMARTData(
        for requestData: Data,
        withReply reply: @escaping (Data?, NSError?) -> Void
    )
}
