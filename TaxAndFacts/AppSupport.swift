import SwiftUI
import UIKit
import Foundation
import Network
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
        case documentNotRecognized
        case duplicateDocument
        case cameraAccessDenied
        case photosAccessDenied
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

@MainActor
@Observable
final class NetworkStatusMonitor {
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "TaxAndFacts.NetworkStatusMonitor")

    private(set) var isOffline = false
    private var recoveryTask: Task<Void, Never>?

    init() {
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isOffline = path.status != .satisfied
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isOffline = isOffline
                if isOffline {
                    self.startRecoveryChecks()
                } else {
                    self.recoveryTask?.cancel()
                    self.recoveryTask = nil
                }
            }
        }

        monitor.start(queue: monitorQueue)
        isOffline = monitor.currentPath.status != .satisfied
        if isOffline {
            startRecoveryChecks()
        }
    }

    private func startRecoveryChecks() {
        guard recoveryTask == nil else { return }

        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                if await self.probeConnectivity() {
                    await MainActor.run {
                        self.isOffline = false
                        self.recoveryTask?.cancel()
                        self.recoveryTask = nil
                    }
                    return
                }
            }
        }
    }

    private func probeConnectivity() async -> Bool {
        var request = URLRequest(
            url: AppConfiguration.productionWebURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 5
        )
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200..<400).contains(httpResponse.statusCode)
        } catch {
            return false
        }
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

    private let legacyStorageKey = "read_later_articles"
    private let storageKey = "read_later_articles"
    private let storageFileName = "read_later_articles.json"
    private let expirationInterval: TimeInterval = 15 * 24 * 60 * 60
    private let expirationWarningInterval: TimeInterval = 14 * 24 * 60 * 60

    init() {
        loadArticles()
        cleanupExpiredArticles()
    }

    func saveArticle(title: String, urlString: String, htmlString: String, imageURLString: String, imageData: Data? = nil) {
        let cleanTitle = preferredTitle(from: title, htmlString: htmlString)
        let cleanedHTMLString = sanitizedArticleHTML(from: htmlString)
        guard !urlString.isEmpty else { return }

        if let existingIndex = articles.firstIndex(where: { $0.urlString == urlString }) {
            let existing = articles[existingIndex]
            articles[existingIndex] = SavedArticle(
                id: existing.id,
                title: cleanTitle.isEmpty ? existing.title : cleanTitle,
                urlString: urlString,
                htmlString: cleanedHTMLString,
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
            htmlString: cleanedHTMLString,
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

    private func sanitizedArticleHTML(from htmlString: String) -> String {
        guard !htmlString.isEmpty else { return htmlString }

        var sanitizedHTML = htmlString
        let patterns = [
            #"<header\b[^>]*>[\s\S]*?</header>"#,
            #"<footer\b[^>]*>[\s\S]*?</footer>"#,
            #"<nav\b[^>]*>[\s\S]*?</nav>"#,
            #"<aside\b[^>]*>[\s\S]*?</aside>"#,
            #"<[^>]+\b(class|id)=\"[^\"]*(?:site-header|main-header|header|site-footer|main-footer|footer|navbar|nav|breadcrumb|topbar)[^\"]*\"[^>]*>[\s\S]*?</[^>]+>"#,
            #"<[^>]+\b(role)=\"(?:banner|contentinfo)\"[^>]*>[\s\S]*?</[^>]+>"#
        ]

        for pattern in patterns {
            sanitizedHTML = sanitizedHTML.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return sanitizedHTML
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
            do {
                let fileURL = try storageURL()
                try encoded.write(to: fileURL, options: .atomic)
            } catch {
                return
            }
        }
    }

    private func loadArticles() {
        if let data = try? Data(contentsOf: storageURL()),
           let decoded = try? JSONDecoder().decode([SavedArticle].self, from: data) {
            articles = decoded
            return
        }

        guard let data = UserDefaults.standard.data(forKey: legacyStorageKey),
              let decoded = try? JSONDecoder().decode([SavedArticle].self, from: data) else {
            return
        }

        articles = decoded
        saveToDisk()
        UserDefaults.standard.removeObject(forKey: legacyStorageKey)
    }

    private func storageURL() throws -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var appDirectoryURL = applicationSupportURL.appendingPathComponent("TaxAndFacts", isDirectory: true)
        if !fileManager.fileExists(atPath: appDirectoryURL.path) {
            try fileManager.createDirectory(at: appDirectoryURL, withIntermediateDirectories: true)
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try appDirectoryURL.setResourceValues(resourceValues)
        return appDirectoryURL.appendingPathComponent(storageFileName)
    }
}

@MainActor
final class ResultPageCaptureController {
    weak var webView: WKWebView?

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    func captureResultSectionPDFData() async -> Data? {
        guard let webView else { return nil }

        let visibleBounds = webView.bounds.integral
        guard !visibleBounds.isEmpty else { return nil }

        let scrollView = webView.scrollView
        let originalOffset = scrollView.contentOffset
        let originalFrame = webView.frame
        let originalBounds = webView.bounds
        let metrics = await pageSectionMetrics(in: webView)
        guard let cropRect = metrics.cropRect else { return nil }

        let captureFrame = CGRect(
            x: originalFrame.origin.x,
            y: originalFrame.origin.y,
            width: max(originalFrame.width, metrics.pageWidth),
            height: max(originalFrame.height, metrics.pageHeight)
        )

        webView.frame = captureFrame
        webView.bounds = CGRect(origin: .zero, size: captureFrame.size)
        scrollView.setContentOffset(.zero, animated: false)
        webView.layoutIfNeeded()

        defer {
            webView.frame = originalFrame
            webView.bounds = originalBounds
            scrollView.setContentOffset(originalOffset, animated: false)
            webView.layoutIfNeeded()
        }

        let configuration = WKPDFConfiguration()
        configuration.rect = cropRect

        do {
            return try await webView.pdf(configuration: configuration)
        } catch {
            return nil
        }
    }

    func renderImage(from pdfData: Data) -> UIImage? {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let pdfDocument = CGPDFDocument(provider),
              let page = pdfDocument.page(at: 1) else {
            return nil
        }

        let pageRect = page.getBoxRect(.mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: pageRect.size, format: format)

        return renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(pageRect)

            let cgContext = context.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: pageRect.height)
            cgContext.scaleBy(x: 1, y: -1)
            cgContext.interpolationQuality = .high
            cgContext.drawPDFPage(page)
            cgContext.restoreGState()
        }
    }

    private struct PageSectionMetrics {
        let pageWidth: CGFloat
        let pageHeight: CGFloat
        let cropRect: CGRect?
    }

    private func pageSectionMetrics(in webView: WKWebView) async -> PageSectionMetrics {
        await withCheckedContinuation { continuation in
            let script = #"""
            (function() {
                function isVisible(element) {
                    if (!element) { return false; }

                    var style = window.getComputedStyle(element);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
                        return false;
                    }

                    var rects = element.getClientRects();
                    return rects.length > 0 && rects[0].width > 0 && rects[0].height > 0;
                }

                function cleanText(element) {
                    var value = [
                        element.innerText || '',
                        element.textContent || '',
                        element.getAttribute('aria-label') || '',
                        element.getAttribute('title') || '',
                        element.value || ''
                    ].join(' ');

                    return value.replace(/\s+/g, ' ').trim().toLowerCase();
                }

                function pageWidth() {
                    var body = document.body || {};
                    var doc = document.documentElement || {};
                    return Math.max(
                        body.scrollWidth || 0,
                        doc.scrollWidth || 0,
                        body.offsetWidth || 0,
                        doc.offsetWidth || 0,
                        body.clientWidth || 0,
                        doc.clientWidth || 0
                    );
                }

                function pageHeight() {
                    var body = document.body || {};
                    var doc = document.documentElement || {};
                    return Math.max(
                        body.scrollHeight || 0,
                        doc.scrollHeight || 0,
                        body.offsetHeight || 0,
                        doc.offsetHeight || 0,
                        body.clientHeight || 0,
                        doc.clientHeight || 0
                    );
                }

                function firstMatchingTop(selectors, matcher) {
                    var bestTop = null;

                    for (var i = 0; i < selectors.length; i++) {
                        var elements = document.querySelectorAll(selectors[i]);

                        for (var j = 0; j < elements.length; j++) {
                            var element = elements[j];
                            if (!isVisible(element)) { continue; }

                            var value = cleanText(element);
                            if (!matcher(value)) { continue; }

                            var rect = element.getBoundingClientRect();
                            var top = rect.top + window.scrollY;
                            if (bestTop === null || top < bestTop) {
                                bestTop = top;
                            }
                        }
                    }

                    return bestTop;
                }

                var previousTop = firstMatchingTop(
                    ['button', '[role="button"]', 'a', 'input[type="button"]', 'input[type="submit"]'],
                    function(value) { return value.indexOf('previous') !== -1; }
                );

                var pageHeightValue = pageHeight();
                var startY = 0;
                var endY = previousTop !== null ? Math.min(pageHeightValue, previousTop - 8) : pageHeightValue;

                if (endY < startY) {
                    endY = pageHeightValue;
                }

                return {
                    width: pageWidth(),
                    height: pageHeightValue,
                    startY: startY,
                    endY: endY
                };
            })();
            """#

            webView.evaluateJavaScript(script) { result, _ in
                guard let dictionary = result as? [String: Any] else {
                    continuation.resume(
                        returning: PageSectionMetrics(
                            pageWidth: webView.bounds.width,
                            pageHeight: webView.bounds.height,
                            cropRect: nil
                        )
                    )
                    return
                }

                let width = CGFloat(
                    (dictionary["width"] as? NSNumber)?.doubleValue
                    ?? (dictionary["width"] as? Double)
                    ?? webView.bounds.width
                )
                let height = CGFloat(
                    (dictionary["height"] as? NSNumber)?.doubleValue
                    ?? (dictionary["height"] as? Double)
                    ?? webView.bounds.height
                )
                let startY = CGFloat(
                    (dictionary["startY"] as? NSNumber)?.doubleValue
                    ?? (dictionary["startY"] as? Double)
                    ?? 0
                )
                let endY = CGFloat(
                    (dictionary["endY"] as? NSNumber)?.doubleValue
                    ?? (dictionary["endY"] as? Double)
                    ?? height
                )
                let cropHeight = max(1, endY - startY)
                continuation.resume(
                    returning: PageSectionMetrics(
                        pageWidth: max(1, width),
                        pageHeight: max(1, height),
                        cropRect: CGRect(
                            x: 0,
                            y: max(0, startY),
                            width: max(1, width),
                            height: cropHeight
                        )
                    )
                )
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
    let isOffline: Bool
    let onBack: () -> Void
    let onHome: () -> Void
    let onSaved: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            navigationButton(title: "Back", systemImage: "chevron.left", action: onBack)
                .disabled(!canGoBack)
                .opacity(canGoBack ? 1 : 0.4)
            navigationButton(title: "Home", systemImage: "house", action: onHome)
                .disabled(isOffline)
                .opacity(isOffline ? 0.4 : 1)
            navigationButton(title: "Read offline", systemImage: "bookmark", action: onSaved)
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
