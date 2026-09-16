import Foundation

/// The feature family that owns one or more Camera Raw properties.
public enum XMPFeatureID: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case basic
    case whiteBalance
    case presence
    case hsl
    case toneCurve
    case splitToning
    case sharpening
    case noiseReduction
    case vignette
    case grain
    case monochrome
    case colorGrading
    case calibration
    case parametricCurve
    case defringe
    case pointColor
    case renderingProfile
    case lensCorrection
    case unknown
}

/// Whether a capability can be exported back to the source XMP family.
public enum XMPMappingDirection: String, Codable, Equatable, Hashable, Sendable {
    case roundTrip
    case importOnly
}

/// Process-version family used to prevent a mapping from being applied to an
/// older Adobe property family with different rendering semantics.
public enum XMPProcessVersionFamily: String, Codable, Equatable, Hashable, Sendable {
    case process2012
}

/// One declarative, reviewable compatibility claim for a group of XMP fields.
public struct XMPFeatureCapability: Codable, Equatable, Hashable, Sendable {
    public var propertyIDs: Set<XMPPropertyID>
    public var feature: XMPFeatureID
    public var processVersionFamily: XMPProcessVersionFamily
    public var level: XMPCompatibilityLevel
    public var direction: XMPMappingDirection
    public var rendererEvidenceID: String?

    public init(
        propertyIDs: Set<XMPPropertyID>,
        feature: XMPFeatureID,
        processVersionFamily: XMPProcessVersionFamily,
        level: XMPCompatibilityLevel,
        direction: XMPMappingDirection,
        rendererEvidenceID: String?
    ) {
        self.propertyIDs = propertyIDs
        self.feature = feature
        self.processVersionFamily = processVersionFamily
        self.level = level
        self.direction = direction
        self.rendererEvidenceID = rendererEvidenceID
    }
}

/// The single source of truth for what an XMP importer claims to understand.
///
/// The initializer is failable so duplicate property ownership cannot be
/// introduced accidentally when a feature converter is added.
public struct XMPCapabilityManifest: Codable, Equatable, Sendable {
    public var capabilities: [XMPFeatureCapability]

    public init?(capabilities: [XMPFeatureCapability]) {
        guard !capabilities.isEmpty,
              capabilities.allSatisfy({ !$0.propertyIDs.isEmpty }) else {
            return nil
        }

        var ownedProperties = Set<XMPPropertyID>()
        for capability in capabilities {
            guard ownedProperties.isDisjoint(with: capability.propertyIDs) else {
                return nil
            }
            ownedProperties.formUnion(capability.propertyIDs)
        }

        self.capabilities = capabilities
    }

    public func capability(for propertyID: XMPPropertyID) -> XMPFeatureCapability? {
        capabilities.first { $0.propertyIDs.contains(propertyID) }
    }

    public func capabilities(for feature: XMPFeatureID) -> [XMPFeatureCapability] {
        capabilities.filter { $0.feature == feature }
    }

    /// The P0 manifest is derived from the mappings that are actually wired
    /// into the current importer. This prevents a second, drifting list of
    /// property names while leaving room for composite feature converters to
    /// add their own entries explicitly in later phases.
    public static let `default`: XMPCapabilityManifest = {
        var grouped: [String: XMPFeatureCapability] = [:]

        for mapping in XMPMappingRegistry.default.mappings {
            let feature = mapping.field.xmpFeatureID
            let key = "\(feature.rawValue)|\(mapping.level.rawValue)"
            if var capability = grouped[key] {
                capability.propertyIDs.insert(mapping.propertyID)
                grouped[key] = capability
            } else {
                grouped[key] = XMPFeatureCapability(
                    propertyIDs: [mapping.propertyID],
                    feature: feature,
                    processVersionFamily: .process2012,
                    level: mapping.level,
                    direction: .roundTrip,
                    rendererEvidenceID: "mapping.\(feature.rawValue)"
                )
            }
        }

        var capabilities = grouped.values.sorted { lhs, rhs in
            let left = "\(lhs.feature.rawValue)|\(lhs.level.rawValue)"
            let right = "\(rhs.feature.rawValue)|\(rhs.level.rawValue)"
            return left < right
        }

        capabilities.append(XMPFeatureCapability(
            propertyIDs: [
                .cameraRaw("ToneCurvePV2012"),
                .cameraRaw("ToneCurvePV2012Red"),
                .cameraRaw("ToneCurvePV2012Green"),
                .cameraRaw("ToneCurvePV2012Blue")
            ],
            feature: .toneCurve,
            processVersionFamily: .process2012,
            level: .native,
            direction: .roundTrip,
            rendererEvidenceID: "mapping.toneCurve"
        ))
        return XMPCapabilityManifest(capabilities: capabilities)!
    }()
}
