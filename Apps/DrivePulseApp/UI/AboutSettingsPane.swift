import AppKit
import Foundation
import SwiftUI

struct AboutSettingsPane: View {
    private let metadata: AboutAppMetadata

    init(metadata: AboutAppMetadata = .current) {
        self.metadata = metadata
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            VStack(spacing: 18) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)

                VStack(spacing: 5) {
                    Text("DrivePulse")
                        .font(.system(size: 28, weight: .bold))

                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Version %@"),
                            metadata.versionDescription
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Text("Monitor external storage health and performance at a glance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Divider()
                    .frame(width: 200)

                Text("Copyright © 2025-2026 SlippinDylan Studio")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AboutAppMetadata: Equatable {
    static var current: AboutAppMetadata {
        AboutAppMetadata(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    let shortVersion: String?
    let build: String?

    init(infoDictionary: [String: Any]) {
        shortVersion = Self.nonEmptyString(
            infoDictionary["CFBundleShortVersionString"]
        )
        build = Self.nonEmptyString(infoDictionary["CFBundleVersion"])
    }

    var versionDescription: String {
        guard let shortVersion else { return "—" }
        guard let build else { return shortVersion }
        return "\(shortVersion) (\(build))"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, value.isEmpty == false else {
            return nil
        }
        return value
    }
}
