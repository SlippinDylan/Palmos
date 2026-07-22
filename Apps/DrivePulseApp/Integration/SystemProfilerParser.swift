import Foundation

import DrivePulseCore

enum SystemProfilerParser {
    static func parse(json: [String: Any]) -> SystemProfilerCache {
        SystemProfilerCache(json: json)
    }
}

struct ThunderboltCandidate {
    let busIndex: Int
    let receptacle: Int
    let item: [String: Any]
}

extension ThunderboltCandidate {
    var isDockLike: Bool {
        let name = ((item["_name"] as? String) ?? "").lowercased()
        let deviceName = (
            (item["device_name"] as? String)
            ?? (item["device_name_key"] as? String)
            ?? ""
        ).lowercased()
        let combined = name + " " + deviceName
        return combined.contains("dock") || combined.contains("hub") || combined.contains("station")
    }

    static func sort(_ lhs: ThunderboltCandidate, _ rhs: ThunderboltCandidate) -> Bool {
        if lhs.busIndex != rhs.busIndex { return lhs.busIndex < rhs.busIndex }
        return lhs.receptacle < rhs.receptacle
    }
}

extension Array where Element == ThunderboltCandidate {
    func uniqueResolvedCandidate() -> ThunderboltCandidate? {
        guard isEmpty == false else { return nil }
        let filtered = filter { !$0.isDockLike }
        let pool = filtered.isEmpty ? self : filtered
        guard pool.count == 1 else { return nil }
        return pool.sorted(by: ThunderboltCandidate.sort).first
    }
}

extension SystemProfilerCache {
    func thunderboltCandidates() -> [ThunderboltCandidate] {
        var candidates: [ThunderboltCandidate] = []
        for (busIndex, bus) in thunderboltBuses.enumerated() {
            let children = (bus["items"] as? [[String: Any]])
                ?? (bus["Items"] as? [[String: Any]])
                ?? (bus["_items"] as? [[String: Any]])
                ?? []
            for item in children {
                let vendorName = (item["vendor_name"] as? String)
                    ?? (item["vendor_name_key"] as? String)
                    ?? ""
                guard vendorName != "Apple Inc." else { continue }
                let receptacleStr = (item["spthunderbolt_receptacle"] as? String)
                    ?? (item["receptacle"] as? String) ?? "0"
                let receptacle = Int(receptacleStr) ?? 0
                candidates.append(ThunderboltCandidate(busIndex: busIndex, receptacle: receptacle, item: item))
            }
        }
        return candidates
    }
}

struct SystemProfilerCache {
    // NVMe leaf items with an extra "__controller__" key injected
    private let nvmeEntries: [[String: Any]]
    private let pciItems: [[String: Any]]
    let thunderboltBuses: [[String: Any]]

    init(json: [String: Any]) {
        var nvme: [[String: Any]] = []
        if let buses = json["SPNVMeDataType"] as? [[String: Any]] {
            for bus in buses {
                let controllerName = bus["_name"] as? String ?? ""
                let children = (bus["items"] as? [[String: Any]])
                    ?? (bus["Items"] as? [[String: Any]])
                    ?? (bus["_items"] as? [[String: Any]])
                    ?? []
                for child in children {
                    var entry = child
                    entry["__controller__"] = controllerName
                    nvme.append(entry)
                }
                // Some controllers surface bsd_name at the bus level
                if bus["bsd_name"] != nil {
                    var entry = bus
                    entry["__controller__"] = controllerName
                    nvme.append(entry)
                }
            }
        }
        self.nvmeEntries = nvme
        self.pciItems = (json["SPPCIDataType"] as? [[String: Any]]) ?? []
        self.thunderboltBuses = (json["SPThunderboltDataType"] as? [[String: Any]]) ?? []
    }

    func nvmeInfo(forBSDName bsdName: String, modelName: String?) -> NVMeInfo? {
        let item = matchedNVMeEntry(forBSDName: bsdName, modelName: modelName)
        guard let item else { return nil }

        let controller = item["__controller__"] as? String
        let model = (item["device_model"] as? String)
            ?? (item["_name"] as? String)
            ?? (item["model"] as? String)
        let serialNumber = (item["device_serial"] as? String)
            ?? (item["spsata_serial_no"] as? String)
            ?? (item["serial_no"] as? String)
        let firmwareVersion = (item["device_revision"] as? String)
            ?? (item["spsata_revision"] as? String)
            ?? (item["revision"] as? String)
        let nvmeVersion = item["spnvme_spec_version"] as? String

        let trimRaw = item["spnvme_trim_support"] as? String
        let trimSupport: Bool? = trimRaw.map { $0 == "spnvme_yes" || $0 == "Yes" }

        let linkWidth = (item["spnvme_linkwidth"] as? String)
            ?? (item["spnvme_link_width"] as? String)
            ?? (item["link_width"] as? String)
        let linkSpeed = (item["spnvme_linkspeed"] as? String)
            ?? (item["spnvme_link_speed"] as? String)
            ?? (item["link_speed"] as? String)
        let ieeeOui = item["spnvme_ieee_oui"] as? String

        let firmwareSlots: Int?
        if let str = item["spnvme_number_of_firmware_slots"] as? String {
            firmwareSlots = Int(str)
        } else {
            firmwareSlots = item["spnvme_number_of_firmware_slots"] as? Int
        }

        let fwResetRaw = item["spnvme_fw_update_requires_reset"] as? String
        let firmwareUpdateRequiresReset: Bool? = fwResetRaw.map { $0 == "spnvme_yes" || $0 == "Yes" }

        return NVMeInfo(
            controller: controller,
            model: model,
            serialNumber: serialNumber,
            firmwareVersion: firmwareVersion,
            nvmeVersion: nvmeVersion,
            trimSupport: trimSupport,
            linkWidth: linkWidth,
            linkSpeed: linkSpeed,
            ieeeOui: ieeeOui,
            firmwareSlots: firmwareSlots,
            firmwareUpdateRequiresReset: firmwareUpdateRequiresReset
        )
    }

    func pciInfo(forNVMeSerialNumber serial: String?) -> PCIInfo? {
        guard let serial else { return nil }

        guard let item = pciItems.first(where: { item in
            let type = (item["sppci_type"] as? String) ?? (item["sppci_device_type"] as? String) ?? ""
            let serialNo = (item["serial_no"] as? String)
                ?? (item["sppci_serialnumber"] as? String)
                ?? ""
            return type.uppercased().contains("NVM") && serialNo == serial
        }) else { return nil }

        let slot = (item["sppci_slot_name"] as? String) ?? (item["sppci_slot"] as? String)
        let vendorID = (item["sppci_vendor-id"] as? String) ?? (item["sppci_vendor_id"] as? String)
        let deviceID = (item["sppci_device-id"] as? String) ?? (item["sppci_device_id"] as? String)
        let linkStatus = (item["sppci_link-status"] as? String)
            ?? (item["sppci_link_status"] as? String)
            ?? (item["link_status"] as? String)
        let tunnelRaw = (item["sppci_tunnel-compatible"] as? String)
            ?? (item["sppci_tunnel_compatible"] as? String)
            ?? (item["tunnel_compatible"] as? String)
        let tunnelCompatible: Bool? = tunnelRaw.map { $0 == "Yes" || $0 == "affirmative_string" }
        let linkWidth = (item["sppci_link-width"] as? String)
            ?? (item["sppci_link_width"] as? String)
            ?? (item["link_width"] as? String)
        let linkSpeed = (item["sppci_link-speed"] as? String)
            ?? (item["sppci_link_speed"] as? String)
            ?? (item["link_speed"] as? String)

        return PCIInfo(
            slot: slot,
            vendorID: vendorID,
            deviceID: deviceID,
            linkStatus: linkStatus,
            tunnelCompatible: tunnelCompatible,
            linkWidth: linkWidth,
            linkSpeed: linkSpeed
        )
    }

    func thunderboltInfo() -> ThunderboltInfo? {
        guard let candidate = thunderboltCandidates().uniqueResolvedCandidate() else { return nil }
        let item = candidate.item

        let vendorName = (item["vendor_name_key"] as? String) ?? (item["vendor_name"] as? String)
        let deviceName = (item["device_name_key"] as? String)
            ?? (item["device_name"] as? String)
            ?? (item["_name"] as? String)
        let mode = (item["mode_key"] as? String)
            ?? (item["spthunderbolt_mode"] as? String)
            ?? (item["thunderbolt_mode"] as? String)
            ?? (item["mode"] as? String)

        let busStr = (item["spthunderbolt_bus"] as? String) ?? (item["bus"] as? String)
        let bus = busStr.flatMap { Int($0) } ?? candidate.busIndex

        let receptacleStr = (item["spthunderbolt_receptacle"] as? String) ?? (item["receptacle"] as? String)
        let receptacle = receptacleStr.flatMap { Int($0) }

        let uid = (item["switch_uid_key"] as? String)
            ?? (item["spthunderbolt_uid"] as? String)
            ?? (item["uid"] as? String)
        let firmwareVersion = (item["switch_version_key"] as? String)
            ?? (item["spthunderbolt_fw_ver"] as? String)
            ?? (item["firmware_version"] as? String)

        let upstreamPort: [String: Any]? =
            (item["receptacle_upstream_ambiguous_tag"] as? [String: Any])
            ?? (item["receptacle_upstream_tag"] as? [String: Any])
            ?? (item["port_upstream"] as? [String: Any])
            ?? (item["Port (Upstream)"] as? [String: Any])

        let linkSpeed: String?
        if let port = upstreamPort {
            linkSpeed = (port["current_speed_key"] as? String)
                ?? (port["speed"] as? String)
                ?? (port["link_speed"] as? String)
        } else {
            linkSpeed = item["link_speed"] as? String
        }

        let linkControllerFirmwareVersion: String?
        if let port = upstreamPort {
            linkControllerFirmwareVersion = (port["lc_version_key"] as? String)
                ?? (port["link_controller_firmware_version"] as? String)
        } else {
            linkControllerFirmwareVersion = item["link_controller_firmware_version"] as? String
        }

        let upstreamPortStatus: String?
        if let port = upstreamPort {
            upstreamPortStatus = (port["receptacle_status_key"] as? String)
                ?? (port["status"] as? String)
                ?? (port["upstreamPortStatus"] as? String)
        } else {
            upstreamPortStatus = item["upstreamPortStatus"] as? String
        }

        return ThunderboltInfo(
            vendorName: vendorName,
            deviceName: deviceName,
            mode: mode,
            bus: bus,
            receptacle: receptacle,
            linkSpeed: linkSpeed,
            uid: uid,
            firmwareVersion: firmwareVersion,
            linkControllerFirmwareVersion: linkControllerFirmwareVersion,
            upstreamPortStatus: upstreamPortStatus
        )
    }

    private func matchedNVMeEntry(forBSDName bsdName: String, modelName: String?) -> [String: Any]? {
        if let exact = nvmeEntries.first(where: { ($0["bsd_name"] as? String) == bsdName }) {
            return exact
        }

        guard let modelName = normalized(modelName) else { return nil }
        let candidates = nvmeEntries.filter { item in
            guard let candidateModel = normalized(
                (item["device_model"] as? String)
                ?? (item["_name"] as? String)
                ?? (item["model"] as? String)
            ) else { return false }
            return candidateModel == modelName
                || candidateModel.contains(modelName)
                || modelName.contains(candidateModel)
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.isEmpty == false else { return nil }
        return value.lowercased()
    }
}
