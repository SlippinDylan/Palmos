import XCTest

@testable import DrivePulseApp

final class SystemProfilerParserBoundaryTests: XCTestCase {
    func testParserOwnsJSONNormalizationBoundary() {
        let cache = SystemProfilerParser.parse(json: [
            "SPPCIDataType": [[
                "sppci_type": "NVMe",
                "serial_no": "SERIAL-13",
                "sppci_slot_name": "slot-1"
            ]]
        ])

        XCTAssertEqual(cache.pciInfo(forNVMeSerialNumber: "SERIAL-13")?.slot, "slot-1")
    }
}
