import Foundation

struct HelperOccupancyEndpointResult: @unchecked Sendable {
    let data: Data?
    let error: NSError?
}

struct HelperOccupancyEndpoint: Sendable {
    private let validator: HelperOccupancyRequestValidator
    private let resolver: HelperDiskTopologyResolver
    private let scanner: HelperOccupancyScanner

    init(
        validator: HelperOccupancyRequestValidator = HelperOccupancyRequestValidator(),
        resolver: HelperDiskTopologyResolver = HelperDiskTopologyResolver(),
        scanner: HelperOccupancyScanner = HelperOccupancyScanner()
    ) {
        self.validator = validator
        self.resolver = resolver
        self.scanner = scanner
    }

    func handle(_ requestData: Data) async -> HelperOccupancyEndpointResult {
        let request: OccupancyScanRequest
        do {
            try HelperOccupancyRequestValidator.validateRequestBytes(requestData)
            request = try DrivePulseXPCMessages.decodeOccupancyRequest(from: requestData)
        } catch {
            return HelperOccupancyEndpointResult(
                data: nil,
                error: HelperOccupancyError.invalidRequest.nsError
            )
        }

        do {
            try await validator.validate(request)
            let scope = try await resolver.resolve(wholeBSDName: request.physicalDeviceBSDName)
            let response = try await scanner.scan(workflowID: request.workflowID, scope: scope)
            return HelperOccupancyEndpointResult(
                data: try DrivePulseXPCMessages.encodeOccupancyResponse(response),
                error: nil
            )
        } catch let error as HelperOccupancyError {
            return HelperOccupancyEndpointResult(data: nil, error: error.nsError)
        } catch {
            return HelperOccupancyEndpointResult(
                data: nil,
                error: HelperOccupancyError.scanFailed.nsError
            )
        }
    }
}
