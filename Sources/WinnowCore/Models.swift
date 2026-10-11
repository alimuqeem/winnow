import Foundation

/// Stable identifier for a Photos asset (`PHAsset.localIdentifier`).
public struct AssetID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public enum MediaKind: String, Sendable, Codable {
    case photo, video
}

/// What WinnowCore needs to know about an asset. Filled in by the app's
/// PhotoKit service; tests construct these directly.
public struct AssetInfo: Hashable, Sendable, Codable {
    public let id: AssetID
    public var kind: MediaKind
    public var creationDate: Date
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fileSize: Int64
    public var isFavorite: Bool
    public var hasEdits: Bool

    public init(id: AssetID, kind: MediaKind = .photo, creationDate: Date,
                pixelWidth: Int = 4032, pixelHeight: Int = 3024, fileSize: Int64 = 0,
                isFavorite: Bool = false, hasEdits: Bool = false) {
        self.id = id
        self.kind = kind
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSize = fileSize
        self.isFavorite = isFavorite
        self.hasEdits = hasEdits
    }

    public var pixelCount: Int { pixelWidth * pixelHeight }
}

/// Raw per-asset analysis signals, as cached. All values are on 0...1 except
/// `sharpness`, which is raw Laplacian variance and is normalised per group.
public struct QualitySignals: Hashable, Sendable, Codable {
    public var aesthetics: Double     // Vision overallScore mapped -1...1 -> 0...1
    public var sharpness: Double      // raw; normalised within a group
    public var faceQuality: Double?   // nil when no faces
    public var isUtility: Bool        // screenshots, receipts, documents

    public init(aesthetics: Double, sharpness: Double, faceQuality: Double? = nil, isUtility: Bool = false) {
        self.aesthetics = aesthetics
        self.sharpness = sharpness
        self.faceQuality = faceQuality
        self.isUtility = isUtility
    }
}

/// A set of visually similar assets, ordered by creation date.
public struct SimilarityGroup: Hashable, Sendable, Identifiable {
    public let members: [AssetID]
    /// Stable across regroupings as long as membership is unchanged.
    public var id: String { members.map(\.rawValue).sorted().joined(separator: "|") }

    public init(members: [AssetID]) { self.members = members }
}
