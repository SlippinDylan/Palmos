import Foundation

enum BundledSMARTCompanionReader {
    static func read(at url: URL) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= SMARTCompanionXPCLimits.binaryBytes else {
                throw HelperInstallerError.preflightFailed(
                    "The bundled smartctl companion is not a regular executable within the \(SMARTCompanionXPCLimits.binaryBytes)-byte installation limit."
                )
            }

            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.isEmpty == false,
                  data.count <= SMARTCompanionXPCLimits.binaryBytes else {
                throw HelperInstallerError.preflightFailed(
                    "The bundled smartctl companion exceeds the installation size limit."
                )
            }
            return data
        } catch let error as HelperInstallerError {
            throw error
        } catch {
            throw HelperInstallerError.preflightFailed(
                "The bundled smartctl companion could not be read at \(url.path): \(error.localizedDescription)"
            )
        }
    }
}
