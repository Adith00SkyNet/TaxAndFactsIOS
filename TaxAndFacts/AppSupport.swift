import SwiftUI
import UIKit
import UserNotifications
import WebKit

enum AppScreen {
    case home
    case saved
    case savedArticle
}

enum AppConfiguration {
    static let productionWebURL = URL(string: "https://taxandfacts.com/")!

    static func isProductionHomeURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == productionWebURL.host?.lowercased() else { return false }
        return url.path.isEmpty || url.path == "/"
    }

    static func isSamePage(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedURLString(lhs) == normalizedURLString(rhs)
    }

    private static func normalizedURLString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.path == "/" {
            components?.path = ""
        }
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    static func isHelpURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.host?.lowercased() == productionWebURL.host?.lowercased() else {
            return false
        }

        return url.path == "/help" ||
               url.path.hasPrefix("/help/") ||
               url.path == "/quick-guides" ||
               url.path.hasPrefix("/quick-guides/")
    }

    static func isCalculatorURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.host?.lowercased() == productionWebURL.host?.lowercased() else {
            return false
        }

        return [
            "/tax-calculator/quick/2025",
            "/tax-calculator/easy/2025",
            "/tax-calculator/2025"
        ].contains(url.path)
    }
}

struct CalculatorCaptureAlert: Identifiable {
    enum Kind {
        case info
        case scanDecision
    }

    let id = UUID()
    let title: String
    let message: String
    let kind: Kind

    static func scanDecision(documentNumber: Int, isCameraCapture: Bool) -> CalculatorCaptureAlert {
        let message: String
        if isCameraCapture {
            message = "Document \(documentNumber) was captured from the camera. If the photo is blurry or the text is not sharp, the extracted values may be less reliable. Scan another W-2 or finish to populate the calculator."
        } else {
            message = "Document \(documentNumber) was selected from your photo library. Review the extracted values before continuing."
        }

        return CalculatorCaptureAlert(
            title: "Review W-2 Capture",
            message: message,
            kind: .scanDecision
        )
    }

    static func info(title: String, message: String) -> CalculatorCaptureAlert {
        CalculatorCaptureAlert(title: title, message: message, kind: .info)
    }
}

struct SavedArticle: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let urlString: String
    let htmlString: String
    let imageURLString: String
    var imageData: Data?
    let savedDate: Date
    var isRead: Bool
}

struct CalculatorCapture: Identifiable, Codable, Equatable {
    let id: UUID
    let pageTitle: String
    let urlString: String
    let recognizedText: String
    let capturedDate: Date
}

@MainActor
@Observable
final class CalculatorCaptureManager {
    private(set) var captures: [CalculatorCapture] = []

    private let storageKey = "calculator_text_captures"

    init() {
        loadCaptures()
    }

    func saveCapture(pageTitle: String, urlString: String, recognizedText: String) {
        let capture = CalculatorCapture(
            id: UUID(),
            pageTitle: pageTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            urlString: urlString,
            recognizedText: recognizedText,
            capturedDate: Date()
        )

        captures.insert(capture, at: 0)
        saveToDisk()
    }

    private func saveToDisk() {
        if let encoded = try? JSONEncoder().encode(captures) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    private func loadCaptures() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CalculatorCapture].self, from: data) else {
            return
        }

        captures = decoded
    }
}

@MainActor
@Observable
final class ReadLaterManager {
    private(set) var articles: [SavedArticle] = []

    private let storageKey = "read_later_articles"
    private let expirationInterval: TimeInterval = 15 * 24 * 60 * 60
    private let expirationWarningInterval: TimeInterval = 14 * 24 * 60 * 60

    init() {
        loadArticles()
        cleanupExpiredArticles()
    }

    func saveArticle(title: String, urlString: String, htmlString: String, imageURLString: String, imageData: Data? = nil) {
        let cleanTitle = preferredTitle(from: title, htmlString: htmlString)
        guard !urlString.isEmpty else { return }

        if let existingIndex = articles.firstIndex(where: { $0.urlString == urlString }) {
            let existing = articles[existingIndex]
            articles[existingIndex] = SavedArticle(
                id: existing.id,
                title: cleanTitle.isEmpty ? existing.title : cleanTitle,
                urlString: urlString,
                htmlString: htmlString,
                imageURLString: imageURLString,
                imageData: imageData ?? (existing.imageURLString == imageURLString ? existing.imageData : nil),
                savedDate: Date(),
                isRead: existing.isRead
            )
            articles.move(fromOffsets: IndexSet(integer: existingIndex), toOffset: 0)
            saveToDisk()
            loadImageIfNeeded(for: existing.id, imageURLString: imageURLString)
            scheduleExpirationWarning(for: existing.id, title: cleanTitle.isEmpty ? existing.title : cleanTitle)
            return
        }

        let article = SavedArticle(
            id: UUID(),
            title: cleanTitle,
            urlString: urlString,
            htmlString: htmlString,
            imageURLString: imageURLString,
            imageData: imageData,
            savedDate: Date(),
            isRead: false
        )

        articles.insert(article, at: 0)
        saveToDisk()
        loadImageIfNeeded(for: article.id, imageURLString: imageURLString)
        scheduleExpirationWarning(for: article.id, title: cleanTitle)
    }

    func deleteArticle(id: UUID) {
        guard let index = articles.firstIndex(where: { $0.id == id }) else { return }
        let removedArticle = articles.remove(at: index)
        saveToDisk()
        cancelExpirationWarnings(ids: [removedArticle.id.uuidString])
    }

    func deleteArticles(at offsets: IndexSet) {
        let ids = offsets.map { articles[$0].id.uuidString }
        articles.remove(atOffsets: offsets)
        saveToDisk()
        cancelExpirationWarnings(ids: ids)
    }

    func deleteArticle(urlString: String) {
        guard let article = articles.first(where: { $0.urlString == urlString }) else { return }
        deleteArticle(id: article.id)
    }

    func isSaved(urlString: String) -> Bool {
        articles.contains { $0.urlString == urlString }
    }

    func setArticle(_ article: SavedArticle, isRead: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles[index].isRead = isRead
        saveToDisk()
    }

    private func preferredTitle(from title: String, htmlString: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, trimmedTitle != "Tax & Facts" {
            return trimmedTitle
        }

        let titlePatterns = [
            #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+name=["']twitter:title["'][^>]+content=["']([^"']+)["']"#,
            #"<h1[^>]*>(.*?)</h1>"#
        ]

        for pattern in titlePatterns {
            if let match = htmlString.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let matchedString = String(htmlString[match])
                if let extractedTitle = extractTitle(from: matchedString), !extractedTitle.isEmpty {
                    return extractedTitle
                }
            }
        }

        return trimmedTitle.isEmpty ? "Tax & Facts" : trimmedTitle
    }

    private func extractTitle(from htmlSnippet: String) -> String? {
        if let contentRange = htmlSnippet.range(of: #"content=["'][^"']+["']"#, options: [.regularExpression]) {
            let contentValue = htmlSnippet[contentRange]
            return contentValue
                .dropFirst("content=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return htmlSnippet
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupExpiredArticles() {
        let now = Date()
        let expiredIDs = articles
            .filter { now.timeIntervalSince($0.savedDate) >= expirationInterval }
            .map { $0.id.uuidString }

        guard !expiredIDs.isEmpty else { return }

        articles.removeAll { now.timeIntervalSince($0.savedDate) >= expirationInterval }
        saveToDisk()
        cancelExpirationWarnings(ids: expiredIDs)
    }

    private func scheduleExpirationWarning(for articleID: UUID, title: String) {
        let notificationID = articleID.uuidString
        let warningInterval = expirationWarningInterval

        Task {
            let center = UNUserNotificationCenter.current()

            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }

                center.removePendingNotificationRequests(withIdentifiers: [notificationID])

                let content = UNMutableNotificationContent()
                content.title = "Saved Reference Update"
                content.body = "\"\(title)\" will expire and be removed tomorrow."
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: warningInterval, repeats: false)
                let request = UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)
                try await center.add(request)
            } catch {
                return
            }
        }
    }

    private func cancelExpirationWarnings(ids: [String]) {
        guard !ids.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    private func loadImageIfNeeded(for articleID: UUID, imageURLString: String) {
        guard let imageURL = URL(string: imageURLString), !imageURLString.isEmpty else { return }

        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: imageURL),
                  data.count <= 2_000_000,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  httpResponse.mimeType?.hasPrefix("image/") == true else {
                return
            }

            if let index = articles.firstIndex(where: { $0.id == articleID }) {
                articles[index].imageData = data
                saveToDisk()
            }
        }
    }

    private func saveToDisk() {
        if let encoded = try? JSONEncoder().encode(articles) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }

    private func loadArticles() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SavedArticle].self, from: data) else {
            return
        }

        articles = decoded
    }
}

@MainActor
final class ResultPageCaptureController {
    weak var webView: WKWebView?

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func captureSnapshotImage() async -> UIImage? {
        guard let webView else { return nil }

        return await withCheckedContinuation { continuation in
            let visibleBounds = webView.bounds.integral
            guard !visibleBounds.isEmpty else {
                continuation.resume(returning: nil)
                return
            }

            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            configuration.rect = visibleBounds

            webView.takeSnapshot(with: configuration) { image, _ in
                if let image {
                    continuation.resume(returning: image)
                    return
                }

                let renderer = UIGraphicsImageRenderer(bounds: visibleBounds)
                let fallbackImage = renderer.image { _ in
                    webView.drawHierarchy(in: visibleBounds, afterScreenUpdates: true)
                }
                continuation.resume(returning: fallbackImage)
            }
        }
    }

    func pdfData(from image: UIImage) -> Data? {
        let renderSize = image.size
        guard renderSize.width > 0, renderSize.height > 0 else { return nil }

        let bounds = CGRect(origin: .zero, size: renderSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        return renderer.pdfData { context in
            context.beginPage()
            image.draw(in: bounds)
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct AppNavigationBar: View {
    static let height: CGFloat = 76

    let canGoBack: Bool
    let onBack: () -> Void
    let onHome: () -> Void
    let onSaved: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            navigationButton(title: "Back", systemImage: "chevron.left", action: onBack)
                .disabled(!canGoBack)
                .opacity(canGoBack ? 1 : 0.4)
            navigationButton(title: "Home", systemImage: "house", action: onHome)
            navigationButton(title: "Saved", systemImage: "bookmark", action: onSaved)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(height: Self.height)
        .background(.regularMaterial)
    }

    private func navigationButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.headline)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(title)
    }
}
