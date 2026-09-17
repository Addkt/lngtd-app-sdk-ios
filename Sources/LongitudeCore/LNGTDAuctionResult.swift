import Foundation

public enum LNGTDAuctionOutcome: String, Equatable, Sendable {
    case success
    case noBids
    case timeout
    case networkError
    case serverError
    case invalidAccountId
    case invalidConfigId
    case invalidSize
    case unrecognised
}

public struct LNGTDAuctionResult: Equatable, Sendable {
    public let outcome: LNGTDAuctionOutcome
    public let targetingKeywords: [String: String]?
    public let exp: Double?
    public let isLate: Bool

    public init(
        outcome: LNGTDAuctionOutcome,
        targetingKeywords: [String: String]?,
        exp: Double?,
        isLate: Bool
    ) {
        self.outcome = outcome
        self.targetingKeywords = targetingKeywords
        self.exp = exp
        self.isLate = isLate
    }
}
