import UIKit
import Vision
import ImageIO

struct RecognizedTextItem: Equatable {
    let text: String
    let boundingBox: CGRect
}

enum TextRecognizer {
    static func recognizeTextItems(in image: UIImage) async -> [RecognizedTextItem] {
        let orientation = image.cgImagePropertyOrientation

        return await Task.detached(priority: .userInitiated) {
            guard let cgImage = image.cgImage else { return [] }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: orientation,
                options: [:]
            )

            do {
                try handler.perform([request])
            } catch {
                return []
            }

            let observations = (request.results ?? []).sorted { left, right in
                let leftBox = left.boundingBox
                let rightBox = right.boundingBox

                if abs(leftBox.midY - rightBox.midY) > 0.01 {
                    return leftBox.midY > rightBox.midY
                }

                if abs(leftBox.minX - rightBox.minX) > 0.01 {
                    return leftBox.minX < rightBox.minX
                }

                return leftBox.width > rightBox.width
            }

            return observations.compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return RecognizedTextItem(text: text, boundingBox: observation.boundingBox)
            }
        }.value
    }
}

struct W2ExtractedFields: Equatable {
    let wages: String?
    let federalIncomeTaxWithheld: String?
    let medicareWagesAndTips: String?
    let stateIncomeTaxWithheld: String?
    let socialSecurityTips: String?
    let allocatedTips: String?

    var summaryText: String {
        [
            "Wages, tips, other comp: \(summaryValue(wages))",
            "Federal income tax withheld: \(summaryValue(federalIncomeTaxWithheld))",
            "Medicare wages and tips: \(summaryValue(medicareWagesAndTips))",
            "State income tax: \(summaryValue(stateIncomeTaxWithheld))",
            "Social security tips: \(summaryValue(socialSecurityTips))",
            "Allocated tips: \(summaryValue(allocatedTips))"
        ]
        .joined(separator: "\n")
    }

    var hasAnyValue: Bool {
        [wages, federalIncomeTaxWithheld, medicareWagesAndTips, stateIncomeTaxWithheld, socialSecurityTips, allocatedTips]
            .contains { value in
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    private func summaryValue(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return "—"
        }

        return value
    }
}

private extension UIImage {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up:
            return .up
        case .upMirrored:
            return .upMirrored
        case .down:
            return .down
        case .downMirrored:
            return .downMirrored
        case .left:
            return .left
        case .leftMirrored:
            return .leftMirrored
        case .right:
            return .right
        case .rightMirrored:
            return .rightMirrored
        @unknown default:
            return .up
        }
    }
}
