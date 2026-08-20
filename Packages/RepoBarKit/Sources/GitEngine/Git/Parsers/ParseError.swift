import Foundation

public enum ParseError: Error, Sendable, Equatable {
    case malformed(String)
}
