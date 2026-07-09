import SwiftUI
import UIKit
import WebKit
import UserNotifications
import Vision
import ImageIO
import PhotosUI

struct ContentView: View {
    @State private var readLaterManager = ReadLaterManager()
    @State private var selectedScreen: AppScreen = .home
    @State private var webURL = AppConfiguration.productionWebURL
    @State private var webHistory: [URL] = []
    @State private var isRestoringWebHistory = false
    @State private var canGoBack = false
    @State private var backRequestID = 0
    @State private var isOffline = false
    @State private var selectedSavedArticle: SavedArticle?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedScreen {
                case .home:
                    HomeTabContainer(
                        manager: readLaterManager,
                        url: $webURL,
                        isOffline: $isOffline,
                        canGoBack: $canGoBack,
                        backRequestID: $backRequestID,
                        onNavigationFinished: handleWebNavigation
                    )
                case .saved:
                    SavedContentView(
                        manager: readLaterManager,
                        isOffline: isOffline,
                        onOpen: openSavedArticle
                    )
                case .savedArticle:
                    if let selectedSavedArticle {
                        SavedArticleDetailView(article: selectedSavedArticle)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            AppNavigationBar(
                canGoBack: selectedScreen == .saved || selectedScreen == .savedArticle || canNavigateBackInHome,
                onBack: goBack,
                onHome: showHome,
                onSaved: showSaved
            )
        }
        .onChange(of: isOffline) { _, newValue in
            if newValue {
                selectedScreen = .saved
            }
        }
    }

    private func goBack() {
        if selectedScreen == .savedArticle {
            selectedSavedArticle = nil
            selectedScreen = .saved
            return
        }

        if selectedScreen == .saved {
            selectedScreen = .home
            return
        }

        guard canNavigateBackInHome else { return }

        if canGoBack {
            isRestoringWebHistory = true
            backRequestID += 1
            return
        }

        if let previousURL = webHistory.popLast() {
            isRestoringWebHistory = true
            webURL = previousURL
        }
    }

    private func showHome() {
        selectedScreen = .home
        webURL = AppConfiguration.productionWebURL
        webHistory.removeAll()
        canGoBack = false
    }

    private func showSaved() {
        selectedScreen = .saved
    }

    private func openSavedArticle(_ article: SavedArticle) {
        if isOffline {
            selectedSavedArticle = article
            selectedScreen = .savedArticle
            return
        }

        guard let url = URL(string: article.urlString) else { return }
        webURL = url
        selectedScreen = .home
    }

    private var canNavigateBackInHome: Bool {
        guard !AppConfiguration.isProductionHomeURL(webURL) else { return false }
        return canGoBack || !webHistory.isEmpty
    }

    private func handleWebNavigation(to currentURL: URL, webViewCanGoBack: Bool) {
        defer {
            webURL = currentURL
            canGoBack = webViewCanGoBack
        }

        guard !AppConfiguration.isSamePage(currentURL, webURL) else { return }

        if isRestoringWebHistory {
            isRestoringWebHistory = false
            return
        }

        webHistory.append(webURL)
    }
}

private enum AppScreen {
    case home
    case saved
    case savedArticle
}

private enum AppConfiguration {
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
               url.path.hasPrefix("/quick-guides/")    }

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

private struct HomeTabContainer: View {
    let manager: ReadLaterManager
    @Binding var url: URL
    @Binding var isOffline: Bool
    @Binding var canGoBack: Bool
    @Binding var backRequestID: Int
    let onNavigationFinished: (URL, Bool) -> Void
    @State private var currentTitle = "Tax & Facts"
    @State private var currentURLString = ""
    @State private var currentHTMLString = ""
    @State private var currentImageURLString = ""
    @State private var captureManager = CalculatorCaptureManager()
    @State private var pendingW2Fields: W2ExtractedFields?
    @State private var w2PopulateRequestID = 0
    @State private var isShowingCamera = false
    @State private var isShowingPhotoLibrary = false
    @State private var isShowingCaptureOptions = false
    @State private var isRecognizingText = false
    @State private var isCalculatorStep2 = false
    @State private var captureAlert: CalculatorCaptureAlert?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isOffline {
                ContentUnavailableView(
                    "You are Offline",
                    systemImage: "wifi.slash",
                    description: Text("You can still review saved Tax & Facts references from the Saved tab.")
                )
            } else {
                NativeWebViewWrapper(
                    url: $url,
                    isOffline: $isOffline,
                    currentTitle: $currentTitle,
                    currentURLString: $currentURLString,
                    currentHTMLString: $currentHTMLString,
                    currentImageURLString: $currentImageURLString,
                    pendingW2Fields: $pendingW2Fields,
                    w2PopulateRequestID: $w2PopulateRequestID,
                    canGoBack: $canGoBack,
                    backRequestID: $backRequestID,
                    isCalculatorStep2: $isCalculatorStep2,
                    onNavigationFinished: onNavigationFinished
                )

                if AppConfiguration.isHelpURL(currentURLString) {
                    SavePageToggleButton(
                        isSaved: manager.isSaved(urlString: currentURLString),
                        action: toggleSavedPage
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 18)
                }

                if AppConfiguration.isCalculatorURL(currentURLString), isCalculatorStep2 {
                    CalculatorScanButton(
                        isProcessing: isRecognizingText,
                        action: showCaptureOptions
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 18)
                }
            }
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraCaptureView(onImageCaptured: processCapturedImage)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingPhotoLibrary) {
            PhotoLibraryCaptureView(onImageCaptured: processCapturedImage)
        }
        .confirmationDialog("Scan W-2", isPresented: $isShowingCaptureOptions, titleVisibility: .visible) {
            Button {
                openCamera()
            } label: {
                Label("Scanner", systemImage: "camera.fill")
            }

            Button {
                openPhotoLibrary()
            } label: {
                Label("Upload from Gallery", systemImage: "photo.on.rectangle")
            }
        }
        .alert(item: $captureAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func showCaptureOptions() {
        isShowingCaptureOptions = true
    }

    private func toggleSavedPage() {
        if manager.isSaved(urlString: currentURLString) {
            manager.deleteArticle(urlString: currentURLString)
        } else {
            manager.saveArticle(
                title: currentTitle,
                urlString: currentURLString,
                htmlString: currentHTMLString,
                imageURLString: currentImageURLString
            )
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            captureAlert = CalculatorCaptureAlert(
                title: "Camera Unavailable",
                message: "This device does not have an available camera."
            )
            return
        }

        isShowingCamera = true
    }

    private func openPhotoLibrary() {
        isShowingPhotoLibrary = true
    }

    private func processCapturedImage(_ image: UIImage) {
        isShowingCamera = false
        isShowingPhotoLibrary = false
        isRecognizingText = true

        Task {
            let recognizedItems = await TextRecognizer.recognizeTextItems(in: image)
            let recognizedText = recognizedItems
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let extractedFields = W2FieldExtractor.extractFields(from: recognizedText, items: recognizedItems)
            let captureText = extractedFields.summaryText

            await MainActor.run {
                if extractedFields.hasAnyValue {
                    captureManager.saveCapture(
                        pageTitle: currentTitle,
                        urlString: currentURLString,
                        recognizedText: captureText
                    )

                    if AppConfiguration.isCalculatorURL(currentURLString), isCalculatorStep2 {
                        pendingW2Fields = extractedFields
                        w2PopulateRequestID += 1
                    }
                }

                isRecognizingText = false
                captureAlert = CalculatorCaptureAlert(
                    title: captureAlertTitle(recognizedText: recognizedText, extractedFields: extractedFields),
                    message: captureAlertMessage(recognizedText: recognizedText, extractedFields: extractedFields)
                )
            }
        }
    }

    private func captureAlertTitle(recognizedText: String, extractedFields: W2ExtractedFields) -> String {
        if recognizedText.isEmpty {
            return "No Text Found"
        }

        return extractedFields.hasAnyValue ? "W-2 Fields Saved" : "No W-2 Fields Found"
    }

    private func captureAlertMessage(recognizedText: String, extractedFields: W2ExtractedFields) -> String {
        if recognizedText.isEmpty {
            return "No readable text was detected."
        }

        if !extractedFields.hasAnyValue {
            return "Readable text was found, but none of the required W-2 fields were detected."
        }

        return extractedFields.summaryText
    }

    private func previewMessage(for text: String) -> String {
        let previewLimit = 280
        if text.count <= previewLimit {
            return text
        }

        return String(text.prefix(previewLimit)) + "..."
    }
}

private struct NativeWebViewWrapper: UIViewRepresentable {
    @Binding var url: URL
    @Binding var isOffline: Bool
    @Binding var currentTitle: String
    @Binding var currentURLString: String
    @Binding var currentHTMLString: String
    @Binding var currentImageURLString: String
    @Binding var pendingW2Fields: W2ExtractedFields?
    @Binding var w2PopulateRequestID: Int
    @Binding var canGoBack: Bool
    @Binding var backRequestID: Int
    @Binding var isCalculatorStep2: Bool
    let onNavigationFinished: (URL, Bool) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.calculatorStepMessageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.allowsBackForwardNavigationGestures = true
        webView.load(request(for: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.handledBackRequestID != backRequestID {
            context.coordinator.handledBackRequestID = backRequestID
            DispatchQueue.main.async {
                if uiView.canGoBack {
                    uiView.goBack()
                }
                self.canGoBack = uiView.canGoBack
            }
            return
        }

        if context.coordinator.loadedURL != url {
            uiView.load(request(for: url))
            context.coordinator.loadedURL = url
        }

        context.coordinator.installW2FieldPrefillSupport(into: uiView)
        DispatchQueue.main.async {
            context.coordinator.attemptW2FieldPrefill(in: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func request(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let calculatorStepMessageName = "calculatorStep"

        var parent: NativeWebViewWrapper
        var loadedURL: URL?
        var handledBackRequestID = 0
        var handledW2PopulateRequestID = -1
        var w2PrefillRetryTimer: Timer?
        var w2PrefillRetryCount = 0
        let w2PrefillRetryLimit = 10

        init(_ parent: NativeWebViewWrapper) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isOffline = false
            parent.currentTitle = cleanTitle(webView.title)
            parent.currentURLString = webView.url?.absoluteString ?? ""
            parent.canGoBack = webView.canGoBack

            if let currentURL = webView.url {
                loadedURL = currentURL
                parent.onNavigationFinished(currentURL, webView.canGoBack)
            }

            updateCurrentPageTitle(from: webView)
            updateCurrentHTML(from: webView)
            updateCurrentImageURL(from: webView)
            injectNativeShellCSS(into: webView)
            updateCalculatorStepState(in: webView)
            installW2FieldPrefillSupport(into: webView)
            attemptW2FieldPrefill(in: webView)
            resetScrollPosition(in: webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.canGoBack = webView.canGoBack
            parent.isCalculatorStep2 = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationError(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleNavigationError(error)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == Self.calculatorStepMessageName {
                if let isStep2 = message.body as? Bool {
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.isCalculatorStep2 = isStep2
                    }
                }
                return
            }
        }

        private func handleNavigationError(_ error: Error) {
            let nsError = error as NSError
            let offlineCodes: Set<Int> = [
                NSURLErrorNotConnectedToInternet,
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost
            ]

            if offlineCodes.contains(nsError.code) {
                parent.isOffline = true
            }
        }

        private func cleanTitle(_ title: String?) -> String {
            guard let title else { return "Tax & Facts" }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else { return "Tax & Facts" }

            return trimmedTitle
        }

        private func updateCurrentPageTitle(from webView: WKWebView) {
            let script = """
            (function() {
                var selectors = [
                    'meta[property="og:title"]',
                    'meta[name="twitter:title"]',
                    'article h1',
                    'main h1',
                    'h1'
                ];

                for (var i = 0; i < selectors.length; i++) {
                    var element = document.querySelector(selectors[i]);
                    var value = element ? (element.getAttribute('content') || element.textContent || '') : '';
                    value = value.trim();
                    if (value) { return value; }
                }

                return document.title || '';
            })();
            """

            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                self.parent.currentTitle = self.cleanTitle(result as? String)
            }
        }

        private func updateCurrentHTML(from webView: WKWebView) {
            webView.evaluateJavaScript("document.documentElement.outerHTML.toString()") { [weak self] result, _ in
                guard let self, let html = result as? String else { return }
                self.parent.currentHTMLString = html
            }
        }

        private func updateCurrentImageURL(from webView: WKWebView) {
            let script = """
            (function() {
                var selector = 'meta[property="og:image"], meta[name="twitter:image"], article img, main img, img';
                var element = document.querySelector(selector);
                var value = element ? (element.getAttribute('content') || element.getAttribute('src') || '') : '';
                if (!value) { return ''; }
                return new URL(value, document.baseURI).href;
            })();
            """

            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self, let imageURLString = result as? String else { return }
                self.parent.currentImageURLString = imageURLString
            }
        }

        private func updateCalculatorStepState(in webView: WKWebView) {
            let currentURLString = webView.url?.absoluteString ?? ""
            guard AppConfiguration.isCalculatorURL(currentURLString) else {
                parent.isCalculatorStep2 = false
                return
            }

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
                        element.getAttribute('title') || ''
                    ].join(' ');

                    return value.replace(/\s+/g, ' ').trim().toLowerCase();
                }

                function containsStepTwo(value) {
                    return /\bstep\s*2\b/.test(value) ||
                           /\b2\s*(of|\/)\s*\d+\b/.test(value) ||
                           value === '2';
                }

                function isW2IncomeScreen() {
                    var pageText = (document.body ? document.body.innerText : '')
                        .replace(/\s+/g, ' ')
                        .trim()
                        .toLowerCase();

                    return pageText.includes('w-2 income') &&
                           (
                               pageText.includes('your income') ||
                               pageText.includes('your / your spouse income') ||
                               pageText.includes('wages, tips, other comp') ||
                               pageText.includes('wages, tips, other compensation') ||
                               pageText.includes('wages, tips, other compensations') ||
                               pageText.includes('add another w2')
                           );
                }

                function detectStepTwo() {
                    if (isW2IncomeScreen()) {
                        return true;
                    }

                    var activeSelectors = [
                        '[aria-current="step"]',
                        '[aria-current="page"]',
                        '[aria-selected="true"]',
                        '[data-state="active"]',
                        '[data-active="true"]',
                        '.active',
                        '.current',
                        '.selected'
                    ];

                    for (var i = 0; i < activeSelectors.length; i++) {
                        var activeElements = document.querySelectorAll(activeSelectors[i]);

                        for (var j = 0; j < activeElements.length; j++) {
                            if (isVisible(activeElements[j]) && containsStepTwo(cleanText(activeElements[j]))) {
                                return true;
                            }
                        }
                    }

                    var visibleHeadings = document.querySelectorAll('h1, h2, h3, h4, legend, [role="heading"]');
                    for (var k = 0; k < visibleHeadings.length; k++) {
                        if (isVisible(visibleHeadings[k]) && containsStepTwo(cleanText(visibleHeadings[k]))) {
                            return true;
                        }
                    }

                    return false;
                }

                function reportStep() {
                    window.webkit.messageHandlers.calculatorStep.postMessage(detectStepTwo());
                }

                if (!window.__taxFactsCalculatorStepObserverInstalled) {
                    window.__taxFactsCalculatorStepObserverInstalled = true;
                    window.__taxFactsReportCalculatorStep = reportStep;

                    var scheduleReport = function() {
                        window.clearTimeout(window.__taxFactsCalculatorStepReportTimer);
                        window.__taxFactsCalculatorStepReportTimer = window.setTimeout(reportStep, 80);
                    };

                    var observer = new MutationObserver(scheduleReport);
                    observer.observe(document.body || document.documentElement, {
                        attributes: true,
                        childList: true,
                        subtree: true
                    });

                    ['click', 'input', 'change', 'hashchange', 'popstate'].forEach(function(eventName) {
                        window.addEventListener(eventName, scheduleReport, true);
                    });
                }

                window.__taxFactsReportCalculatorStep = reportStep;
                reportStep();
                window.setTimeout(reportStep, 250);
                window.setTimeout(reportStep, 750);
            })();
            """#

            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func installW2FieldPrefillSupport(into webView: WKWebView) {
            let script = #"""
            (function() {
                if (window.__taxFactsW2PrefillInstalled) {
                    return;
                }

                function isVisible(element) {
                    if (!element) { return false; }

                    var style = window.getComputedStyle(element);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
                        return false;
                    }

                    var rects = element.getClientRects();
                    return rects.length > 0 && rects[0].width > 0 && rects[0].height > 0;
                }

                function normalize(value) {
                    return (value || '')
                        .toLowerCase()
                        .replace(/[^a-z0-9]+/g, ' ')
                        .replace(/\s+/g, ' ')
                        .trim();
                }

                function normalizeKey(value) {
                    return normalize((value || '').replace(/([a-z0-9])([A-Z])/g, '$1 $2'));
                }

                function allDocuments(rootDocument) {
                    var docs = [];

                    function visit(doc) {
                        if (!doc || docs.indexOf(doc) !== -1) {
                            return;
                        }

                        docs.push(doc);

                        var frames = [];
                        try {
                            frames = Array.from(doc.querySelectorAll('iframe'));
                        } catch (error) {
                            return;
                        }

                        for (var i = 0; i < frames.length; i += 1) {
                            try {
                                var frameDoc = frames[i].contentDocument;
                                if (frameDoc) {
                                    visit(frameDoc);
                                }
                            } catch (error) {
                                // Ignore cross-origin frames.
                            }
                        }
                    }

                    visit(rootDocument || document);
                    return docs;
                }

                function queryAllAcrossDocuments(selector) {
                    var results = [];
                    var docs = allDocuments(document);

                    for (var i = 0; i < docs.length; i += 1) {
                        try {
                            results = results.concat(Array.from(docs[i].querySelectorAll(selector)));
                        } catch (error) {
                            // Ignore documents we cannot inspect.
                        }
                    }

                    return results;
                }

                function fieldDefinitions() {
                    return [
                        {
                            key: 'wages',
                            modelName: 'wage',
                            ngModelPath: 'w2.wage',
                            exactMatchers: ['t01', 'w2.wage', 'Wages, Tips, Other compensations'],
                            patterns: [
                                'w2 wages tips other compensations',
                                'w2 wages tips other compensation',
                                'wages tips other compensations',
                                'wages tips other compensation',
                                'wages tips and other compensation',
                                'your income'
                            ]
                        },
                        {
                            key: 'federalIncomeTaxWithheld',
                            modelName: 'federal',
                            ngModelPath: 'w2.federal',
                            exactMatchers: ['w2.federal', 'Federal Income tax withheld'],
                            patterns: [
                                'federal income tax withheld',
                                'federal income tax with held',
                                'federal tax withheld',
                                'federal tax with held',
                                'box 2 federal income tax withheld',
                                'box 2 federal income tax',
                                'box 2',
                                'income tax withheld',
                                'federal withholding'
                            ]
                        },
                        {
                            key: 'medicareWagesAndTips',
                            modelName: 'medicareWages',
                            ngModelPath: 'w2.medicareWages',
                            exactMatchers: ['w2.medicareWages', 'Medicare Wages & Tips'],
                            patterns: [
                                'medicare wages and tips',
                                'medicare wages tips',
                                'medicare wages'
                            ]
                        },
                        {
                            key: 'stateIncomeTaxWithheld',
                            modelName: 'state',
                            ngModelPath: 'w2.state',
                            exactMatchers: ['w2.state', 'State Income Tax withheld'],
                            patterns: [
                                'state income tax withheld',
                                'state income tax with held',
                                'state income tax',
                                'state tax withheld',
                                'state tax',
                                'state withholding',
                                'box 17 state income tax withheld',
                                'box 17 state income tax',
                                '17 state income tax withheld',
                                '17 state income tax'
                            ]
                        },
                        {
                            key: 'socialSecurityTips',
                            modelName: 'sectip',
                            ngModelPath: 'w2.sectip',
                            exactMatchers: ['w2.sectip', 'Social Security Tip'],
                            patterns: [
                                'social security tip',
                                'social security tips'
                            ]
                        },
                        {
                            key: 'allocatedTips',
                            modelName: 'allotip',
                            ngModelPath: 'w2.allotip',
                            exactMatchers: ['w2.allotip', 'Allocated Tip'],
                            patterns: [
                                'allocated tip',
                                'allocated tips'
                            ]
                        }
                    ];
                }

                function definitionSearchTerms(definition) {
                    var terms = definition.patterns.slice();
                    terms.push(normalizeKey(definition.key));
                    return terms.filter(function(term) { return term.length > 0; });
                }

                function elementText(element) {
                    if (!element) { return ''; }

                    return [
                        element.getAttribute('aria-label') || '',
                        element.getAttribute('placeholder') || '',
                        element.getAttribute('title') || '',
                        element.getAttribute('name') || '',
                        element.getAttribute('id') || '',
                        element.innerText || '',
                        element.textContent || ''
                    ].join(' ');
                }

                function getElementContext(element) {
                    var parts = [];
                    var current = element;

                    for (var depth = 0; current && depth < 4; depth += 1) {
                        parts.push(elementText(current));
                        current = current.parentElement;
                    }

                    return normalize(parts.join(' '));
                }

                function matchesAnyPattern(text, patterns) {
                    for (var i = 0; i < patterns.length; i += 1) {
                        if (text.indexOf(patterns[i]) !== -1) {
                            return true;
                        }
                    }

                    return false;
                }

                function isFieldFilled(element) {
                    if (!element) { return false; }

                    if (element.isContentEditable) {
                        return normalize(element.textContent).length > 0;
                    }

                    return normalize(element.value || '').length > 0;
                }

                function visibleText(element) {
                    if (!element) { return ''; }

                    return normalize([
                        element.getAttribute('aria-label') || '',
                        element.getAttribute('placeholder') || '',
                        element.getAttribute('title') || '',
                        element.innerText || '',
                        element.textContent || ''
                    ].join(' '));
                }

                function candidateText(element) {
                    if (!element) { return ''; }

                    return normalize([
                        element.getAttribute('aria-label') || '',
                        element.getAttribute('aria-labelledby') || '',
                        element.getAttribute('placeholder') || '',
                        element.getAttribute('title') || '',
                        element.getAttribute('name') || '',
                        element.getAttribute('id') || '',
                        element.getAttribute('autocomplete') || '',
                        element.getAttribute('ng-model') || '',
                        element.getAttribute('data-field') || '',
                        element.getAttribute('data-testid') || '',
                        element.getAttribute('formcontrolname') || '',
                        element.getAttribute('formControlName') || '',
                        element.getAttribute('inputmode') || ''
                    ].join(' '));
                }

                function matchesExactDefinition(candidate, definition) {
                    if (!definition.exactMatchers || definition.exactMatchers.length === 0) {
                        return false;
                    }

                    var candidateContext = normalize([
                        candidate.getAttribute('aria-label') || '',
                        candidate.getAttribute('aria-labelledby') || '',
                        candidate.getAttribute('placeholder') || '',
                        candidate.getAttribute('title') || '',
                        candidate.getAttribute('name') || '',
                        candidate.getAttribute('id') || '',
                        candidate.getAttribute('autocomplete') || '',
                        candidate.getAttribute('ng-model') || '',
                        candidate.getAttribute('data-field') || '',
                        candidate.getAttribute('data-testid') || '',
                        candidate.getAttribute('formcontrolname') || '',
                        candidate.getAttribute('formControlName') || '',
                        candidate.getAttribute('inputmode') || ''
                    ].join(' '));

                    for (var i = 0; i < definition.exactMatchers.length; i += 1) {
                        if (candidateContext.indexOf(normalize(definition.exactMatchers[i])) !== -1) {
                            return true;
                        }
                    }

                    return false;
                }

                function getAngularScope() {
                    if (!window.angular) {
                        return null;
                    }

                    var scopeCandidates = queryAllAcrossDocuments('[ng-repeat="w2 in data.wages"], .ng-scope');
                    for (var i = 0; i < scopeCandidates.length; i += 1) {
                        try {
                            var scope = window.angular.element(scopeCandidates[i]).scope();
                            if (scope && scope.w2) {
                                return scope;
                            }
                        } catch (error) {
                        }
                    }

                    return null;
                }

                function assignPath(object, path, value) {
                    if (!object || !path) {
                        return false;
                    }

                    var parts = path.split('.');
                    var current = object;

                    for (var i = 0; i < parts.length - 1; i += 1) {
                        if (!current[parts[i]]) {
                            current[parts[i]] = {};
                        }

                        current = current[parts[i]];
                    }

                    current[parts[parts.length - 1]] = value;
                    return true;
                }

                function getTargetScope(element) {
                    if (!window.angular || !element) {
                        return null;
                    }

                    var current = element;
                    while (current && current.nodeType === 1) {
                        var repeatExpression = current.getAttribute ? (current.getAttribute('ng-repeat') || current.getAttribute('data-ng-repeat') || '') : '';
                        if (repeatExpression.indexOf('w2 in data.wages') !== -1) {
                            try {
                                var repeatScope = window.angular.element(current).scope();
                                if (repeatScope) {
                                    return repeatScope;
                                }
                            } catch (repeatError) {
                            }
                        }

                        current = current.parentElement;
                    }

                    try {
                        var jq = window.angular.element(element);
                        if (jq && typeof jq.scope === 'function') {
                            var scope = jq.scope();
                            if (scope) {
                                return scope;
                            }
                        }
                    } catch (error) {
                    }

                    try {
                        var fallbackJq = window.angular.element(element);
                        if (fallbackJq && typeof fallbackJq.isolateScope === 'function') {
                            return fallbackJq.isolateScope() || null;
                        }
                    } catch (error) {
                    }

                    return null;
                }

                function setAngularModelValue(definition, value) {
                    if (!definition || !definition.ngModelPath) {
                        return false;
                    }

                    var targetCandidates = queryAllAcrossDocuments('[ng-model="' + definition.ngModelPath + '"]');
                    if (!targetCandidates || targetCandidates.length === 0) {
                        logDebug('W2 debug', definition.key, 'selector', definition.ngModelPath, 'candidates', '0');
                        return false;
                    }

                    var visibleCandidates = [];
                    for (var c = 0; c < targetCandidates.length; c += 1) {
                        if (isVisible(targetCandidates[c])) {
                            visibleCandidates.push(targetCandidates[c]);
                        }
                    }

                    var orderedCandidates = visibleCandidates.length > 0 ? visibleCandidates : targetCandidates;
                    logDebug(
                        'W2 debug',
                        definition.key,
                        'selector',
                        definition.ngModelPath,
                        'candidates',
                        String(targetCandidates.length),
                        'visible',
                        String(visibleCandidates.length),
                        'usingVisible',
                        String(visibleCandidates.length > 0)
                    );

                    for (var i = 0; i < orderedCandidates.length; i += 1) {
                        var target = orderedCandidates[i];
                        var didUpdate = false;
                        var targetInfo = [
                            target.getAttribute('id') || '',
                            target.getAttribute('placeholder') || '',
                            target.getAttribute('name') || '',
                            target.getAttribute('ng-model') || '',
                            target.getAttribute('class') || ''
                        ].join(' | ');
                        var repeatScope = getTargetScope(target);

                        try {
                            if (window.angular) {
                                var jq = window.angular.element(target);
                                var ngModelController = jq.controller ? jq.controller('ngModel') : null;
                                logDebug('W2 debug', definition.key, 'candidate', String(i), targetInfo, 'hasNgModelController', String(!!ngModelController), 'hasScope', String(!!repeatScope));

                                if (ngModelController && typeof ngModelController.$setViewValue === 'function') {
                                    ngModelController.$setViewValue(value);
                                    if (typeof ngModelController.$render === 'function') {
                                        ngModelController.$render();
                                    }

                                    if (repeatScope) {
                                        if (repeatScope.w2 && typeof repeatScope.w2 === 'object') {
                                            repeatScope.w2[definition.modelName] = value;
                                        } else {
                                            assignPath(repeatScope, 'w2.' + definition.modelName, value);
                                        }

                                        if (typeof repeatScope.$applyAsync === 'function') {
                                            repeatScope.$applyAsync();
                                        } else if (typeof repeatScope.$apply === 'function') {
                                            repeatScope.$apply();
                                        }
                                    }

                                    didUpdate = true;
                                    logDebug('W2 debug', definition.key, 'applied via ngModelController', value);
                                }
                            }
                        } catch (error) {
                            logDebug('W2 debug', definition.key, 'controller write error', String(error));
                        }

                        try {
                            var nativeSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
                            if (target.tagName === 'INPUT' && nativeSetter && nativeSetter.set) {
                                nativeSetter.set.call(target, value);
                            } else {
                                target.value = value;
                            }

                            target.dispatchEvent(new Event('input', { bubbles: true }));
                            target.dispatchEvent(new Event('change', { bubbles: true }));
                            target.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Tab' }));

                            var targetScopeFallback = repeatScope;

                            if (targetScopeFallback) {
                                if (targetScopeFallback.w2 && typeof targetScopeFallback.w2 === 'object') {
                                    targetScopeFallback.w2[definition.modelName] = value;
                                } else {
                                    assignPath(targetScopeFallback, 'w2.' + definition.modelName, value);
                                }

                                if (typeof targetScopeFallback.$applyAsync === 'function') {
                                    targetScopeFallback.$applyAsync();
                                } else if (typeof targetScopeFallback.$apply === 'function') {
                                    targetScopeFallback.$apply();
                                }
                            }

                            didUpdate = true;
                            logDebug('W2 debug', definition.key, 'applied via native input fallback', value);
                        } catch (writeError) {
                            logDebug('W2 debug', definition.key, 'native write error', String(writeError));
                        }

                        if (didUpdate) {
                            return true;
                        }
                    }

                    return false;
                }

                function describeCandidate(candidate, definition) {
                    if (!candidate) { return 'null'; }

                    var rect = candidate.getBoundingClientRect();
                    var scope = null;
                    try {
                        scope = getTargetScope(candidate);
                    } catch (error) {
                        scope = null;
                    }

                    var scopeValue = '';
                    if (scope && scope.w2 && definition && definition.modelName && typeof scope.w2 === 'object') {
                        scopeValue = String(scope.w2[definition.modelName] || '');
                    }

                    return [
                        'id=' + (candidate.getAttribute('id') || ''),
                        'name=' + (candidate.getAttribute('name') || ''),
                        'model=' + (candidate.getAttribute('ng-model') || ''),
                        'placeholder=' + (candidate.getAttribute('placeholder') || ''),
                        'class=' + (candidate.getAttribute('class') || ''),
                        'visible=' + String(isVisible(candidate)),
                        'value=' + String(candidate.value || ''),
                        'scope=' + scopeValue,
                        'top=' + String(Math.round(rect.top)),
                        'left=' + String(Math.round(rect.left))
                    ].join(' | ');
                }

                function reportFieldState(definition, phase) {
                    if (!definition || !definition.ngModelPath) { return; }

                    var matches = queryAllAcrossDocuments('[ng-model="' + definition.ngModelPath + '"]');
                    var visibleMatches = [];
                    for (var i = 0; i < matches.length; i += 1) {
                        if (isVisible(matches[i])) {
                            visibleMatches.push(matches[i]);
                        }
                    }

                    var lines = [];
                    lines.push('W2 field report [' + phase + '] ' + definition.key + ' selector=' + definition.ngModelPath);
                    lines.push('matches=' + String(matches.length) + ' visible=' + String(visibleMatches.length));

                    var limit = Math.min(matches.length, 3);
                    for (var j = 0; j < limit; j += 1) {
                        lines.push('match[' + j + '] ' + describeCandidate(matches[j], definition));
                    }

                    var visibleLimit = Math.min(visibleMatches.length, 3);
                    for (var k = 0; k < visibleLimit; k += 1) {
                        lines.push('visible[' + k + '] ' + describeCandidate(visibleMatches[k], definition));
                    }

                    logDebug(lines.join(' || '));
                }

                function allContainerCandidates() {
                    return queryAllAcrossDocuments('label, legend, p, div, section, article, li, td, th, span').filter(function(element) {
                        return isVisible(element) && visibleText(element).length > 0;
                    });
                }

                function bestContainerForDefinition(definition) {
                    var patterns = definitionSearchTerms(definition);
                    var elements = allContainerCandidates();
                    var bestMatch = null;
                    var bestLength = Number.POSITIVE_INFINITY;

                    for (var i = 0; i < elements.length; i += 1) {
                        var element = elements[i];
                        var text = visibleText(element);
                        if (!matchesAnyPattern(text, patterns)) {
                            continue;
                        }

                        if ((definition.key === 'federalIncomeTaxWithheld' || definition.key === 'stateIncomeTaxWithheld') &&
                            text.indexOf('total') !== -1 &&
                            text.indexOf('withheld') !== -1) {
                            continue;
                        }

                        var inputs = element.querySelectorAll('input, textarea, [contenteditable=\"true\"]');
                        var hasVisibleInput = false;
                        for (var j = 0; j < inputs.length; j += 1) {
                            if (isVisible(inputs[j]) && !inputs[j].disabled && !inputs[j].readOnly) {
                                hasVisibleInput = true;
                                break;
                            }
                        }

                        if (!hasVisibleInput) {
                            continue;
                        }

                        var score = text.length;
                        if (score < bestLength) {
                            bestLength = score;
                            bestMatch = element;
                        }
                    }

                    return bestMatch;
                }

                function setInputValue(element, value) {
                    if (!element) { return false; }

                    var nativeSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
                    var textAreaSetter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');

                    if (nativeSetter && nativeSetter.set && element.tagName === 'INPUT') {
                        nativeSetter.set.call(element, value);
                    } else if (textAreaSetter && textAreaSetter.set && element.tagName === 'TEXTAREA') {
                        textAreaSetter.set.call(element, value);
                    } else {
                        element.value = value;
                    }

                    element.focus();
                    element.dispatchEvent(new Event('input', { bubbles: true }));
                    element.dispatchEvent(new Event('change', { bubbles: true }));
                    element.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Tab' }));
                    element.blur();
                    return true;
                }

                function setEditableValue(element, value) {
                    if (!element) { return false; }

                    element.focus();
                    element.textContent = value;
                    element.dispatchEvent(new Event('input', { bubbles: true }));
                    element.dispatchEvent(new Event('change', { bubbles: true }));
                    element.blur();
                    return true;
                }

                function getVisibleCandidates() {
                    var candidates = queryAllAcrossDocuments('input, textarea, [contenteditable=\"true\"]').filter(function(candidate) {
                        return isVisible(candidate) && !candidate.disabled && !candidate.readOnly;
                    });

                    return candidates.sort(function(left, right) {
                        var leftRect = left.getBoundingClientRect();
                        var rightRect = right.getBoundingClientRect();

                        if (Math.abs(leftRect.top - rightRect.top) > 4) {
                            return leftRect.top - rightRect.top;
                        }

                        return leftRect.left - rightRect.left;
                    });
                }

                function bestCandidateForDefinition(definition) {
                    var patterns = definitionSearchTerms(definition);
                    var candidates = getVisibleCandidates();
                    var bestMatch = null;
                    var bestScore = -1;

                    for (var i = 0; i < candidates.length; i += 1) {
                        var candidate = candidates[i];
                        if (matchesExactDefinition(candidate, definition)) {
                            return candidate;
                        }

                        var context = getElementContext(candidate) + ' ' + candidateText(candidate);
                        var isMatch = matchesAnyPattern(context, patterns);

                        if (!isMatch) {
                            continue;
                        }

                        var score = context.length;
                        if (score > bestScore) {
                            bestScore = score;
                            bestMatch = candidate;
                        }
                    }

                    return bestMatch;
                }

                function targetCandidateForDefinition(definition) {
                    var bestMatch = bestCandidateForDefinition(definition);
                    if (bestMatch) {
                        return bestMatch;
                    }

                    var container = bestContainerForDefinition(definition);
                    if (container) {
                        var containerFields = Array.from(container.querySelectorAll('input, textarea, [contenteditable=\"true\"]')).filter(function(candidate) {
                            return isVisible(candidate) && !candidate.disabled && !candidate.readOnly;
                        });

                        for (var i = 0; i < containerFields.length; i += 1) {
                            return containerFields[i];
                        }
                    }

                    if (definition.key === 'federalIncomeTaxWithheld' || definition.key === 'stateIncomeTaxWithheld') {
                        var positionalMatch = nthEmptyVisibleCandidate(typeof definition.orderIndex === 'number' ? definition.orderIndex : 0);
                        if (positionalMatch) {
                            return positionalMatch;
                        }
                    }

                    return nthEmptyVisibleCandidate(typeof definition.orderIndex === 'number' ? definition.orderIndex : 0);
                }

                function firstEmptyVisibleCandidate() {
                    return nthEmptyVisibleCandidate(0);
                }

                function nthEmptyVisibleCandidate(targetIndex) {
                    var candidates = getVisibleCandidates();
                    var emptyIndex = 0;

                    for (var i = 0; i < candidates.length; i += 1) {
                        if (!isFieldFilled(candidates[i])) {
                            if (emptyIndex === targetIndex) {
                                return candidates[i];
                            }

                            emptyIndex += 1;
                        }
                    }

                    return null;
                }

                function fillField(definition, value) {
                    if (!value) { return true; }

                    reportFieldState(definition, 'before');
                    var modelApplied = setAngularModelValue(definition, value);
                    var bestMatch = targetCandidateForDefinition(definition);

                    var domApplied = false;
                    if (bestMatch) {
                        logDebug('W2 fill target', definition.key, 'value', value, 'label', candidateText(bestMatch), 'context', getElementContext(bestMatch));

                        if (bestMatch.isContentEditable) {
                            domApplied = setEditableValue(bestMatch, value);
                        } else {
                            domApplied = setInputValue(bestMatch, value);
                        }
                    } else {
                        logDebug('W2 fill target not found for', definition.key, 'value', value);
                    }

                    var success = modelApplied || domApplied;
                    reportFieldState(definition, success ? 'after' : 'failed');
                    return success;
                }

                function createState(payload) {
                    return {
                        payload: payload || {},
                        nextIndex: 0,
                        lastAttemptAt: 0
                    };
                }

                function isStateComplete(state) {
                    var definitions = fieldDefinitions();
                    for (var i = state.nextIndex; i < definitions.length; i += 1) {
                        var key = definitions[i].key;
                        if ((state.payload[key] || '').trim()) {
                            return false;
                        }
                    }

                    return true;
                }

                function clickAdvanceControl() {
                    var controlSelectors = [
                        'button',
                        '[role=\"button\"]',
                        'a',
                        'input[type=\"button\"]',
                        'input[type=\"submit\"]'
                    ];

                    var controls = queryAllAcrossDocuments(controlSelectors.join(','));
                    var advanceLabels = ['next', 'continue', 'done', 'submit', 'save', 'finish'];

                    for (var i = 0; i < controls.length; i += 1) {
                        var control = controls[i];
                        if (!isVisible(control) || control.disabled) {
                            continue;
                        }

                        var text = normalize(elementText(control));
                        for (var j = 0; j < advanceLabels.length; j += 1) {
                            if (text === advanceLabels[j] || text.indexOf(advanceLabels[j] + ' ') !== -1 || text.indexOf(' ' + advanceLabels[j]) !== -1) {
                                control.click();
                                return true;
                            }
                        }
                    }

                    return false;
                }

                function attemptFill() {
                    var state = window.__taxFactsW2PrefillState;
                    if (!state || !state.payload) { return false; }

                    logDebug('W2 attemptFill start', 'nextIndex=' + String(state.nextIndex), 'payloadKeys=' + Object.keys(state.payload).join(','));
                    var definitions = fieldDefinitions();
                    logDebug('W2 payload keys', Object.keys(state.payload).join(','), JSON.stringify(state.payload));
                    while (state.nextIndex < definitions.length) {
                        var definition = definitions[state.nextIndex];
                        var value = state.payload[definition.key] || '';

                        if (!value) {
                            state.nextIndex += 1;
                            continue;
                        }

                        if (fillField(definition, value)) {
                            state.nextIndex += 1;

                            if (definition.key === 'wages') {
                                window.setTimeout(scheduleAttempt, 250);
                            }

                            return true;
                        }

                        break;
                    }

                    if (state.nextIndex >= definitions.length || isStateComplete(state)) {
                        window.clearInterval(window.__taxFactsW2PrefillInterval);
                        window.__taxFactsW2PrefillInterval = null;
                        return true;
                    }

                    return false;
                }

                function scheduleAttempt() {
                    window.clearTimeout(window.__taxFactsW2PrefillTimer);
                    window.__taxFactsW2PrefillTimer = window.setTimeout(attemptFill, 120);
                }

                window.__taxFactsSetPendingW2Fill = function(payload) {
                    logDebug('W2 setPendingFill', 'payloadKeys=' + Object.keys(payload || {}).join(','), JSON.stringify(payload || {}));
                    window.__taxFactsW2PrefillState = createState(payload || null);
                    window.clearInterval(window.__taxFactsW2PrefillInterval);
                    window.__taxFactsW2PrefillInterval = window.setInterval(attemptFill, 350);
                    scheduleAttempt();
                };

                if (!window.__taxFactsW2PrefillObserver) {
                    window.__taxFactsW2PrefillObserver = new MutationObserver(scheduleAttempt);
                    window.__taxFactsW2PrefillObserver.observe(document.body || document.documentElement, {
                        attributes: true,
                        childList: true,
                        subtree: true
                    });
                }

                window.__taxFactsW2PrefillInstalled = true;
            })();
            """#

            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func attemptW2FieldPrefill(in webView: WKWebView) {
            guard parent.w2PopulateRequestID != handledW2PopulateRequestID,
                  let payload = parent.pendingW2Fields,
                  AppConfiguration.isCalculatorURL(parent.currentURLString) else {
                stopW2PrefillRetryLoop()
                return
            }

            guard let payloadJSON = jsonObjectString(from: w2PayloadDictionary(from: payload)) else {
                return
            }

            beginW2PrefillRetryLoop(in: webView, payloadJSON: payloadJSON)
        }

        private func beginW2PrefillRetryLoop(in webView: WKWebView, payloadJSON: String) {
            guard w2PrefillRetryTimer == nil else { return }

            w2PrefillRetryCount = 0

            performW2PrefillAttempt(in: webView, payloadJSON: payloadJSON)

            w2PrefillRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self, weak webView] _ in
                guard let self, let webView else { return }

                self.w2PrefillRetryCount += 1
                if self.w2PrefillRetryCount >= self.w2PrefillRetryLimit {
                    self.stopW2PrefillRetryLoop()
                    return
                }

                self.performW2PrefillAttempt(in: webView, payloadJSON: payloadJSON)
            }
        }

        private func performW2PrefillAttempt(in webView: WKWebView, payloadJSON: String) {
            let directFillScript = """
            (function(payload) {
                try {
                function logDebug() {}

                function normalize(value) {
                    return (value || '')
                        .toLowerCase()
                        .replace(/[^a-z0-9]+/g, ' ')
                        .replace(/\\s+/g, ' ')
                        .trim();
                }

                function normalizeKey(value) {
                    return normalize(value || '').replace(/\\s+/g, '');
                }

                function isVisible(element) {
                    if (!element) { return false; }

                    var style = window.getComputedStyle(element);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') {
                        return false;
                    }

                    var rects = element.getClientRects();
                    return rects.length > 0 && rects[0].width > 0 && rects[0].height > 0;
                }

                function allDocuments(rootDocument) {
                    var docs = [];

                    function visit(doc) {
                        if (!doc || docs.indexOf(doc) !== -1) {
                            return;
                        }

                        docs.push(doc);

                        var frames = [];
                        try {
                            frames = Array.from(doc.querySelectorAll('iframe'));
                        } catch (error) {
                            return;
                        }

                        for (var i = 0; i < frames.length; i += 1) {
                            try {
                                var frameDoc = frames[i].contentDocument;
                                if (frameDoc) {
                                    visit(frameDoc);
                                }
                            } catch (error) {
                            }
                        }

                        var elements = [];
                        try {
                            elements = Array.from(doc.querySelectorAll('*'));
                        } catch (error) {
                            elements = [];
                        }

                        for (var k = 0; k < elements.length; k += 1) {
                            var shadowRoot = elements[k].shadowRoot;
                            if (shadowRoot) {
                                visit(shadowRoot);
                            }
                        }
                    }

                    visit(rootDocument || document);
                    return docs;
                }

                function queryAllAcrossDocuments(selector) {
                    var results = [];
                    var docs = allDocuments(document);

                    for (var i = 0; i < docs.length; i += 1) {
                        try {
                            results = results.concat(Array.from(docs[i].querySelectorAll(selector)));
                        } catch (error) {
                        }
                    }

                    return results;
                }

                function candidateText(element) {
                    if (!element) { return ''; }

                    return normalize([
                        element.getAttribute('aria-label') || '',
                        element.getAttribute('placeholder') || '',
                        element.getAttribute('title') || '',
                        element.getAttribute('name') || '',
                        element.getAttribute('id') || '',
                        element.getAttribute('autocomplete') || '',
                        element.getAttribute('data-field') || '',
                        element.getAttribute('data-testid') || '',
                        element.getAttribute('formcontrolname') || '',
                        element.getAttribute('formControlName') || '',
                        element.innerText || '',
                        element.textContent || ''
                    ].join(' '));
                }

                function nativeSetValue(element, value) {
                    if (!element) { return false; }

                    if (element.isContentEditable) {
                        element.focus();
                        element.textContent = value;
                        element.dispatchEvent(new Event('input', { bubbles: true }));
                        element.dispatchEvent(new Event('change', { bubbles: true }));
                        element.blur();
                        return true;
                    }

                    try {
                        var inputSetter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
                        var textAreaSetter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
                        if (element.tagName === 'INPUT' && inputSetter && inputSetter.set) {
                            inputSetter.set.call(element, value);
                        } else if (element.tagName === 'TEXTAREA' && textAreaSetter && textAreaSetter.set) {
                            textAreaSetter.set.call(element, value);
                        } else {
                            element.value = value;
                        }

                        element.focus();
                        element.dispatchEvent(new Event('input', { bubbles: true }));
                        element.dispatchEvent(new Event('change', { bubbles: true }));
                        element.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Tab' }));
                        element.blur();
                        return true;
                    } catch (error) {
                        return false;
                    }
                }

                function fieldDefinitions() {
                    return [
                        { key: 'wages', modelPath: 'w2.wage', patterns: ['wages tips other compensations', 'wages tips other compensation', 'wages tips and other compensation', 'your income', 'w2 income', 'w2 wages', 'box 1', 'wages'] },
                        { key: 'federalIncomeTaxWithheld', modelPath: 'w2.federal', patterns: ['federal income tax withheld', 'federal income tax with held', 'federal tax withheld', 'federal tax with held', 'box 2 federal income tax withheld', 'box 2 federal income tax', 'box 2', 'income tax withheld', 'federal withholding'] },
                        { key: 'medicareWagesAndTips', modelPath: 'w2.medicareWages', patterns: ['medicare wages and tips', 'medicare wages tips', 'medicare wages'] },
                        { key: 'stateIncomeTaxWithheld', modelPath: 'w2.state', patterns: ['state income tax withheld', 'state income tax with held', 'state income tax', 'state tax withheld', 'state tax', 'state withholding', 'box 17 state income tax withheld', 'box 17 state income tax', '17 state income tax withheld', '17 state income tax'] },
                        { key: 'socialSecurityTips', modelPath: 'w2.sectip', patterns: ['social security tip', 'social security tips'] },
                        { key: 'allocatedTips', modelPath: 'w2.allotip', patterns: ['allocated tip', 'allocated tips'] }
                    ];
                }

                function exactModelCandidate(definition) {
                    if (!definition || !definition.modelPath) {
                        return null;
                    }

                    var selector = '[ng-model="' + definition.modelPath + '"]';
                    var candidates = queryAllAcrossDocuments(selector);
                    if (!candidates || candidates.length === 0) {
                        return null;
                    }

                    for (var i = 0; i < candidates.length; i += 1) {
                        if (isVisible(candidates[i])) {
                            return candidates[i];
                        }
                    }

                    return candidates[0];
                }

                function assignPath(object, path, value) {
                    if (!object || !path) {
                        return false;
                    }

                    var parts = path.split('.');
                    var current = object;

                    for (var i = 0; i < parts.length - 1; i += 1) {
                        if (!current[parts[i]]) {
                            current[parts[i]] = {};
                        }

                        current = current[parts[i]];
                    }

                    current[parts[parts.length - 1]] = value;
                    return true;
                }

                function getTargetScope(element) {
                    if (!window.angular || !element) {
                        return null;
                    }

                    var current = element;
                    while (current && current.nodeType === 1) {
                        var repeatExpression = current.getAttribute ? (current.getAttribute('ng-repeat') || current.getAttribute('data-ng-repeat') || '') : '';
                        if (repeatExpression.indexOf('w2 in data.wages') !== -1) {
                            try {
                                var repeatScope = window.angular.element(current).scope();
                                if (repeatScope) {
                                    return repeatScope;
                                }
                            } catch (error) {
                            }
                        }

                        current = current.parentElement;
                    }

                    try {
                        var jq = window.angular.element(element);
                        if (jq && typeof jq.scope === 'function') {
                            var scope = jq.scope();
                            if (scope) {
                                return scope;
                            }
                        }
                    } catch (error) {
                    }

                    try {
                        var fallbackJq = window.angular.element(element);
                        if (fallbackJq && typeof fallbackJq.isolateScope === 'function') {
                            return fallbackJq.isolateScope() || null;
                        }
                    } catch (error) {
                    }

                    return null;
                }

                function setAngularModelValue(element, definition, value) {
                    if (!window.angular || !element || !definition) {
                        return false;
                    }

                    var didUpdate = false;
                    var scope = getTargetScope(element);

                    try {
                        var jq = window.angular.element(element);
                        var ngModelController = jq && jq.controller ? jq.controller('ngModel') : null;
                        if (ngModelController && typeof ngModelController.$setViewValue === 'function') {
                            ngModelController.$setViewValue(value);
                            if (typeof ngModelController.$render === 'function') {
                                ngModelController.$render();
                            }
                            didUpdate = true;
                        }
                    } catch (error) {
                        logDebug('W2 angular controller write error', definition.key, String(error));
                    }

                    if (scope) {
                        try {
                            if (scope.w2 && typeof scope.w2 === 'object') {
                                scope.w2[definition.key === 'medicareWagesAndTips' ? 'medicareWages' : definition.key === 'federalIncomeTaxWithheld' ? 'federal' : definition.key === 'stateIncomeTaxWithheld' ? 'state' : definition.key === 'socialSecurityTips' ? 'sectip' : definition.key === 'allocatedTips' ? 'allotip' : 'wage'] = value;
                            } else {
                                var modelName = definition.key === 'medicareWagesAndTips' ? 'medicareWages' : definition.key === 'federalIncomeTaxWithheld' ? 'federal' : definition.key === 'stateIncomeTaxWithheld' ? 'state' : definition.key === 'socialSecurityTips' ? 'sectip' : definition.key === 'allocatedTips' ? 'allotip' : 'wage';
                                assignPath(scope, 'w2.' + modelName, value);
                            }

                            if (typeof scope.$applyAsync === 'function') {
                                scope.$applyAsync();
                            } else if (typeof scope.$apply === 'function') {
                                scope.$apply();
                            }

                            didUpdate = true;
                        } catch (error) {
                            logDebug('W2 angular scope write error', definition.key, String(error));
                        }
                    }

                    return didUpdate;
                }

                function fillAllFields(payloadObject) {
                    var definitions = fieldDefinitions();
                    var orderedKeys = [
                        'wages',
                        'federalIncomeTaxWithheld',
                        'medicareWagesAndTips',
                        'stateIncomeTaxWithheld',
                        'socialSecurityTips',
                        'allocatedTips'
                    ];
                    var definitionsByKey = {};
                    var filledCount = 0;
                    var requestedCount = 0;

                    for (var d = 0; d < definitions.length; d += 1) {
                        definitions[d].orderIndex = d;
                        definitionsByKey[definitions[d].key] = definitions[d];
                    }

                    for (var i = 0; i < orderedKeys.length; i += 1) {
                        var definition = definitionsByKey[orderedKeys[i]];
                        if (!definition) {
                            continue;
                        }

                        var value = String((payloadObject && payloadObject[definition.key]) || '').trim();
                        if (!value) {
                            continue;
                        }

                        requestedCount += 1;

                        var patterns = definition.patterns.concat([normalizeKey(definition.key)]);
                        var candidates = queryAllAcrossDocuments('input, textarea, [contenteditable=\\\"true\\\"]').filter(function(candidate) {
                            return isVisible(candidate) && !candidate.disabled && !candidate.readOnly;
                        });

                        var bestMatch = null;
                        var bestScore = -1;

                        bestMatch = exactModelCandidate(definition);
                        if (bestMatch) {
                            logDebug('W2 exact model match', definition.key, candidateText(bestMatch), 'value', value);
                        }

                        if (!bestMatch) {

                        for (var j = 0; j < candidates.length; j += 1) {
                            var candidate = candidates[j];
                            var context = normalize(getElementContext(candidate) + ' ' + candidateText(candidate));
                            var matched = false;

                            for (var k = 0; k < patterns.length; k += 1) {
                                if (context.indexOf(patterns[k]) !== -1) {
                                    matched = true;
                                    break;
                                }
                            }

                            if (!matched) {
                                continue;
                            }

                            if (context.length > bestScore) {
                                bestScore = context.length;
                                bestMatch = candidate;
                            }
                        }

                        }

                        if (!bestMatch && definition.key === 'wages') {
                            var emptyCandidates = queryAllAcrossDocuments('input, textarea, [contenteditable=\\\"true\\\"]').filter(function(candidate) {
                                return isVisible(candidate) && !candidate.disabled && !candidate.readOnly;
                            });

                            for (var n = 0; n < emptyCandidates.length; n += 1) {
                                var emptyCandidate = emptyCandidates[n];
                                var currentValue = emptyCandidate.isContentEditable ? emptyCandidate.textContent : emptyCandidate.value;
                                if (!normalize(currentValue || '').length) {
                                    bestMatch = emptyCandidate;
                                    break;
                                }
                            }
                        }

                        if (!bestMatch) {
                            var containerCandidates = allContainerCandidates();
                            for (var c = 0; c < containerCandidates.length; c += 1) {
                                var container = containerCandidates[c];
                                var containerContext = normalize(visibleText(container) + ' ' + elementText(container));
                                var containerMatches = false;

                                for (var p = 0; p < patterns.length; p += 1) {
                                    if (containerContext.indexOf(patterns[p]) !== -1) {
                                        containerMatches = true;
                                        break;
                                    }
                                }

                                if (!containerMatches) {
                                    continue;
                                }

                                var containerFields = Array.from(container.querySelectorAll('input, textarea, [contenteditable=\\\"true\\\"]')).filter(function(candidate) {
                                    return isVisible(candidate) && !candidate.disabled && !candidate.readOnly;
                                });

                                if (containerFields.length > 0) {
                                    bestMatch = containerFields[0];
                                    break;
                                }
                            }
                        }

                        if (!bestMatch) {
                            continue;
                        }

                        var angularApplied = setAngularModelValue(bestMatch, definition, value);
                        if (angularApplied || nativeSetValue(bestMatch, value)) {
                            bestMatch.setAttribute('value', value);
                            bestMatch.dispatchEvent(new Event('input', { bubbles: true, cancelable: true }));
                            bestMatch.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
                            bestMatch.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, data: value, inputType: 'insertText' }));
                            bestMatch.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Tab' }));
                            bestMatch.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Tab' }));
                            filledCount += 1;
                            logDebug('W2 field applied', definition.key, 'angular=' + String(angularApplied), 'value=' + value);
                        }
                    }

                    return requestedCount > 0 && filledCount === requestedCount;
                }


                function firstEmptyVisibleCandidate() {
                    var candidates = queryAllAcrossDocuments('input, textarea, [contenteditable=\\\"true\\\"]').filter(function(candidate) {
                        return isVisible(candidate) && !candidate.disabled && !candidate.readOnly;
                    });

                    for (var i = 0; i < candidates.length; i += 1) {
                        var candidate = candidates[i];
                        var currentValue = candidate.isContentEditable ? candidate.textContent : candidate.value;
                        if (!normalize(currentValue || '').length) {
                            return candidate;
                        }
                    }

                    return null;
                }

                function bestWageCandidate() {
                    var exactPatterns = [
                        'wages tips other compensations',
                        'wages tips other compensation',
                        'wages tips and other compensation',
                        'your income',
                        'w2 income',
                        'w2 wages',
                        'box 1',
                        'wages'
                    ];

                    var candidates = queryAllAcrossDocuments('input, textarea, [contenteditable=\\\"true\\\"]').filter(function(candidate) {
                        return isVisible(candidate) && !candidate.disabled && !candidate.readOnly;
                    });

                    var bestMatch = null;
                    var bestScore = -1;

                    for (var i = 0; i < candidates.length; i += 1) {
                        var candidate = candidates[i];
                        var context = normalize(candidateText(candidate));

                        if (context === 'wages tips other compensations' ||
                            context.indexOf('wages tips other compensation') !== -1 ||
                            context.indexOf('wages tips and other compensation') !== -1 ||
                            context.indexOf('your income') !== -1 ||
                            context.indexOf('w2 income') !== -1 ||
                            context.indexOf('w2 wages') !== -1 ||
                            context.indexOf('box 1') !== -1 ||
                            context.indexOf('wages') !== -1) {
                                var score = context.length;
                                if (score > bestScore) {
                                    bestScore = score;
                                    bestMatch = candidate;
                                }
                        }
                    }

                    return bestMatch || firstEmptyVisibleCandidate();
                }

                var wageValue = String((payload && payload.wages) || '').trim();
                if (!wageValue) {
                    return false;
                }

                var target = bestWageCandidate();
                if (!target) {
                    return false;
                }

                var applied = nativeSetValue(target, wageValue);
                if (applied) {
                    target.setAttribute('value', wageValue);
                    target.dispatchEvent(new Event('input', { bubbles: true, cancelable: true }));
                    target.dispatchEvent(new Event('change', { bubbles: true, cancelable: true }));
                    target.dispatchEvent(new InputEvent('input', { bubbles: true, cancelable: true, data: wageValue, inputType: 'insertText' }));
                    target.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'Tab' }));
                    target.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Tab' }));
                }

                return fillAllFields(payload);
                } catch (error) {
                    logDebug('W2 JS exception', String(error), error && error.stack ? error.stack : '');
                    return false;
                }
            })(\(payloadJSON));
            """

            webView.evaluateJavaScript(directFillScript) { [weak self] result, _ in
                guard let self else { return }

                if let success = result as? Bool, success {
                    self.handledW2PopulateRequestID = self.parent.w2PopulateRequestID
                    self.parent.pendingW2Fields = nil
                    self.stopW2PrefillRetryLoop()
                    return
                }
            }
        }

        private func stopW2PrefillRetryLoop(keepPayload: Bool = false) {
            w2PrefillRetryTimer?.invalidate()
            w2PrefillRetryTimer = nil
            w2PrefillRetryCount = 0

            if !keepPayload {
                parent.pendingW2Fields = nil
            }
        }

        private func w2PayloadDictionary(from fields: W2ExtractedFields) -> [String: String] {
            var payload: [String: String] = [:]

            if let value = numericOnlyString(fields.wages) {
                payload["wages"] = value
            }

            if let value = numericOnlyString(fields.federalIncomeTaxWithheld) {
                payload["federalIncomeTaxWithheld"] = value
            }

            if let value = numericOnlyString(fields.medicareWagesAndTips) {
                payload["medicareWagesAndTips"] = value
            }

            if let value = numericOnlyString(fields.stateIncomeTaxWithheld) {
                payload["stateIncomeTaxWithheld"] = value
            }

            if let value = numericOnlyString(fields.socialSecurityTips) {
                payload["socialSecurityTips"] = value
            }

            if let value = numericOnlyString(fields.allocatedTips) {
                payload["allocatedTips"] = value
            }

            return payload
        }

        private func numericOnlyString(_ value: String?) -> String? {
            let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedValue.isEmpty else { return nil }

            let allowedCharacters = CharacterSet(charactersIn: "0123456789.,-")
            let filtered = trimmedValue.unicodeScalars.filter { allowedCharacters.contains($0) }
            let result = String(String.UnicodeScalarView(filtered))
            return result.isEmpty ? nil : result
        }

        private func jsonObjectString(from dictionary: [String: String]) -> String? {
            guard !dictionary.isEmpty,
                  let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }

            return json
        }

        private func injectNativeShellCSS(into webView: WKWebView) {
            let css = """
            html, body {
                padding-top: 0 !important;
                margin-top: 0 !important;
                scroll-padding-top: 72px !important;
            }

            header, nav, .navbar, .site-header, .main-header {
                position: relative !important;
                top: auto !important;
            }

            article, main, .post, .single-post, .entry-content {
                scroll-margin-top: 72px !important;
            }

            article h1:first-child,
            main h1:first-child,
            .entry-title,
            .post-title {
                padding-top: 18px !important;
            }
            """

            let escapedCSS = css
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")

            let script = """
            (function() {
                var existingStyle = document.getElementById('ios-native-shell-style');
                if (existingStyle) { existingStyle.remove(); }
                var style = document.createElement('style');
                style.id = 'ios-native-shell-style';
                style.innerHTML = `\(escapedCSS)`;
                document.head.appendChild(style);
            })();
            """

            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        private func resetScrollPosition(in webView: WKWebView) {
            webView.scrollView.setContentOffset(.zero, animated: false)

            let script = """
            window.scrollTo(0, 0);
            setTimeout(function() { window.scrollTo(0, 0); }, 150);
            setTimeout(function() { window.scrollTo(0, 0); }, 450);
            """

            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}

private struct SavedContentView: View {
    let manager: ReadLaterManager
    let isOffline: Bool
    let onOpen: (SavedArticle) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if manager.articles.isEmpty {
                    ContentUnavailableView(
                        "No Saved Content",
                        systemImage: "bookmark",
                        description: Text("Open https://taxandfacts.com/help/ and tap Save to keep it for offline reading.")
                    )
                } else {
                    List {
                        ForEach(manager.articles) { article in
                            SavedArticleRow(
                                article: article,
                                isRead: Binding(
                                    get: { article.isRead },
                                    set: { manager.setArticle(article, isRead: $0) }
                                ),
                                onOpen: { onOpen(article) },
                                onDelete: { manager.deleteArticle(id: article.id) }
                            )
                        }
                        .onDelete(perform: manager.deleteArticles)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(isOffline ? "Offline Saved" : "Saved Content")
        }
    }
}

private struct SavedArticleRow: View {
    let article: SavedArticle
    @Binding var isRead: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 12) {
                    SavedArticleThumbnail(article: article, isRead: isRead)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(article.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)

                        Label(expirationText, systemImage: "calendar.badge.clock")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(expirationTextColor)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                CompactReadToggle(isRead: $isRead)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(width: 34, height: 34)
                        .background(Color.red.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
            }
        }
        .padding(1)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .padding(.vertical, 2)
        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
        .listRowSeparator(.hidden)
    }

    private var expirationText: String {
        let days = daysRemaining
        return days == 1 ? "Expires in 1 day" : "Expires in \(days) days"
    }

    private var expirationTextColor: Color {
        daysRemaining <= 2 ? .orange : .secondary
    }

    private var daysRemaining: Int {
        let expirationDate = article.savedDate.addingTimeInterval(15 * 24 * 60 * 60)
        let remainingSeconds = max(0, expirationDate.timeIntervalSinceNow)
        return max(1, Int(ceil(remainingSeconds / (24 * 60 * 60))))
    }

}

private struct CompactReadToggle: View {
    @Binding var isRead: Bool

    var body: some View {
        Button {
            isRead.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isRead ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.bold))
                Text("Mark as read")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(isRead ? .green : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background((isRead ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mark as read")
        .accessibilityValue(isRead ? "Read" : "Unread")
    }
}

private struct SavedArticleThumbnail: View {
    let article: SavedArticle
    let isRead: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let imageData = article.imageData,
                   let uiImage = UIImage(data: imageData) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "doc.text.image")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.accentColor)
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if isRead {
                Image(systemName: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white, .green)
                    .padding(4)
            }
        }
        .frame(width: 58, height: 58)
    }
}

private struct SavePageToggleButton: View {
    let isSaved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(.separator, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityLabel(isSaved ? "Remove saved page" : "Save page for offline reading")
    }
}

private struct CalculatorScanButton: View {
    let isProcessing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Scan", systemImage: "doc.viewfinder")
                        .font(.headline.weight(.semibold))
                }
            }
            .foregroundStyle(.primary)
            .frame(height: 56)
            .padding(.horizontal, isProcessing ? 0 : 18)
            .frame(minWidth: 56)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.separator, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityLabel(isProcessing ? "Extracting text" : "Scan W-2")
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.cameraDevice = .rear
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraCaptureView

        init(parent: CameraCaptureView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImageCaptured(image)
            } else {
                parent.dismiss()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct PhotoLibraryCaptureView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryCaptureView

        init(parent: PhotoLibraryCaptureView) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                parent.dismiss()
                return
            }

            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let self else { return }

                DispatchQueue.main.async {
                    if let image = object as? UIImage {
                        self.parent.onImageCaptured(image)
                    } else {
                        self.parent.dismiss()
                    }
                }
            }
        }
    }
}

private struct RecognizedTextItem: Equatable {
    let text: String
    let boundingBox: CGRect
}

private enum TextRecognizer {
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

            let observations = request.results ?? []
            return observations.compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return RecognizedTextItem(text: text, boundingBox: observation.boundingBox)
            }
        }.value
    }
}

private struct W2ExtractedFields: Equatable {
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

private enum W2FieldExtractor {
    private struct FieldSpec {
        let labels: [String]
    }

    private struct CandidateValue {
        let value: String
        let score: CGFloat
    }

    private static let wagesSpec = FieldSpec(labels: [
        "box 1 wages tips other compensation",
        "1 wages tips other compensation",
        "w2 wages tips other compensation",
        "w2 wages tips other compensations",
        "w2 wage tips other compensation",
        "w2 wage tips other compensations",
        "wages tips and other comp",
        "wages tips and other compensation",
        "wages tips and other compensations",
        "wages tips other comp",
        "wages tips other compensation",
        "wages tips other compensations",
        "wage tips and other comp",
        "wage tips and other compensation",
        "wage tips other comp",
        "wage tips other compensation"
    ])

    private static let federalTaxSpec = FieldSpec(labels: [
        "box 2 federal income tax withheld",
        "2 federal income tax withheld",
        "box 2 federal income tax with held",
        "federal income tax withheld",
        "federal income tax with held",
        "federal income tax",
        "federal tax withheld",
        "federal tax with held",
        "income tax withheld"
    ])

    private static let medicareSpec = FieldSpec(labels: [
        "box 5 medicare wages and tips",
        "5 medicare wages and tips",
        "medicare wages and tips",
        "medicare wages tips",
        "medicare wages",
        "madicare wages and tips",
        "madicare wages tips"
    ])

    private static let socialSecurityTipsSpec = FieldSpec(labels: [
        "box 7 social security tips",
        "7 social security tips",
        "social security tips"
    ])

    private static let allocatedTipsSpec = FieldSpec(labels: [
        "box 8 allocated tips",
        "8 allocated tips",
        "allocated tips"
    ])

    private static let stateTaxSpec = FieldSpec(labels: [
        "box 17 state income tax",
        "17 state income tax",
        "box 17 state income tax withheld",
        "17 state income tax withheld",
        "state income tax withheld",
        "state income tax with held",
        "state income tax with held also",
        "state income tax",
        "state tax withheld",
        "state tax"
    ])

    private static var allTargetLabels: [String] {
        [wagesSpec, federalTaxSpec, medicareSpec, socialSecurityTipsSpec, allocatedTipsSpec, stateTaxSpec].flatMap(\.labels)
    }

    static func extractFields(from text: String, items: [RecognizedTextItem] = []) -> W2ExtractedFields {
        let fallbackFields = extractFieldsFromText(text)

        return W2ExtractedFields(
            wages: extractPositionedValue(from: items, spec: wagesSpec, minimumWholeDollarDigits: 5) ?? fallbackFields.wages,
            federalIncomeTaxWithheld: extractPositionedValue(from: items, spec: federalTaxSpec) ?? fallbackFields.federalIncomeTaxWithheld,
            medicareWagesAndTips: extractPositionedValue(from: items, spec: medicareSpec) ?? fallbackFields.medicareWagesAndTips,
            stateIncomeTaxWithheld: extractPositionedValue(from: items, spec: stateTaxSpec, minimumWholeDollarDigits: 3) ?? fallbackFields.stateIncomeTaxWithheld,
            socialSecurityTips: extractTipFieldValue(from: items, spec: socialSecurityTipsSpec),
            allocatedTips: extractTipFieldValue(from: items, spec: allocatedTipsSpec)
        )
    }

    private static func extractFieldsFromText(_ text: String) -> W2ExtractedFields {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return W2ExtractedFields(
            wages: extractValueAfterLabel(from: lines, spec: wagesSpec, minimumWholeDollarDigits: 5),
            federalIncomeTaxWithheld: extractValueAfterLabel(from: lines, spec: federalTaxSpec),
            medicareWagesAndTips: extractValueAfterLabel(from: lines, spec: medicareSpec),
            stateIncomeTaxWithheld: extractValueAfterLabel(from: lines, spec: stateTaxSpec, minimumWholeDollarDigits: 3),
            socialSecurityTips: extractTipFieldValue(from: lines, spec: socialSecurityTipsSpec),
            allocatedTips: extractTipFieldValue(from: lines, spec: allocatedTipsSpec)
        )
    }

    private static func extractTipFieldValue(from items: [RecognizedTextItem], spec: FieldSpec) -> String? {
        for labelItem in items where containsAnyLabel(labelItem.text, labels: spec.labels) {
            if let value = firstCurrencyValue(in: textAfterBestLabel(in: labelItem.text, labels: spec.labels), allowsWholeDollars: true),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: 3) {
                return value
            }
        }

        return nil
    }

    private static func extractTipFieldValue(from lines: [String], spec: FieldSpec) -> String? {
        for line in lines {
            let normalizedLine = normalizedSearchText(line)
            guard spec.labels.contains(where: { normalizedLine.contains($0) }) else { continue }

            if let value = firstCurrencyValue(in: textAfterBestLabel(in: line, labels: spec.labels), allowsWholeDollars: true),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: 3) {
                return value
            }
        }

        return nil
    }

    private static func extractPositionedValue(from items: [RecognizedTextItem], spec: FieldSpec, minimumWholeDollarDigits: Int = 1) -> String? {
        extractPositionedValue(from: items, spec: spec, minimumWholeDollarDigits: minimumWholeDollarDigits, allowRelaxedFallback: true)
    }

    private static func extractPositionedValue(
        from items: [RecognizedTextItem],
        spec: FieldSpec,
        minimumWholeDollarDigits: Int,
        allowRelaxedFallback: Bool
    ) -> String? {
        guard !items.isEmpty else { return nil }

        for labelItem in items where containsAnyLabel(labelItem.text, labels: spec.labels) {
            if let value = firstCurrencyValue(in: textAfterBestLabel(in: labelItem.text, labels: spec.labels), allowsWholeDollars: true),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }

            let lowerBoundaryY = nextLowerW2LabelBoundaryY(in: items, below: labelItem.boundingBox)
            let candidates = items.compactMap { item -> CandidateValue? in
                guard item != labelItem,
                      isLikelySameW2Box(candidate: item.boundingBox, label: labelItem.boundingBox, lowerBoundaryY: lowerBoundaryY),
                      !containsAnyLabel(item.text, labels: allTargetLabels),
                      !containsIgnoredW2Label(item.text),
                      let value = firstCurrencyValue(in: normalizedSearchText(item.text), allowsWholeDollars: true),
                      isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) else {
                    return nil
                }

                let score = spatialScore(candidate: item.boundingBox, label: labelItem.boundingBox)
                return CandidateValue(value: value, score: score)
            }

            if let bestValue = candidates.min(by: { $0.score < $1.score })?.value {
                return bestValue
            }

            if allowRelaxedFallback, minimumWholeDollarDigits > 1,
               let relaxedValue = relaxedNearbyCurrencyValue(from: items, label: labelItem.boundingBox, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return relaxedValue
            }
        }

        return nil
    }

    private static func extractValueAfterLabel(from lines: [String], spec: FieldSpec, minimumWholeDollarDigits: Int = 1) -> String? {
        for lineIndex in lines.indices {
            let normalizedLine = normalizedSearchText(lines[lineIndex])
            guard spec.labels.contains(where: { normalizedLine.contains($0) }) else {
                continue
            }

            if let value = firstCurrencyValue(in: textAfterBestLabel(in: lines[lineIndex], labels: spec.labels), allowsWholeDollars: true),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }

            let nextLineIndex = lines.index(after: lineIndex)
            if nextLineIndex < lines.endIndex,
               !containsAnyLabel(lines[nextLineIndex], labels: allTargetLabels),
               !containsIgnoredW2Label(lines[nextLineIndex]),
               let value = firstCurrencyValue(in: normalizedSearchText(lines[nextLineIndex]), allowsWholeDollars: true),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }

            let secondNextLineIndex = lines.index(after: nextLineIndex)
            if secondNextLineIndex < lines.endIndex,
               !containsAnyLabel(lines[secondNextLineIndex], labels: allTargetLabels),
               !containsIgnoredW2Label(lines[secondNextLineIndex]),
               let value = firstCurrencyValue(in: normalizedSearchText(lines[secondNextLineIndex]), allowsWholeDollars: true),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }
        }

        return nil
    }

    private static func isLikelySameW2Box(candidate: CGRect, label: CGRect, lowerBoundaryY: CGFloat?) -> Bool {
        let candidateMidX = candidate.midX
        let labelMidX = label.midX
        let candidateMidY = candidate.midY
        let labelMidY = label.midY
        let sameColumnTolerance = max(CGFloat(0.18), label.width * 1.1)
        let isSameColumn = abs(candidateMidX - labelMidX) <= sameColumnTolerance
        let isSameOrBelowLabel = candidateMidY <= labelMidY + 0.035
        let isNearVertically = candidateMidY >= labelMidY - 0.16
        let isAboveNextBox = lowerBoundaryY.map { candidateMidY > $0 } ?? true

        return isSameColumn && isSameOrBelowLabel && isNearVertically && isAboveNextBox
    }

    private static func nextLowerW2LabelBoundaryY(in items: [RecognizedTextItem], below label: CGRect) -> CGFloat? {
        let sameColumnTolerance = max(CGFloat(0.18), label.width * 1.1)
        let lowerLabels = items.filter { item in
            let isSameColumn = abs(item.boundingBox.midX - label.midX) <= sameColumnTolerance
            let isBelow = item.boundingBox.midY < label.midY
            return isSameColumn && isBelow && isAnyW2BoxLabel(item.text)
        }

        return lowerLabels.map(\.boundingBox.midY).max()
    }

    private static func spatialScore(candidate: CGRect, label: CGRect) -> CGFloat {
        let horizontalDistance = abs(candidate.midX - label.midX)
        let verticalDistance = abs(candidate.midY - label.midY)
        let belowBonus: CGFloat = candidate.midY <= label.midY ? 0 : 0.1
        return horizontalDistance + verticalDistance + belowBonus
    }

    private static func textAfterBestLabel(in text: String, labels: [String]) -> String {
        let normalizedText = normalizedSearchText(text)

        for label in labels.sorted(by: { $0.count > $1.count }) {
            guard let labelRange = normalizedText.range(of: label) else {
                continue
            }

            return String(normalizedText[labelRange.upperBound...])
        }

        return normalizedText
    }

    private static func containsAnyLabel(_ text: String, labels: [String]) -> Bool {
        let normalizedText = normalizedSearchText(text)
        return labels.contains { normalizedText.contains($0) }
    }

    private static let ignoredW2Labels: [String] = [
        "social security",
        "social security number",
        "social security tax withheld",
        "social security wages",
        "allocated tips",
        "dependent care benefits",
        "nonqualified plans",
        "employee ssn",
        "employer identification",
        "employer name",
        "employee name",
        "control number",
        "local wages",
        "local income tax"
    ]

    private static let w2BoxBoundaryLabels: [String] = allTargetLabels + ignoredW2Labels + [
        "social security tips",
        "verification code",
        "dependent care benefits",
        "nonqualified plans",
        "state wages tips",
        "state wages tips etc",
        "local wages tips",
        "local wages tips etc",
        "locality name"
    ]

    private static func containsIgnoredW2Label(_ text: String) -> Bool {
        let normalizedText = normalizedSearchText(text)
        return ignoredW2Labels.contains { normalizedText.contains($0) }
    }

    private static func isAnyW2BoxLabel(_ text: String) -> Bool {
        let normalizedText = normalizedSearchText(text)
        return w2BoxBoundaryLabels.contains { normalizedText.contains($0) }
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: #"[^a-z0-9.$]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstCurrencyValue(in text: String, allowsWholeDollars: Bool = false) -> String? {
        currencyValues(in: text, allowsWholeDollars: allowsWholeDollars).first
    }

    private static func isAcceptableCurrencyValue(_ value: String, minimumWholeDollarDigits: Int) -> Bool {
        guard minimumWholeDollarDigits > 1, !value.contains("."), !value.contains(",") else {
            return true
        }

        let digitCount = value.filter(\.isNumber).count
        return digitCount >= minimumWholeDollarDigits
    }

    private static func relaxedNearbyCurrencyValue(
        from items: [RecognizedTextItem],
        label: CGRect,
        minimumWholeDollarDigits: Int
    ) -> String? {
        let relaxedCandidates = items.compactMap { item -> CandidateValue? in
            guard !containsAnyLabel(item.text, labels: allTargetLabels),
                  !containsIgnoredW2Label(item.text),
                  let value = firstCurrencyValue(in: normalizedSearchText(item.text), allowsWholeDollars: true),
                  isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) else {
                return nil
            }

            let candidateMidX = item.boundingBox.midX
            let candidateMidY = item.boundingBox.midY
            guard candidateMidX >= label.midX - 0.02,
                  candidateMidY <= label.midY + 0.08,
                  candidateMidY >= label.midY - 0.25 else {
                return nil
            }

            let score = spatialScore(candidate: item.boundingBox, label: label)
            return CandidateValue(value: value, score: score)
        }

        return relaxedCandidates.min(by: { $0.score < $1.score })?.value
    }

    private static func currencyValues(in text: String, allowsWholeDollars: Bool = false) -> [String] {
        let amountPattern = allowsWholeDollars
            ? #"[0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})?|[0-9]+(?:\.[0-9]{2})?"#
            : #"[0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{2})|[0-9]{4,}(?:\.[0-9]{2})|[0-9]+\.[0-9]{2}"#
        let pattern = #"(?<![a-z0-9])\$?\s*("# + amountPattern + #")(?![a-z0-9])"#
        let ignoredBoxNumbers: Set<String> = ["1", "2", "3", "4", "5", "6", "16", "17", "18", "19", "20"]

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)

        return matches.compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else {
                return nil
            }

            let value = String(text[valueRange]).replacingOccurrences(of: ",", with: "")
            return ignoredBoxNumbers.contains(value) ? nil : value
        }
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

private struct CalculatorCaptureAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SavedArticleDetailView: View {
    let article: SavedArticle

    var body: some View {
        Group {
            if article.htmlString.isEmpty {
                ContentUnavailableView(
                    "Saved Page Unavailable",
                    systemImage: "doc.questionmark",
                    description: Text("This saved item does not include an offline page snapshot.")
                )
            } else {
                OfflineHTMLView(htmlString: article.htmlString, baseURLString: article.urlString)
            }
        }
    }
}

private struct OfflineHTMLView: UIViewRepresentable {
    let htmlString: String
    let baseURLString: String

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.loadHTMLString(htmlString, baseURL: URL(string: baseURLString))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        uiView.loadHTMLString(htmlString, baseURL: URL(string: baseURLString))
    }
}

private struct SavedArticle: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let urlString: String
    let htmlString: String
    let imageURLString: String
    var imageData: Data?
    let savedDate: Date
    var isRead: Bool

    init(
        id: UUID,
        title: String,
        urlString: String,
        htmlString: String,
        imageURLString: String,
        imageData: Data? = nil,
        savedDate: Date,
        isRead: Bool = false
    ) {
        self.id = id
        self.title = title
        self.urlString = urlString
        self.htmlString = htmlString
        self.imageURLString = imageURLString
        self.imageData = imageData
        self.savedDate = savedDate
        self.isRead = isRead
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        urlString = try container.decode(String.self, forKey: .urlString)
        htmlString = try container.decodeIfPresent(String.self, forKey: .htmlString) ?? ""
        imageURLString = try container.decodeIfPresent(String.self, forKey: .imageURLString) ?? ""
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        savedDate = try container.decode(Date.self, forKey: .savedDate)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    }
}

private struct CalculatorCapture: Identifiable, Codable, Equatable {
    let id: UUID
    let pageTitle: String
    let urlString: String
    let recognizedText: String
    let capturedDate: Date
}

@MainActor
@Observable
private final class CalculatorCaptureManager {
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
private final class ReadLaterManager {
    private(set) var articles: [SavedArticle] = []

    private let storageKey = "read_later_articles"
    private let expirationInterval: TimeInterval = 15 * 24 * 60 * 60
    private let expirationWarningInterval: TimeInterval = 14 * 24 * 60 * 60

    init() {
        loadArticles()
        cleanupExpiredArticles()
    }

    func saveArticle(title: String, urlString: String, htmlString: String, imageURLString: String) {
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
                imageData: existing.imageURLString == imageURLString ? existing.imageData : nil,
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
            title: cleanTitle.isEmpty ? "Tax & Facts" : cleanTitle,
            urlString: urlString,
            htmlString: htmlString,
            imageURLString: imageURLString,
            savedDate: Date()
        )

        articles.insert(article, at: 0)
        saveToDisk()
        loadImageIfNeeded(for: article.id, imageURLString: imageURLString)
        scheduleExpirationWarning(for: article.id, title: article.title)
    }

    func deleteArticles(at offsets: IndexSet) {
        let deletedIDs = offsets.map { articles[$0].id.uuidString }
        articles.remove(atOffsets: offsets)
        saveToDisk()
        cancelExpirationWarnings(ids: deletedIDs)
    }

    func deleteArticle(id: UUID) {
        articles.removeAll { $0.id == id }
        saveToDisk()
        cancelExpirationWarnings(ids: [id.uuidString])
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

private struct AppNavigationBar: View {
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

#Preview {
    ContentView()
}
