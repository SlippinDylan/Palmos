import AppKit
import Foundation
import SwiftUI

struct AboutSettingsPane: View {
    private let metadata: AboutAppMetadata
    private let canCheckForUpdates: () -> Bool
    private let onCheckForUpdates: () -> Void

    init(
        metadata: AboutAppMetadata = .current,
        canCheckForUpdates: @escaping () -> Bool = { false },
        onCheckForUpdates: @escaping () -> Void = {}
    ) {
        self.metadata = metadata
        self.canCheckForUpdates = canCheckForUpdates
        self.onCheckForUpdates = onCheckForUpdates
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
                    Text("Palmos")
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

                Button("Check for Updates…", action: onCheckForUpdates)
                    .disabled(canCheckForUpdates() == false)

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
