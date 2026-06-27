import Foundation

enum HelperVersionHandshake {
    static func current(bundle: Bundle = .main) -> HelperHandshake {
        HelperHandshake(
            helperVersion: helperVersion(from: bundle),
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor
        )
    }

    static func encodedCurrent(bundle: Bundle = .main) throws -> Data {
        try DrivePulseXPCMessages.encode(current(bundle: bundle))
    }

    private static func helperVersion(from bundle: Bundle) -> String {
        if let marketingVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String, marketingVersion.isEmpty == false {
            return marketingVersion
        }

        if let buildVersion = bundle.object(
            forInfoDictionaryKey: kCFBundleVersionKey as String
        ) as? String, buildVersion.isEmpty == false {
            return buildVersion
        }

        return "0"
    }
}
