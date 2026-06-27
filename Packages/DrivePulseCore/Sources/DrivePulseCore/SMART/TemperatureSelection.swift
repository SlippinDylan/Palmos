public enum TemperatureSelection {
    public static func overviewTemperature(for smartData: SmartData) -> Int? {
        smartData.highestTemperature
            ?? smartData.sensorTemperatures.values.max()
            ?? smartData.primaryTemperature
    }
}
