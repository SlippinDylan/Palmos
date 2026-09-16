import Foundation

enum HelperVersionHandshake {
    static func current(
        bundle: Bundle = .main,
        smartctlCompanionAvailable: Bool? = nil
    ) -> HelperHandshake {
        HelperHandshake(
            helperVersion: helperVersion(from: bundle),
            contractMajor: XPCContractVersion.currentMajor,
            contractMinor: XPCContractVersion.currentMinor,
            smartctlCompanionAvailable: smartctlCompanionAvailable
        )
    }

    static func encodedCurrent(
        bundle: Bundle = .main,
        smartctlCompanionAvailable: Bool? = nil
    ) throws -> Data {
        try PalmosXPCMessages.encode(current(
            bundle: bundle,
            smartctlCompanionAvailable: smartctlCompanionAvailable
        ))
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
