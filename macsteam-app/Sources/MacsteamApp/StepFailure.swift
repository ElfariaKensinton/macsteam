import Foundation

struct StepFailure: Error, LocalizedError {
    let step: String
    let detail: String
    var errorDescription: String? { "\(step): \(detail)" }
}
