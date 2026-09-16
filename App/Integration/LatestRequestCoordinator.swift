import Foundation

actor LatestRequestCoordinator {
    private var latestGeneration = 0

    func beginRequest() -> Int {
        latestGeneration += 1
        return latestGeneration
    }

    func isLatest(_ generation: Int) -> Bool {
        generation == latestGeneration
    }
}
