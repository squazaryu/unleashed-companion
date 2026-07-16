import CoreLocation
import Foundation

enum WiFiMapperAPConfidence: String {
    case low
    case medium
    case high

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var sortRank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}

struct WiFiMapperAPEstimate: Identifiable, Equatable {
    let id: String
    let ssid: String
    let bssid: String
    let channel: Int?
    let coordinate: CLLocationCoordinate2D
    let observationCount: Int
    let strongestRSSI: Int
    let averageRSSI: Int
    let radiusMeters: Double
    let maxSpreadMeters: Double
    let averageAccuracyMeters: Double?
    let confidence: WiFiMapperAPConfidence

    var displaySSID: String { ssid.isEmpty ? "<hidden>" : ssid }

    static func == (lhs: WiFiMapperAPEstimate, rhs: WiFiMapperAPEstimate) -> Bool {
        lhs.id == rhs.id &&
            lhs.ssid == rhs.ssid &&
            lhs.bssid == rhs.bssid &&
            lhs.channel == rhs.channel &&
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude &&
            lhs.observationCount == rhs.observationCount &&
            lhs.strongestRSSI == rhs.strongestRSSI &&
            lhs.averageRSSI == rhs.averageRSSI &&
            lhs.radiusMeters == rhs.radiusMeters &&
            lhs.maxSpreadMeters == rhs.maxSpreadMeters &&
            lhs.averageAccuracyMeters == rhs.averageAccuracyMeters &&
            lhs.confidence == rhs.confidence
    }
}

enum WiFiMapperAPEstimator {
    static let defaultMinimumObservations = 3

    static func estimates(
        from points: [WiFiMapperPoint],
        minimumObservations: Int = defaultMinimumObservations
    ) -> [WiFiMapperAPEstimate] {
        let grouped = Dictionary(grouping: points) { $0.bssid.uppercased() }

        return grouped
            .compactMap { bssid, observations -> WiFiMapperAPEstimate? in
                guard !bssid.isEmpty else { return nil }
                return estimate(
                    bssid: bssid,
                    observations: observations,
                    minimumObservations: minimumObservations)
            }
            .sorted { lhs, rhs in
                if lhs.confidence.sortRank != rhs.confidence.sortRank {
                    return lhs.confidence.sortRank > rhs.confidence.sortRank
                }
                if lhs.observationCount != rhs.observationCount {
                    return lhs.observationCount > rhs.observationCount
                }
                return lhs.strongestRSSI > rhs.strongestRSSI
            }
    }

    private static func estimate(
        bssid: String,
        observations: [WiFiMapperPoint],
        minimumObservations: Int
    ) -> WiFiMapperAPEstimate? {
        let usable = observations.compactMap { point -> WeightedObservation? in
            guard let rssi = point.primaryRSSI else { return nil }
            return WeightedObservation(point: point, rssi: rssi, weight: weight(for: point, rssi: rssi))
        }

        guard usable.count >= minimumObservations else { return nil }

        let reference = usable[0].point.coordinate
        let projection = LocalProjection(reference: reference)
        let totalWeight = usable.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }

        var weightedX = 0.0
        var weightedY = 0.0
        var weightedRSSI = 0.0
        var weightedAccuracy = 0.0
        var accuracyWeight = 0.0

        for item in usable {
            let projected = projection.project(item.point.coordinate)
            weightedX += projected.x * item.weight
            weightedY += projected.y * item.weight
            weightedRSSI += Double(item.rssi) * item.weight

            if let accuracy = item.point.accuracy, accuracy > 0 {
                weightedAccuracy += accuracy * item.weight
                accuracyWeight += item.weight
            }
        }

        let estimatePoint = ProjectedPoint(x: weightedX / totalWeight, y: weightedY / totalWeight)
        let coordinate = projection.coordinate(from: estimatePoint)
        let radius = confidenceRadius(
            usable: usable,
            projection: projection,
            estimatePoint: estimatePoint,
            totalWeight: totalWeight,
            averageAccuracy: accuracyWeight > 0 ? weightedAccuracy / accuracyWeight : nil)
        let maxSpread = usable
            .map { projection.distance(from: $0.point.coordinate, to: coordinate) }
            .max() ?? 0
        let strongest = usable.max { $0.rssi < $1.rssi }!
        let averageRSSI = Int((weightedRSSI / totalWeight).rounded())
        let averageAccuracy = accuracyWeight > 0 ? weightedAccuracy / accuracyWeight : nil
        let confidence = confidence(
            observationCount: usable.count,
            radiusMeters: radius,
            maxSpreadMeters: maxSpread,
            averageAccuracyMeters: averageAccuracy,
            strongestRSSI: strongest.rssi)

        return WiFiMapperAPEstimate(
            id: bssid,
            ssid: strongest.point.ssid,
            bssid: bssid,
            channel: strongest.point.channel,
            coordinate: coordinate,
            observationCount: usable.count,
            strongestRSSI: strongest.rssi,
            averageRSSI: averageRSSI,
            radiusMeters: radius,
            maxSpreadMeters: maxSpread,
            averageAccuracyMeters: averageAccuracy,
            confidence: confidence)
    }

    private static func weight(for point: WiFiMapperPoint, rssi: Int) -> Double {
        let signal = min(max((Double(rssi) + 100.0) / 70.0, 0.05), 1.0)
        let sampleWeight = sqrt(Double(max(point.samples ?? 1, 1))).clamped(to: 1.0 ... 4.0)
        let accuracyWeight: Double
        if let accuracy = point.accuracy, accuracy > 0 {
            accuracyWeight = (30.0 / max(accuracy, 3.0)).clamped(to: 0.25 ... 2.0)
        } else {
            accuracyWeight = 1.0
        }
        return pow(signal, 3.0) * sampleWeight * accuracyWeight
    }

    private static func confidenceRadius(
        usable: [WeightedObservation],
        projection: LocalProjection,
        estimatePoint: ProjectedPoint,
        totalWeight: Double,
        averageAccuracy: Double?
    ) -> Double {
        let weightedVariance = usable.reduce(0.0) { partial, item in
            let projected = projection.project(item.point.coordinate)
            let distanceSquared = pow(projected.x - estimatePoint.x, 2.0) +
                pow(projected.y - estimatePoint.y, 2.0)
            return partial + distanceSquared * item.weight
        } / totalWeight

        let observationPenalty = 1.0 + max(0.0, Double(5 - usable.count)) * 0.15
        return (sqrt(weightedVariance) + (averageAccuracy ?? 12.0)) * observationPenalty
    }

    private static func confidence(
        observationCount: Int,
        radiusMeters: Double,
        maxSpreadMeters: Double,
        averageAccuracyMeters: Double?,
        strongestRSSI: Int
    ) -> WiFiMapperAPConfidence {
        let averageAccuracy = averageAccuracyMeters ?? 20.0

        if observationCount >= 8 &&
            radiusMeters <= 30 &&
            maxSpreadMeters >= 20 &&
            averageAccuracy <= 15 &&
            strongestRSSI >= -62 {
            return .high
        }

        if observationCount >= 4 &&
            radiusMeters <= 75 &&
            maxSpreadMeters >= 8 &&
            averageAccuracy <= 35 {
            return .medium
        }

        return .low
    }
}

private struct WeightedObservation {
    let point: WiFiMapperPoint
    let rssi: Int
    let weight: Double
}

private struct ProjectedPoint {
    let x: Double
    let y: Double
}

private struct LocalProjection {
    let reference: CLLocationCoordinate2D
    let metersPerDegreeLatitude = 111_320.0
    let metersPerDegreeLongitude: Double

    init(reference: CLLocationCoordinate2D) {
        self.reference = reference
        metersPerDegreeLongitude = 111_320.0 * cos(reference.latitude * .pi / 180.0)
    }

    func project(_ coordinate: CLLocationCoordinate2D) -> ProjectedPoint {
        ProjectedPoint(
            x: (coordinate.longitude - reference.longitude) * metersPerDegreeLongitude,
            y: (coordinate.latitude - reference.latitude) * metersPerDegreeLatitude)
    }

    func coordinate(from point: ProjectedPoint) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: reference.latitude + point.y / metersPerDegreeLatitude,
            longitude: reference.longitude + point.x / metersPerDegreeLongitude)
    }

    func distance(from lhs: CLLocationCoordinate2D, to rhs: CLLocationCoordinate2D) -> Double {
        let a = project(lhs)
        let b = project(rhs)
        return hypot(a.x - b.x, a.y - b.y)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
