import Foundation
import Capacitor
import Vision
import UIKit

/// Reads invoice photos on the phone with Apple's Vision text recognizer (works offline).
/// Returns every piece of text with its position, size, tilt and confidence so the app
/// can rebuild the invoice table row by row.
@objc(VisionOCRPlugin)
public class VisionOCRPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "VisionOCRPlugin"
    public let jsName = "VisionOCR"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "recognize", returnType: CAPPluginReturnPromise)
    ]

    @objc func isAvailable(_ call: CAPPluginCall) {
        call.resolve(["value": true])
    }

    @objc func recognize(_ call: CAPPluginCall) {
        guard let input = call.getString("image") else {
            call.reject("No image")
            return
        }
        var words: [String] = []
        if let arr = call.getArray("words") {
            for v in arr {
                if let s = v as? String { words.append(s) }
            }
        }
        let correct = call.getBool("correct") ?? true

        DispatchQueue.global(qos: .userInitiated).async {
            var base64 = input
            if let comma = input.firstIndex(of: ",") {
                base64 = String(input[input.index(after: comma)...])
            }
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  let image = UIImage(data: data),
                  let cg = image.cgImage else {
                call.reject("Could not open the image")
                return
            }
            let pw = Double(cg.width)
            let ph = Double(cg.height)

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = correct
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.006
            if correct && !words.isEmpty {
                request.customWords = Array(words.prefix(400))
            }

            let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                call.reject("Reading failed: \(error.localizedDescription)")
                return
            }

            var items: [[String: Any]] = []
            let results: [VNRecognizedTextObservation] = request.results ?? []
            for obs in results {
                guard let best = obs.topCandidates(1).first else { continue }
                // Vision points are 0...1 with the origin bottom-left; convert to pixels, origin top-left
                let tlx = Double(obs.topLeft.x) * pw, tly = (1.0 - Double(obs.topLeft.y)) * ph
                let trx = Double(obs.topRight.x) * pw, tryy = (1.0 - Double(obs.topRight.y)) * ph
                let blx = Double(obs.bottomLeft.x) * pw, bly = (1.0 - Double(obs.bottomLeft.y)) * ph
                let brx = Double(obs.bottomRight.x) * pw, bry = (1.0 - Double(obs.bottomRight.y)) * ph
                let cx = (tlx + trx + blx + brx) / 4.0
                let cy = (tly + tryy + bly + bry) / 4.0
                let w = ((trx - tlx) * (trx - tlx) + (tryy - tly) * (tryy - tly)).squareRoot()
                let h = ((blx - tlx) * (blx - tlx) + (bly - tly) * (bly - tly)).squareRoot()
                let angle = atan2(bry - bly, brx - blx)
                var item: [String: Any] = [:]
                item["t"] = best.string
                item["c"] = Double(best.confidence)
                item["x"] = cx
                item["y"] = cy
                item["w"] = w
                item["h"] = h
                item["a"] = angle
                items.append(item)
            }
            call.resolve(["items": items, "width": pw, "height": ph])
        }
    }
}
