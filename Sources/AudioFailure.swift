import Foundation

struct AudioFailure: Error, LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}
