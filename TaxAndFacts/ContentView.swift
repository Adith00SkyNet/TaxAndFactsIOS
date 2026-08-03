import SwiftUI
import UIKit
import AVFoundation
import Photos
import WebKit
import UserNotifications
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var readLaterManager = ReadLaterManager()
    @State private var networkStatusMonitor = NetworkStatusMonitor()
    @State private var selectedScreen: AppScreen = .home
    @State private var webURL = AppConfiguration.productionWebURL
    @State private var webHistory: [URL] = []
    @State private var isRestoringWebHistory = false
    @State private var canGoBack = false
    @State private var backRequestID = 0
    @State private var webViewOffline = false
    @State private var selectedSavedArticle: SavedArticle?

    private var isOffline: Bool {
        networkStatusMonitor.isOffline || webViewOffline
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedScreen {
                case .home:
                    HomeTabContainer(
                        manager: readLaterManager,
                        url: $webURL,
                        isOffline: Binding(
                            get: { isOffline },
                            set: { webViewOffline = $0 }
                        ),
                        canGoBack: $canGoBack,
                        backRequestID: $backRequestID,
                        onNavigationFinished: handleWebNavigation
                    )
                case .saved:
                    SavedContentView(
                        manager: readLaterManager,
                        isOffline: isOffline,
                        onOpen: openSavedArticle,
                        onBrowseArticles: showBlogList
                    )
                case .savedArticle:
                    if let selectedSavedArticle {
                        SavedArticleDetailView(
                            article: selectedSavedArticle,
                            isOffline: isOffline,
                            onClose: {
                                self.selectedSavedArticle = nil
                                self.selectedScreen = .saved
                            }
                        )
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
        .onChange(of: networkStatusMonitor.isOffline) { _, newValue in
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

    private func showBlogList() {
        selectedScreen = .home
        webURL = URL(string: "https://taxandfacts.com/blogList.html")!
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

 #if false
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

#endif

private struct HomeTabContainer: View {
    private enum W2ScanSource {
        case camera
        case photoLibrary
        case file
    }

    private struct UploadSuccessState: Identifiable {
        let id = UUID()
        let documentNumber: Int
    }

    private struct SuccessToastState: Identifiable {
        let id = UUID()
        let message: String
    }

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
    @State private var pendingW2Documents: [W2ExtractedFields] = []
    @State private var w2PopulateRequestID = 0
    @State private var isShowingCamera = false
    @State private var isShowingPhotoLibrary = false
    @State private var isShowingFileImporter = false
    @State private var isShowingCaptureOptions = false
    @State private var isRecognizingText = false
    @State private var isCalculatorStep2 = false
    @State private var isCalculatorStep4 = false
    @State private var uploadSuccessState: UploadSuccessState?
    @State private var captureAlert: CalculatorCaptureAlert?
    @State private var unclearImageAlert: CalculatorCaptureAlert?
    @State private var documentNotRecognizedAlert: CalculatorCaptureAlert?
    @State private var lastW2ScanSource: W2ScanSource = .camera
    @State private var shouldPopulateQueuedW2Documents = false
    @State private var resultPageCaptureController = ResultPageCaptureController()
    @State private var isShowingResultSaveOptions = false
    @State private var isShowingPDFExportPicker = false
    @State private var pdfExportURL: URL?
    @State private var previousStepRequestID = 0
    @State private var isSavingResultPage = false
    @State private var successToastState: SuccessToastState?

    private enum ResultPageSaveFormat {
        case screenshot
        case pdf
    }
    

    private var shouldShowResultSaveButton: Bool {
        guard AppConfiguration.isCalculatorURL(currentURLString) else { return false }

        return isCalculatorStep4
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if isOffline {
                ContentUnavailableView(
                    "🌐 You are currently offline. Accessing saved articles only.",
                    systemImage: "wifi.slash",
                    description: Text("")
                )
            } else {
                NativeWebViewWrapper(
                    url: $url,
                    isOffline: $isOffline,
                    currentTitle: $currentTitle,
                    currentURLString: $currentURLString,
                    currentHTMLString: $currentHTMLString,
                    currentImageURLString: $currentImageURLString,
                    pendingW2Documents: $pendingW2Documents,
                    w2PopulateRequestID: $w2PopulateRequestID,
                    shouldPopulateQueuedW2Documents: $shouldPopulateQueuedW2Documents,
                    canGoBack: $canGoBack,
                    backRequestID: $backRequestID,
                    previousStepRequestID: $previousStepRequestID,
                    isCalculatorStep2: $isCalculatorStep2,
                    isCalculatorStep4: $isCalculatorStep4,
                    resultPageCaptureController: resultPageCaptureController,
                    onNavigationFinished: onNavigationFinished,
                    onW2PopulationSuccess: { showSuccessToast(message: "Success! Your tax form has been updated with your uploaded W-2 data.") },
                    onShowCaptureOptions: showCaptureOptions
                )

                if AppConfiguration.isHelpURL(currentURLString) {
                    SavePageToggleButton(
                        isSaved: manager.isSaved(urlString: currentURLString),
                        action: toggleSavedPage
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 18)
                }

                if shouldShowResultSaveButton {
                    ResultPageSaveButton(
                        isSaving: isSavingResultPage,
                        action: showResultSaveOptions
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 18)
                    .zIndex(2)
                }

            }
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraCaptureView { image in
                processCapturedImage(image, source: .camera)
            } onPermissionDenied: {
                captureAlert = CalculatorCaptureAlert(
                    title: "Camera Access Denied",
                    message: "To scan your W-2, please enable camera access in your iPhone's system settings.",
                    kind: .cameraAccessDenied
                )
            }
                .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingPhotoLibrary) {
            PhotoLibraryCaptureView { image in
                processCapturedImage(image, source: .photoLibrary)
            }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importSelectedFile(from: url)
            case .failure:
                captureAlert = CalculatorCaptureAlert.info(
                    title: "Unable to Open File",
                    message: "The selected file could not be imported. Please try again."
                )
            }
        }
        .background(
            NativeCenteredAlertPresenter(isPresented: $isShowingResultSaveOptions) { dismiss in
                let alert = UIAlertController(
                    title: "Save your tax outcome",
                    message: "Choose how you would like to export your final calculation summary.",
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: "Save as PDF document", style: .default) { _ in
                    dismiss()
                    saveCurrentResultPage(as: .pdf)
                })

                alert.addAction(UIAlertAction(title: "Save to Photos image", style: .default) { _ in
                    dismiss()
                    saveCurrentResultPage(as: .screenshot)
                })

                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    dismiss()
                })

                return alert
            }
        )
        .sheet(isPresented: $isShowingPDFExportPicker, onDismiss: {
            self.pdfExportURL = nil
        }) {
            if let exportURL = pdfExportURL {
                PDFExportPicker(
                    fileURL: exportURL,
                    onExportCompleted: {
                        self.isShowingPDFExportPicker = false
                        self.pdfExportURL = nil
                        showSuccessToast(message: "PDF saved successfully to your files!")
                    },
                    onCancel: {
                        self.isShowingPDFExportPicker = false
                        self.pdfExportURL = nil
                    }
                )
            }
        }
        .alert(item: $captureAlert) { alert in
            switch alert.kind {
            case .info:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            case .scanDecision:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Yes"), action: reopenLastScanSource),
                    secondaryButton: .cancel(Text("Done Scanning"), action: beginW2Population)
                )
            case .documentNotRecognized:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Upload again"), action: reopenLastScanSource),
                    secondaryButton: .cancel(Text("Enter manually"), action: enterW2Manually)
                )
            case .duplicateDocument:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Upload again"), action: reopenLastScanSource),
                    secondaryButton: .cancel(Text("Cancel"))
                )
            case .cameraAccessDenied:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Go to Settings"), action: openAppSettings),
                    secondaryButton: .cancel(Text("Cancel"))
                )
            case .photosAccessDenied:
                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    primaryButton: .default(Text("Go to Settings"), action: openAppSettings),
                    secondaryButton: .cancel(Text("Cancel"))
                )
            }
        }
        .background(
            NativeCenteredAlertPresenter(isPresented: $isShowingCaptureOptions) { dismiss in
                let alert = UIAlertController(
                    title: "Upload W-2",
                    message: "Choose how you want to add your W-2.",
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: "Take a photo", style: .default) { _ in
                    dismiss()
                    openCamera()
                })

                alert.addAction(UIAlertAction(title: "Upload image", style: .default) { _ in
                    dismiss()
                    openPhotoLibrary()
                })

                alert.addAction(UIAlertAction(title: "Upload file", style: .default) { _ in
                    dismiss()
                    openFileImporter()
                })

                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    dismiss()
                })

                return alert
            }
        )
        .background(
            NativeCenteredAlertPresenter(isPresented: Binding(
                get: { uploadSuccessState != nil },
                set: { newValue in
                    if !newValue {
                        uploadSuccessState = nil
                    }
                }
            )) { dismiss in
                let documentNumber = uploadSuccessState?.documentNumber ?? 1
                let alert = UIAlertController(
                    title: "W-2 added successfully!",
                    message: "Your file is attached as W-2 #\(documentNumber). What would you like to do next?",
                    preferredStyle: .alert
                )

                alert.addAction(UIAlertAction(title: "Finish & calculate tax", style: .default) { _ in
                    dismiss()
                    finishAndCalculateTax()
                })

                alert.addAction(UIAlertAction(title: "Add another W-2", style: .default) { _ in
                    dismiss()
                    addAnotherW2()
                })

                alert.addAction(UIAlertAction(title: "Remove this file", style: .destructive) { _ in
                    dismiss()
                    removeUploadedW2()
                })

                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    dismiss()
                })

                return alert
            }
        )
        .background(
            NativeCenteredAlertPresenter(isPresented: Binding(
                get: { unclearImageAlert != nil },
                set: { newValue in
                    if !newValue {
                        unclearImageAlert = nil
                    }
                }
            )) { dismiss in
                let alert = unclearImageAlert ?? CalculatorCaptureAlert(
                    title: "Unclear image",
                    message: "We couldn't read the text on your W-2. Please try again with a clearer photo or upload a digital PDF.",
                    kind: .documentNotRecognized
                )

                let alertController = UIAlertController(
                    title: alert.title,
                    message: alert.message,
                    preferredStyle: .alert
                )

                alertController.addAction(UIAlertAction(title: "Upload again", style: .default) { _ in
                    dismiss()
                    reopenLastScanSource()
                })

                alertController.addAction(UIAlertAction(title: "Enter manually", style: .default) { _ in
                    dismiss()
                    enterW2Manually()
                })

                alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    dismiss()
                })

                return alertController
            }
        )
        .background(
            NativeCenteredAlertPresenter(isPresented: Binding(
                get: { documentNotRecognizedAlert != nil },
                set: { newValue in
                    if !newValue {
                        documentNotRecognizedAlert = nil
                    }
                }
            )) { dismiss in
                let alert = documentNotRecognizedAlert ?? CalculatorCaptureAlert(
                    title: "Document not recognized",
                    message: "We couldn't find a valid W-2 form in this file. Please make sure you are uploading an official W-2 tax document.",
                    kind: .documentNotRecognized
                )

                let alertController = UIAlertController(
                    title: alert.title,
                    message: alert.message,
                    preferredStyle: .alert
                )

                alertController.addAction(UIAlertAction(title: "Upload again", style: .default) { _ in
                    dismiss()
                    reopenLastScanSource()
                })

                alertController.addAction(UIAlertAction(title: "Enter manually", style: .default) { _ in
                    dismiss()
                    enterW2Manually()
                })

                alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    dismiss()
                })

                return alertController
            }
        )
        .overlay {
            if isRecognizingText {
                processingOverlay
                    .transition(.opacity)
                    .zIndex(7)
            }
        }
        .overlay(alignment: .top) {
            if let successToastState {
                successToastView(for: successToastState)
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(6)
            }
        }
    }

    private func showCaptureOptions() {
        isShowingCaptureOptions = true
    }

    private func showResultSaveOptions() {
        isShowingResultSaveOptions = true
    }

    private func showSuccessToast(message: String) {
        let toast = SuccessToastState(message: message)
        withAnimation(.easeInOut(duration: 0.25)) {
            successToastState = toast
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard successToastState?.id == toast.id else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                successToastState = nil
            }
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
    }

    private struct NativeCenteredAlertPresenter: UIViewControllerRepresentable {
        @Binding var isPresented: Bool
        let makeAlert: (_ dismiss: @escaping () -> Void) -> UIAlertController

        func makeUIViewController(context: Context) -> UIViewController {
            UIViewController()
        }

        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
            if isPresented {
                guard !context.coordinator.isPresenting else { return }
                context.coordinator.isPresenting = true

                let dismiss = {
                    isPresented = false
                }

                let alertController = makeAlert(dismiss)
                context.coordinator.presentedAlert = alertController
                DispatchQueue.main.async {
                    uiViewController.present(alertController, animated: true)
                }
            } else if context.coordinator.isPresenting {
                context.coordinator.isPresenting = false
                context.coordinator.presentedAlert?.dismiss(animated: true)
                context.coordinator.presentedAlert = nil
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        final class Coordinator {
            var isPresenting = false
            weak var presentedAlert: UIViewController?
        }
    }

    private func successToastView(for state: SuccessToastState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)

            Text(state.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator.opacity(0.18), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }


    private static func importedImage(from url: URL) -> UIImage? {
        let fileExtension = url.pathExtension.lowercased()

        if fileExtension == "pdf",
           let pdfData = try? Data(contentsOf: url),
           let provider = CGDataProvider(data: pdfData as CFData),
           let pdfDocument = CGPDFDocument(provider),
           let page = pdfDocument.page(at: 1) {
            let pageRect = page.getBoxRect(.mediaBox)
            guard pageRect.width > 0, pageRect.height > 0 else { return nil }

            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true

            let renderer = UIGraphicsImageRenderer(size: pageRect.size, format: format)
            return renderer.image { context in
                UIColor.systemBackground.setFill()
                context.fill(CGRect(origin: .zero, size: pageRect.size))

                let cgContext = context.cgContext
                cgContext.saveGState()
                cgContext.translateBy(x: 0, y: pageRect.height)
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.interpolationQuality = .high
                cgContext.drawPDFPage(page)
                cgContext.restoreGState()
            }
        }

        if let image = UIImage(contentsOfFile: url.path) {
            return image
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)

                Text("Processing W-2")
                    .font(.headline.weight(.semibold))

                Text("Extracting your W-2 data and updating your tax form... Please hold on a moment.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
            .padding(.horizontal, 24)
        }
    }

    private func uploadSuccessOverlay(for state: UploadSuccessState) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(alignment: .center, spacing: 16) {
                Text("W-2 added successfully!")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Your file is attached as W-2 #\(state.documentNumber). What would you like to do next?")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button(action: finishAndCalculateTax) {
                        Text("Finish & calculate tax")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.white)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(action: addAnotherW2) {
                        Text("Add another W-2")
                            .font(.headline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .foregroundStyle(.primary)
                            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(.separator, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: removeUploadedW2) {
                        Text("Remove this file")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.blue)
                            .underline()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 22, y: 8)
            .padding(.horizontal, 20)
        }
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
            showSuccessToast(message: "Article saved! You can now read this without an internet connection.")
        }
    }

    private func saveCurrentResultPage(as format: ResultPageSaveFormat) {
        guard !isSavingResultPage else { return }
        isSavingResultPage = true

        Task { @MainActor in
            defer { isSavingResultPage = false }

            guard let pdfData = await resultPageCaptureController.captureResultSectionPDFData() else {
                captureAlert = CalculatorCaptureAlert.info(
                    title: "Unable to Save",
                    message: "The result page could not be captured. Please try again."
                )
                return
            }

            do {
                switch format {
                case .screenshot:
                    guard let snapshotImage = resultPageCaptureController.renderImage(from: pdfData),
                          snapshotImage.cgImage != nil else {
                        captureAlert = CalculatorCaptureAlert.info(
                            title: "Unable to Save",
                            message: "The result page image could not be generated."
                        )
                        return
                    }

                    saveResultScreenshotToPhotos(snapshotImage)
                case .pdf:
                    let fileURL: URL
                    let fileName = "TaxAndFacts-Result-\(UUID().uuidString).pdf"
                    fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
                    try pdfData.write(to: fileURL, options: .atomic)
                    pdfExportURL = fileURL
                    isShowingPDFExportPicker = true
                }
            } catch {
                let message: String
                switch format {
                case .screenshot:
                    message = "The screenshot file could not be written."
                case .pdf:
                    message = "The PDF file could not be written."
                }

                captureAlert = CalculatorCaptureAlert.info(
                    title: "Unable to Export",
                    message: message
                )
            }
        }
    }

    private func saveResultScreenshotToPhotos(_ image: UIImage) {
        let saveChanges = {
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.showSuccessToast(message: "Image saved successfully to your photo library!")
                    } else {
                        let message = error?.localizedDescription ?? "The image could not be saved to your photo library."
                        self.captureAlert = CalculatorCaptureAlert(
                            title: "Photos Access Denied",
                            message: message.isEmpty
                                ? "We need permission to save the image to your gallery. Please enable photo access in your iPhone's system settings."
                                : "We need permission to save the image to your gallery. Please enable photo access in your iPhone's system settings.",
                            kind: .photosAccessDenied
                        )
                    }
                }
            })
        }

        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            saveChanges()
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                switch status {
                case .authorized, .limited:
                    saveChanges()
                default:
                    DispatchQueue.main.async {
                        self.captureAlert = CalculatorCaptureAlert(
                            title: "Photos Access Denied",
                            message: "We need permission to save the image to your gallery. Please enable photo access in your iPhone's system settings.",
                            kind: .photosAccessDenied
                        )
                    }
                }
            }
        default:
            captureAlert = CalculatorCaptureAlert(
                title: "Photos Access Denied",
                message: "We need permission to save the image to your gallery. Please enable photo access in your iPhone's system settings.",
                kind: .photosAccessDenied
            )
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            captureAlert = CalculatorCaptureAlert(
                title: "Camera Unavailable",
                message: "This device does not have an available camera.",
                kind: .info
            )
            return
        }

        lastW2ScanSource = .camera
        isShowingCamera = true
    }

    private func openPhotoLibrary() {
        lastW2ScanSource = .photoLibrary
        isShowingPhotoLibrary = true
    }

    private func openFileImporter() {
        lastW2ScanSource = .file
        isShowingFileImporter = true
    }

    private func reopenLastScanSource() {
        switch lastW2ScanSource {
        case .camera:
            openCamera()
        case .photoLibrary:
            openPhotoLibrary()
        case .file:
            openFileImporter()
        }
    }

    private func processCapturedImage(_ image: UIImage, source: W2ScanSource) {
        isShowingCamera = false
        isShowingPhotoLibrary = false
        isRecognizingText = true
        lastW2ScanSource = source

        Task.detached(priority: .userInitiated) {
            let recognizedItems = await TextRecognizer.recognizeTextItems(in: image)
            let recognizedText = recognizedItems
                .map(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let extractedFields = W2FieldExtractor.extractFields(from: recognizedText, items: recognizedItems)
            let captureText = extractedFields.summaryText

            print(
                "[TaxAndFacts] W2 scan doc fetch: source=\(source == .camera ? "camera" : "photoLibrary") " +
                "recognizedItems=\(recognizedItems.count) " +
                "hasValues=\(extractedFields.hasAnyValue) " +
                "wages=\(extractedFields.wages ?? "nil")"
            )
            await MainActor.run { [recognizedText, extractedFields, captureText] in
                if !hasWagesValue(extractedFields) {
                    let alertTitle = captureAlertTitle(recognizedText: recognizedText, extractedFields: extractedFields)
                    let alertMessage = captureAlertMessage(recognizedText: recognizedText, extractedFields: extractedFields)

                    if alertTitle == "Unclear image" {
                        unclearImageAlert = CalculatorCaptureAlert(
                            title: alertTitle,
                            message: alertMessage,
                            kind: .documentNotRecognized
                        )
                    } else {
                        documentNotRecognizedAlert = CalculatorCaptureAlert(
                            title: alertTitle,
                            message: alertMessage,
                            kind: .documentNotRecognized
                        )
                    }
                } else if extractedFields.hasAnyValue {
                    if isDuplicateW2Document(extractedFields) {
                        captureAlert = CalculatorCaptureAlert(
                            title: "Duplicate document",
                            message: "This W-2 appears to match one you have already uploaded. Please upload a different W-2.",
                            kind: .duplicateDocument
                        )
                    } else {
                        captureManager.saveCapture(
                            pageTitle: currentTitle,
                            urlString: currentURLString,
                            recognizedText: captureText
                        )
                        pendingW2Documents.append(extractedFields)
                        uploadSuccessState = UploadSuccessState(documentNumber: pendingW2Documents.count)
                    }
                } else {
                    captureAlert = CalculatorCaptureAlert(
                        title: captureAlertTitle(recognizedText: recognizedText, extractedFields: extractedFields),
                        message: captureAlertMessage(recognizedText: recognizedText, extractedFields: extractedFields),
                        kind: .info
                    )
                }

                isRecognizingText = false
            }
        }
    }

    private func importSelectedFile(from url: URL) {
        isRecognizingText = true
        lastW2ScanSource = .photoLibrary

        Task.detached(priority: .userInitiated) { [url] in
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let image = Self.importedImage(from: url) else {
                await MainActor.run {
                    self.isRecognizingText = false
                    self.captureAlert = CalculatorCaptureAlert.info(
                        title: "Unable to Import",
                        message: "The selected file could not be read as an image or PDF."
                    )
                }
                return
            }

            await MainActor.run {
                self.processCapturedImage(image, source: .file)
            }
        }
    }

    private func beginW2Population() {
        guard !pendingW2Documents.isEmpty else { return }

        shouldPopulateQueuedW2Documents = true
        w2PopulateRequestID += 1
        uploadSuccessState = nil
    }

    private func finishAndCalculateTax() {
        uploadSuccessState = nil
        beginW2Population()
    }

    private func addAnotherW2() {
        uploadSuccessState = nil
        showCaptureOptions()
    }

    private func enterW2Manually() {
        uploadSuccessState = nil
    }

    private func removeUploadedW2() {
        guard !pendingW2Documents.isEmpty else {
            uploadSuccessState = nil
            return
        }

        pendingW2Documents.removeLast()
        uploadSuccessState = nil
        previousStepRequestID += 1
    }

    private func isDuplicateW2Document(_ extractedFields: W2ExtractedFields) -> Bool {
        pendingW2Documents.contains { existingFields in
            existingFields.duplicateComparisonKey == extractedFields.duplicateComparisonKey
        }
    }

    private func captureAlertTitle(recognizedText: String, extractedFields: W2ExtractedFields) -> String {
        if recognizedText.isEmpty {
            return "Unclear image"
        }

        if !hasWagesValue(extractedFields) {
            return "Document not recognized"
        }

        return extractedFields.hasAnyValue ? "W-2 Fields Saved" : "No W-2 Fields Found"
    }

    private func captureAlertMessage(recognizedText: String, extractedFields: W2ExtractedFields) -> String {
        if recognizedText.isEmpty {
            return "We couldn't read the text on your W-2. Please try again with a clearer photo or upload a digital PDF."
        }

        if !hasWagesValue(extractedFields) {
            return "We couldn't find a valid W-2 form in this file. Please make sure you are uploading an official W-2 tax document."
        }

        if !extractedFields.hasAnyValue {
            return "Readable text was found, but none of the required W-2 fields were detected."
        }

        return extractedFields.summaryText
    }

    private func hasWagesValue(_ extractedFields: W2ExtractedFields) -> Bool {
        guard let wages = extractedFields.wages?.trimmingCharacters(in: .whitespacesAndNewlines), !wages.isEmpty else {
            return false
        }

        return true
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
    @Binding var pendingW2Documents: [W2ExtractedFields]
    @Binding var w2PopulateRequestID: Int
    @Binding var shouldPopulateQueuedW2Documents: Bool
    @Binding var canGoBack: Bool
    @Binding var backRequestID: Int
    @Binding var previousStepRequestID: Int
    @Binding var isCalculatorStep2: Bool
    @Binding var isCalculatorStep4: Bool
    let resultPageCaptureController: ResultPageCaptureController
    let onNavigationFinished: (URL, Bool) -> Void
    let onW2PopulationSuccess: () -> Void
    let onShowCaptureOptions: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.calculatorStepMessageName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.calculatorResultMessageName)
        configuration.userContentController.add(context.coordinator, name: Coordinator.calculatorScanMessageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.allowsBackForwardNavigationGestures = true
        resultPageCaptureController.attach(webView: webView)
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

        if context.coordinator.handledPreviousStepRequestID != previousStepRequestID {
            context.coordinator.handledPreviousStepRequestID = previousStepRequestID
            DispatchQueue.main.async {
                context.coordinator.clickCalculatorPreviousButton(in: uiView)
            }
            return
        }

        if context.coordinator.loadedURL != url {
            uiView.load(request(for: url))
            context.coordinator.loadedURL = url
        }

        resultPageCaptureController.attach(webView: uiView)
        context.coordinator.installW2FieldPrefillSupport(into: uiView)
        context.coordinator.installW2ScanTargetButton(into: uiView)
        context.coordinator.updateCalculatorResultState(in: uiView)
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
        static let calculatorResultMessageName = "calculatorResult"
        static let calculatorScanMessageName = "calculatorScan"

        var parent: NativeWebViewWrapper
        var loadedURL: URL?
        var handledBackRequestID = 0
        var handledPreviousStepRequestID = 0
        var handledW2PopulateRequestID = -1
        var submittedW2PopulateRequestID = -1
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
            installW2ScanTargetButton(into: webView)
            updateCalculatorResultState(in: webView)
            installW2FieldPrefillSupport(into: webView)
            attemptW2FieldPrefill(in: webView)
            resetScrollPosition(in: webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.canGoBack = webView.canGoBack
            parent.isCalculatorStep2 = false
            parent.isCalculatorStep4 = false
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

            if message.name == Self.calculatorResultMessageName {
                if let isResultPage = message.body as? Bool {
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.isCalculatorStep4 = isResultPage
                    }
                }
                return
            }

            if message.name == Self.calculatorScanMessageName {
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onShowCaptureOptions()
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

                function containsStepFour(value) {
                    return /\bstep\s*4\b/.test(value) ||
                           /\b4\s*(of|\/)\s*\d+\b/.test(value) ||
                           value === '4';
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

                function detectStepFour() {
                    var activeSelectors = [
                        '[aria-current=\"step\"]',
                        '[aria-current=\"page\"]',
                        '[aria-selected=\"true\"]',
                        '[data-state=\"active\"]',
                        '[data-active=\"true\"]',
                        '.active',
                        '.current',
                        '.selected'
                    ];

                    for (var i = 0; i < activeSelectors.length; i++) {
                        var activeElements = document.querySelectorAll(activeSelectors[i]);

                        for (var j = 0; j < activeElements.length; j++) {
                            if (isVisible(activeElements[j]) && containsStepFour(cleanText(activeElements[j]))) {
                                return true;
                            }
                        }
                    }

                    var visibleHeadings = document.querySelectorAll('h1, h2, h3, h4, legend, [role=\"heading\"]');
                    for (var k = 0; k < visibleHeadings.length; k++) {
                        if (isVisible(visibleHeadings[k]) && containsStepFour(cleanText(visibleHeadings[k]))) {
                            return true;
                        }
                    }

                    return false;
                }

                function reportState() {
                    window.webkit.messageHandlers.calculatorStep.postMessage(detectStepTwo());
                    window.webkit.messageHandlers.calculatorResult.postMessage(detectStepFour());
                }

                if (!window.__taxFactsCalculatorStepObserverInstalled) {
                    window.__taxFactsCalculatorStepObserverInstalled = true;
                    window.__taxFactsReportCalculatorStep = reportState;

                    var scheduleReport = function() {
                        window.clearTimeout(window.__taxFactsCalculatorStepReportTimer);
                        window.__taxFactsCalculatorStepReportTimer = window.setTimeout(reportState, 80);
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

                window.__taxFactsReportCalculatorStep = reportState;
                reportState();
                window.setTimeout(reportState, 250);
                window.setTimeout(reportState, 750);
            })();
            """#

            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func updateCalculatorResultState(in webView: WKWebView) {
            let currentURLString = webView.url?.absoluteString ?? ""
            guard AppConfiguration.isCalculatorURL(currentURLString) else {
                parent.isCalculatorStep4 = false
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

                function containsStepFour(value) {
                    return /\bstep\s*4\b/.test(value) ||
                           /\b4\s*(of|\/)\s*\d+\b/.test(value) ||
                           value === '4';
                }

                function detectStepFour() {
                    var pageText = (document.body ? document.body.innerText : '')
                        .replace(/\s+/g, ' ')
                        .trim()
                        .toLowerCase();

                    if (pageText.includes('tax comparison') &&
                        pageText.includes('with obbba') &&
                        pageText.includes('without obbba')) {
                        return true;
                    }

                    if (pageText.includes('pending tax payable') ||
                        pageText.includes('federal tax paid') ||
                        pageText.includes('refund')) {
                        return true;
                    }

                    if (pageText.includes('step 4') || pageText.includes('4 of 4')) {
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
                            if (isVisible(activeElements[j]) && containsStepFour(cleanText(activeElements[j]))) {
                                return true;
                            }
                        }
                    }

                    var visibleHeadings = document.querySelectorAll('h1, h2, h3, h4, legend, [role="heading"]');
                    for (var k = 0; k < visibleHeadings.length; k++) {
                        if (isVisible(visibleHeadings[k]) && containsStepFour(cleanText(visibleHeadings[k]))) {
                            return true;
                        }
                    }

                    return false;
                }

                function hasVisibleText(value, selectors) {
                    for (var i = 0; i < selectors.length; i++) {
                        var elements = document.querySelectorAll(selectors[i]);

                        for (var j = 0; j < elements.length; j++) {
                            if (isVisible(elements[j]) && cleanText(elements[j]).indexOf(value) !== -1) {
                                return true;
                            }
                        }
                    }

                    return false;
                }

                function detectResultPage() {
                    if (detectStepFour()) {
                        return true;
                    }

                    var tableSelectors = ['table', 'tbody', 'tr', 'td', 'th'];
                    var headingSelectors = ['h1', 'h2', 'h3', 'h4', 'legend', '[role=\"heading\"]'];
                    var visibleTable = hasVisibleText('with obbba', tableSelectors) && hasVisibleText('without obbba', tableSelectors);
                    var resultHeading = hasVisibleText('tax comparison', headingSelectors);

                    if (!visibleTable || !resultHeading) {
                        return false;
                    }

                    return hasVisibleText('pending tax payable', tableSelectors) ||
                           hasVisibleText('refund', tableSelectors) ||
                           hasVisibleText('tax on income', tableSelectors) ||
                           hasVisibleText('federal tax paid', tableSelectors);
                }

                function reportResult() {
                    window.webkit.messageHandlers.calculatorResult.postMessage(detectResultPage());
                }

                if (!window.__taxFactsCalculatorResultObserverInstalled) {
                    window.__taxFactsCalculatorResultObserverInstalled = true;
                    window.__taxFactsReportCalculatorResult = reportResult;

                    var scheduleReport = function() {
                        window.clearTimeout(window.__taxFactsCalculatorResultReportTimer);
                        window.__taxFactsCalculatorResultReportTimer = window.setTimeout(reportResult, 80);
                    };

                    var observer = new MutationObserver(scheduleReport);
                    observer.observe(document.body || document.documentElement, {
                        attributes: true,
                        childList: true,
                        subtree: true
                    });

                    ['click', 'input', 'change', 'hashchange', 'popstate', 'scroll'].forEach(function(eventName) {
                        window.addEventListener(eventName, scheduleReport, true);
                    });
                }

                window.__taxFactsReportCalculatorResult = reportResult;
                reportResult();
                window.setTimeout(reportResult, 250);
                window.setTimeout(reportResult, 750);
            })();
            """#

            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func installW2ScanTargetButton(into webView: WKWebView) {
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

                function normalize(value) {
                    return (value || '')
                        .replace(/\s+/g, ' ')
                        .trim()
                        .toLowerCase();
                }

                function removeButton() {
                    var existing = document.getElementById('taxfacts-w2-scan-target');
                    if (existing && existing.parentNode) {
                        existing.parentNode.removeChild(existing);
                    }
                }

                function createButton(row) {
                    if (!row) {
                        return;
                    }

                    var existing = document.getElementById('taxfacts-w2-scan-target');
                    if (existing && existing.parentNode) {
                        existing.parentNode.removeChild(existing);
                    }

                    var buttonHost = document.createElement('span');
                    buttonHost.id = 'taxfacts-w2-scan-target';
                    buttonHost.style.cssText = 'position:absolute;left:15px;top:50%;transform:translateY(-50%);display:inline-flex;align-items:center;justify-content:center;margin:0;z-index:5;pointer-events:auto;';
                    buttonHost.innerHTML = '<button type="button" aria-label="Scan W-2" title="Scan W-2" style="appearance:none;-webkit-appearance:none;display:inline-flex;align-items:center;justify-content:center;width:20px;height:20px;padding:0;border:1px solid #000000;border-radius:50%;background:#000000;box-shadow:none;cursor:pointer;pointer-events:auto;vertical-align:middle;"><svg viewBox="0 0 24 24" aria-hidden="true" focusable="false" style="width:12.7px;height:12.7px;display:block;fill:none;stroke:#ffffff;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;"><path d="M12 4v10"></path><path d="M8.5 7.5L12 4l3.5 3.5"></path><path d="M5 14.5v3A2.5 2.5 0 0 0 7.5 20h9A2.5 2.5 0 0 0 19 17.5v-3"></path></svg></button><span style="margin-left:6px;color:#949494;font-size:9.83125px;line-height:1;vertical-align:middle;font-family:Montserrat, Arial, Verdana, sans-serif;">W2-Upload</span>';

                    var button = buttonHost.firstElementChild;
                    button.addEventListener('click', function(event) {
                        event.preventDefault();
                        event.stopPropagation();
                        try {
                            window.webkit.messageHandlers.calculatorScan.postMessage(true);
                        } catch (error) {}
                    });

                    row.insertAdjacentElement('afterbegin', buttonHost);
                }

                function refreshButton() {
                    if ((window.location.pathname || '').indexOf('/tax-calculator/') === -1) {
                        removeButton();
                        return;
                    }

                    var row = document.querySelector('#inn-tab1 .col-12.d-flex.align-items-center.position-relative');
                    if (!row) {
                        removeButton();
                        return;
                    }

                    var existing = document.getElementById('taxfacts-w2-scan-target');
                    if (existing && existing.parentNode === row && existing === row.firstChild) {
                        return;
                    }

                    removeButton();
                    createButton(row);
                }

                function scheduleRefresh() {
                    window.clearTimeout(window.__taxFactsW2ScanTargetTimer);
                    window.__taxFactsW2ScanTargetTimer = window.setTimeout(refreshButton, 80);
                }

                if (!window.__taxFactsW2ScanTargetInstalled) {
                    window.__taxFactsW2ScanTargetInstalled = true;
                    window.__taxFactsW2ScanTargetObserver = new MutationObserver(scheduleRefresh);
                    window.__taxFactsW2ScanTargetObserver.observe(document.body || document.documentElement, {
                        attributes: true,
                        childList: true,
                        subtree: true
                    });

                    ['input', 'change', 'hashchange', 'popstate'].forEach(function(eventName) {
                        window.addEventListener(eventName, scheduleRefresh, true);
                    });
                }

                refreshButton();
            })();
            """#

            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func clickCalculatorPreviousButton(in webView: WKWebView) {
            let script = #"""
            (function() {
                var selectors = [
                    'button.btn-prev.btn-wiz-prev',
                    'button[ng-click="tabChanged(1, 1)"]',
                    'button[ng-click*="tabChanged(1, 1)"]'
                ];

                for (var i = 0; i < selectors.length; i += 1) {
                    var button = document.querySelector(selectors[i]);
                    if (button) {
                        button.click();
                        return true;
                    }
                }

                return false;
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

                function logDebug() {}

                function fieldDefinitions() {
                    return [
                        {
                            key: 'wages',
                            modelName: 'wage',
                            ngModelPath: 'w2.wage',
                            exactMatchers: ['t01', 'w2.wage', 'Wages, Tips, Other compensations', 'Wages, tips, other comp.'],
                            patterns: [
                                'w2 wages tips other compensations',
                                'w2 wages tips other compensation',
                                'wages tips other compensations',
                                'wages tips other compensation',
                                'wages tips and other compensation',
                                'wages tips other comp',
                                'box 1 wages tips other compensation',
                                'box 1 wages tips other compensations'
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
                        var matches = queryAllAcrossDocuments('[ng-model="' + definition.ngModelPath + '"]');
                        if (matches && matches.length > 0) {
                            if (index >= 0 && index < matches.length) {
                                return matches[index];
                            }

                            return matches[0];
                        }

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

                function parseW2Amount(value) {
                    if (value === undefined || value === null) {
                        return 0;
                    }

                    var normalized = String(value).replace(/,/g, '').trim();
                    if (!normalized) {
                        return 0;
                    }

                    var parsed = parseFloat(normalized);
                    return isNaN(parsed) ? 0 : parsed;
                }

                function formatW2Amount(value) {
                    var parsed = typeof value === 'number' && isFinite(value) ? value : parseW2Amount(value);
                    return parsed.toFixed(2);
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

                function findScopeChainRoot(scope) {
                    var current = scope;
                    var lastMatch = null;

                    while (current) {
                        try {
                            if (current.data && (current.data.total || Array.isArray(current.data.wages))) {
                                lastMatch = current;
                            }
                        } catch (error) {
                        }

                        current = current.$parent || null;
                    }

                    return lastMatch || scope || null;
                }

                function syncW2SummaryValues(state, currentIndex) {
                    if (!state || !state.payloads || state.payloads.length === 0) {
                        logDebug('W2 summary sync skipped', 'reason=no-state-or-payloads');
                        return;
                    }

                    var maxIndex = typeof currentIndex === 'number' ? currentIndex : (state.payloads.length - 1);
                    if (maxIndex < 0) {
                        logDebug('W2 summary sync skipped', 'reason=invalid-index', 'currentIndex=' + String(currentIndex));
                        return;
                    }

                    var totals = {
                        wage: 0,
                        federal: 0,
                        medi: 0,
                        state: 0,
                        tip: 0,
                        overtime: 0
                    };

                    for (var i = 0; i <= maxIndex && i < state.payloads.length; i += 1) {
                        var entry = state.payloads[i] || {};
                        totals.wage += parseW2Amount(entry.wages);
                        totals.federal += parseW2Amount(entry.federalIncomeTaxWithheld);
                        totals.medi += parseW2Amount(entry.medicareWagesAndTips);
                        totals.state += parseW2Amount(entry.stateIncomeTaxWithheld);
                        totals.tip += parseW2Amount(entry.socialSecurityTips) + parseW2Amount(entry.allocatedTips);
                        totals.overtime += parseW2Amount(entry.overtime);
                    }

                    var rootScope = null;
                    try {
                        if (window.angular) {
                            var jq = window.angular.element(document.body || document.documentElement);
                            if (jq && typeof jq.scope === 'function') {
                                rootScope = jq.scope();
                            }
                            if (!rootScope && jq && typeof jq.isolateScope === 'function') {
                                rootScope = jq.isolateScope();
                            }
                        }
                    } catch (error) {
                        rootScope = null;
                    }

                    rootScope = findScopeChainRoot(rootScope);
                    if (!rootScope) {
                        logDebug('W2 summary sync scope missing', 'docIndex=' + String(maxIndex), 'payloadCount=' + String(state.payloads.length));
                        return;
                    }

                    var totalScope = null;
                    var scopeWalker = rootScope;
                    while (scopeWalker && !totalScope) {
                        if (scopeWalker.data && scopeWalker.data.total) {
                            totalScope = scopeWalker;
                            break;
                        }

                        scopeWalker = scopeWalker.$parent || null;
                    }

                    if (!totalScope) {
                        logDebug('W2 summary sync total scope missing', 'docIndex=' + String(maxIndex), 'hasRoot=' + String(!!rootScope));
                        return;
                    }

                    if (!totalScope.data.total) {
                        totalScope.data.total = {};
                    }

                    totalScope.data.total.wage = totals.wage;
                    totalScope.data.total.federal = totals.federal;
                    totalScope.data.total.medi = totals.medi;
                    totalScope.data.total.state = totals.state;
                    totalScope.data.total.tip = totals.tip;
                    totalScope.data.total.overtime = totals.overtime;
                    totalScope.data.total.tipMax = totals.tip;
                    totalScope.data.total.tipmax = totals.tip;
                    totalScope.data.total.overtimeMax = totals.overtime;

                    if (typeof totalScope.$applyAsync === 'function') {
                        totalScope.$applyAsync();
                    } else if (typeof totalScope.$apply === 'function') {
                        totalScope.$apply();
                    }

                    logDebug('W2 summary synced', 'docIndex=' + String(maxIndex), 'wage=' + String(totalScope.data.total.wage), 'federal=' + String(totalScope.data.total.federal), 'medi=' + String(totalScope.data.total.medi), 'state=' + String(totalScope.data.total.state), 'tip=' + String(totalScope.data.total.tip));
                    logDebug('W2 summary scope snapshot', 'docIndex=' + String(maxIndex), 'hasTotal=' + String(!!(totalScope.data && totalScope.data.total)), 'keys=' + Object.keys(totalScope.data.total || {}).join(','), 'raw=' + JSON.stringify(totalScope.data.total || {}));
                }

                function setAngularModelValue(definition, value, targetElement) {
                    if (!definition || !definition.ngModelPath) {
                        return false;
                    }

                    var targetCandidates = [];
                    if (targetElement) {
                        targetCandidates.push(targetElement);
                    }

                    var fallbackCandidates = queryAllAcrossDocuments('[ng-model="' + definition.ngModelPath + '"]');
                    if (fallbackCandidates && fallbackCandidates.length > 0) {
                        for (var f = 0; f < fallbackCandidates.length; f += 1) {
                            if (targetCandidates.indexOf(fallbackCandidates[f]) === -1) {
                                targetCandidates.push(fallbackCandidates[f]);
                            }
                        }
                    }

                    if (targetCandidates.length === 0) {
                        logDebug('W2 debug', definition.key, 'selector', definition.ngModelPath, 'candidates', '0');
                        return false;
                    }

                    var visibleCandidates = [];
                    for (var c = 0; c < targetCandidates.length; c += 1) {
                        if (isVisible(targetCandidates[c])) {
                            visibleCandidates.push(targetCandidates[c]);
                        }
                    }

                    var orderedCandidates = [];
                    if (targetElement) {
                        orderedCandidates.push(targetElement);
                    }

                    var candidatePool = visibleCandidates.length > 0 ? visibleCandidates : targetCandidates;
                    for (var p = 0; p < candidatePool.length; p += 1) {
                        if (orderedCandidates.indexOf(candidatePool[p]) === -1) {
                            orderedCandidates.push(candidatePool[p]);
                        }
                    }
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
                        String(visibleCandidates.length > 0),
                        'targetPreferred',
                        String(!!targetElement)
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

                    if (definition && definition.key === 'wages') {
                        logDebug('W2 wages bestCandidateForDefinition', 'candidateCount=' + String(candidates.length), 'bestMatch=' + String(!!bestMatch), 'bestScore=' + String(bestScore));
                        for (var n = 0; n < Math.min(candidates.length, 8); n += 1) {
                            var candidate = candidates[n];
                            logDebug(
                                'W2 wages candidate[' + String(n) + ']',
                                'text=' + candidateText(candidate),
                                'context=' + getElementContext(candidate),
                                'value=' + String(candidate.value || ''),
                                'class=' + String(candidate.className || ''),
                                'visible=' + String(isVisible(candidate)),
                                'disabled=' + String(!!candidate.disabled),
                                'readOnly=' + String(!!candidate.readOnly),
                                'rect=' + JSON.stringify((function() {
                                    try {
                                        var rect = candidate.getBoundingClientRect();
                                        return { top: rect.top, left: rect.left, width: rect.width, height: rect.height };
                                    } catch (error) {
                                        return null;
                                    }
                                })())
                            );
                        }
                    }

                    return bestMatch;
                }

                function currentDocumentIndex() {
                    return state && typeof state.documentIndex === 'number' ? state.documentIndex : 0;
                }

                function visibleW2Rows() {
                    return queryAllAcrossDocuments('[ng-repeat="w2 in data.wages"], [data-ng-repeat="w2 in data.wages"]').filter(function(row) {
                        return isVisible(row);
                    });
                }

                function rowContainerForDocumentIndex(index) {
                    var rows = visibleW2Rows();
                    if (!rows || rows.length === 0) {
                        return null;
                    }

                    if (index >= 0 && index < rows.length) {
                        return rows[index];
                    }

                    return rows[rows.length - 1];
                }

                function targetCandidateWithinRow(row, definition) {
                    if (!row || !definition || !definition.ngModelPath) {
                        return null;
                    }

                    var selectors = [
                        '[ng-model="' + definition.ngModelPath + '"]',
                        '[data-ng-model="' + definition.ngModelPath + '"]',
                        '[name="' + definition.modelName + '"]'
                    ];

                    for (var i = 0; i < selectors.length; i += 1) {
                        var rowTarget = row.querySelector(selectors[i]);
                        if (rowTarget) {
                            return rowTarget;
                        }
                    }

                    return null;
                }

                function candidatesForDefinition(definition) {
                    if (!definition || !definition.ngModelPath) {
                        return [];
                    }

                    return queryAllAcrossDocuments('[ng-model="' + definition.ngModelPath + '"], [data-ng-model="' + definition.ngModelPath + '"], [name="' + definition.modelName + '"]');
                }

                function exactModelCandidate(definition) {
                    var matches = candidatesForDefinition(definition);
                    for (var i = 0; i < matches.length; i += 1) {
                        if (matchesExactDefinition(matches[i], definition)) {
                            return matches[i];
                        }
                    }

                    return matches.length > 0 ? matches[0] : null;
                }

                function targetCandidateForDefinition(definition) {
                    var targetIndex = currentDocumentIndex();
                    var targetRow = rowContainerForDocumentIndex(targetIndex);
                    if (definition && definition.key === 'wages') {
                        logDebug(
                            'W2 wages targetCandidateForDefinition',
                            'docIndex=' + String(targetIndex),
                            'hasRow=' + String(!!targetRow),
                            'rowCount=' + String(visibleW2Rows().length),
                            'candidateCount=' + String(candidatesForDefinition(definition).length)
                        );
                    }
                    if (targetRow) {
                        var rowMatch = targetCandidateWithinRow(targetRow, definition);
                        if (rowMatch) {
                            if (definition && definition.key === 'wages') {
                                logDebug(
                                    'W2 wages row match',
                                    'label=' + candidateText(rowMatch),
                                    'context=' + getElementContext(rowMatch),
                                    'value=' + String(rowMatch.value || ''),
                                    'class=' + String(rowMatch.className || '')
                                );
                            }
                            return rowMatch;
                        }
                    }

                    var candidates = candidatesForDefinition(definition);
                    if (candidates.length > targetIndex) {
                        if (definition && definition.key === 'wages') {
                            logDebug(
                                'W2 wages index fallback',
                                'docIndex=' + String(targetIndex),
                                'selectedIndex=' + String(targetIndex),
                                'selectedLabel=' + candidateText(candidates[targetIndex]),
                                'selectedContext=' + getElementContext(candidates[targetIndex]),
                                'selectedValue=' + String(candidates[targetIndex].value || '')
                            );
                        }
                        return candidates[targetIndex];
                    }

                    var bestMatch = bestCandidateForDefinition(definition);
                    if (bestMatch) {
                        if (definition && definition.key === 'wages') {
                            logDebug(
                                'W2 wages best fallback',
                                'label=' + candidateText(bestMatch),
                                'context=' + getElementContext(bestMatch),
                                'value=' + String(bestMatch.value || ''),
                                'class=' + String(bestMatch.className || '')
                            );
                        }
                        return bestMatch;
                    }

                    var container = bestContainerForDefinition(definition);
                    if (container) {
                        var containerFields = Array.from(container.querySelectorAll('input, textarea, [contenteditable=\"true\"]')).filter(function(candidate) {
                            return isVisible(candidate) && !candidate.disabled && !candidate.readOnly;
                        });

                        for (var i = 0; i < containerFields.length; i += 1) {
                            if (definition && definition.key === 'wages') {
                                logDebug(
                                    'W2 wages container fallback',
                                    'container=' + String(container.tagName || ''),
                                    'fieldCount=' + String(containerFields.length),
                                    'selectedLabel=' + candidateText(containerFields[i]),
                                    'selectedContext=' + getElementContext(containerFields[i]),
                                    'selectedValue=' + String(containerFields[i].value || '')
                                );
                            }
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

                    logDebug('W2 fillField begin', definition.key, 'value=' + value, 'docIndex=' + String(currentDocumentIndex()));
                    var targetRow = rowContainerForDocumentIndex(currentDocumentIndex());
                    var rowCandidate = targetRow ? targetCandidateWithinRow(targetRow, definition) : null;
                    var bestMatch = targetCandidateForDefinition(definition);
                    if (!bestMatch && rowCandidate) {
                        bestMatch = rowCandidate;
                    }
                    if (!bestMatch) {
                        bestMatch = exactModelCandidate(definition);
                    }

                    if (!bestMatch) {
                        logDebug('W2 fill target not found for', definition.key, 'value', value);
                        return false;
                    }

                    logDebug('W2 fill target', definition.key, 'value', value, 'label', candidateText(bestMatch), 'context', getElementContext(bestMatch));

                    logDebug('W2 fillField resolved', definition.key, 'rowCandidate=' + String(!!rowCandidate), 'targetRow=' + String(!!targetRow));

                        var modelApplied = setAngularModelValue(definition, value, bestMatch);
                        var domApplied = false;
                        if (bestMatch.isContentEditable) {
                            domApplied = setEditableValue(bestMatch, value);
                    } else {
                        domApplied = setInputValue(bestMatch, value);
                    }

                    if (!modelApplied) {
                        modelApplied = setAngularModelValue(definition, value, bestMatch);
                    }

                    logDebug('W2 field applied', definition.key, 'model=' + String(modelApplied), 'dom=' + String(domApplied), 'value=' + value);
                    return modelApplied || domApplied || !!bestMatch;
                }

                function normalizePayloads(payload) {
                    if (!payload) { return []; }
                    if (Array.isArray(payload)) {
                        return payload.filter(function(item) {
                            return item && Object.keys(item).length > 0;
                        });
                    }

                    return Object.keys(payload).length > 0 ? [payload] : [];
                }

                function createState(payload) {
                    return {
                        payloads: normalizePayloads(payload),
                        payloadSignature: payloadSignature(payload),
                        documentIndex: 0,
                        nextIndex: 0,
                        lastAttemptAt: 0,
                        awaitingAnotherW2: false,
                        addAnotherRequestedForDocIndex: -1,
                        bootstrappedAdditionalRows: false
                    };
                }

                function payloadSignature(payload) {
                    var normalizedPayloads = normalizePayloads(payload);
                    var normalized = [];

                    for (var i = 0; i < normalizedPayloads.length; i += 1) {
                        var entry = normalizedPayloads[i] || {};
                        var keys = Object.keys(entry).sort();
                        var snapshot = {};

                        for (var k = 0; k < keys.length; k += 1) {
                            snapshot[keys[k]] = String(entry[keys[k]]);
                        }

                        normalized.push(snapshot);
                    }

                    return JSON.stringify(normalized);
                }

                function isStateComplete(state) {
                    return !state || !state.payloads || state.documentIndex >= state.payloads.length;
                }

                function clickAddAnotherW2() {
                    var controlSelectors = [
                        'button[ng-click="anotherWage()"]',
                        'button[data-ng-click="anotherWage()"]',
                        'button.clone-btn[ng-click="anotherWage()"]',
                        'button',
                        '[role=\"button\"]',
                        'a',
                        'input[type=\"button\"]',
                        'input[type=\"submit\"]'
                    ];

                    var controls = queryAllAcrossDocuments(controlSelectors.join(','));
                    var advanceLabels = ['add another w2', 'add another', 'another w2'];

                    for (var i = 0; i < controls.length; i += 1) {
                        var control = controls[i];
                        if (!isVisible(control) || control.disabled) {
                            continue;
                        }

                        var text = normalize(candidateText(control) + ' ' + elementText(control));
                        for (var j = 0; j < advanceLabels.length; j += 1) {
                            if (text.indexOf(advanceLabels[j]) !== -1) {
                                try {
                                    control.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, cancelable: true, view: window }));
                                    control.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
                                    control.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
                                    control.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
                                } catch (error) {
                                    control.click();
                                }

                                logDebug('W2 add another clicked', String(i), text);
                                return true;
                            }
                        }
                    }

                    var allElements = queryAllAcrossDocuments('*');
                    for (var k = 0; k < allElements.length; k += 1) {
                        var element = allElements[k];
                        if (!isVisible(element) || element.disabled) {
                            continue;
                        }

                        var elementTextValue = normalize(candidateText(element) + ' ' + elementText(element));
                        for (var m = 0; m < advanceLabels.length; m += 1) {
                            if (elementTextValue.indexOf(advanceLabels[m]) !== -1) {
                                try {
                                    element.dispatchEvent(new MouseEvent('pointerdown', { bubbles: true, cancelable: true, view: window }));
                                    element.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window }));
                                    element.dispatchEvent(new MouseEvent('mouseup', { bubbles: true, cancelable: true, view: window }));
                                    element.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
                                } catch (error) {
                                    try { element.click(); } catch (clickError) {}
                                }

                                logDebug('W2 add another clicked fallback', String(k), elementTextValue);
                                return true;
                            }
                        }
                    }

                    logDebug('W2 add another button not found');
                    return false;
                }

                function w2RowCount() {
                    return rowContainersForW2().length;
                }

                function attemptFill() {
                    var state = window.__taxFactsW2PrefillState;
                    if (!state || !state.payloads || state.documentIndex >= state.payloads.length) { return false; }

                    function visibleW2Rows() {
                        return queryAllAcrossDocuments('[ng-repeat="w2 in data.wages"], [data-ng-repeat="w2 in data.wages"]').filter(function(row) {
                            return isVisible(row);
                        });
                    }

                    function rowTargetForDocumentIndex(index) {
                        var rows = visibleW2Rows();
                        if (!rows || rows.length === 0) {
                            return null;
                        }

                        if (index >= 0 && index < rows.length) {
                            return rows[index];
                        }

                        return rows[rows.length - 1];
                    }

                    function rowTargetForDefinition(row, definition, index) {
                        var selectors = [
                            '[ng-model="' + definition.ngModelPath + '"]',
                            '[data-ng-model="' + definition.ngModelPath + '"]',
                            '[name="' + definition.modelName + '"]'
                        ];

                        if (row) {
                            for (var r = 0; r < selectors.length; r += 1) {
                                var rowTarget = row.querySelector(selectors[r]);
                                if (rowTarget) {
                                    return rowTarget;
                                }
                            }
                        }

                        return null;
                    }

                    function applyFieldValue(target, definition, numericValue, displayValue) {
                        if (!target || !definition || numericValue === undefined || numericValue === null) {
                            return false;
                        }

                        var modelApplied = false;
                        try {
                            modelApplied = setAngularModelValue(definition, numericValue, target);
                        } catch (error) {
                            logDebug('W2 model write error', definition.key, String(error));
                        }

                        var domApplied = false;
                        try {
                            if (target.isContentEditable) {
                                domApplied = setEditableValue(target, displayValue);
                            } else {
                                domApplied = setInputValue(target, displayValue);
                            }
                        } catch (error) {
                            logDebug('W2 DOM write error', definition.key, String(error));
                        }

                        return modelApplied || domApplied;
                    }

                    if (state.awaitingAnotherW2) {
                        var existingRows = visibleW2Rows();
                        if (existingRows.length > state.documentIndex + 1) {
                            state.documentIndex += 1;
                            state.nextIndex = 0;
                            state.awaitingAnotherW2 = false;
                            state.addAnotherRequestedForDocIndex = -1;
                        } else {
                            logDebug('W2 waiting for added row', 'currentDoc=' + String(state.documentIndex), 'rows=' + String(existingRows.length));
                            if (state.addAnotherRequestedForDocIndex !== state.documentIndex) {
                                state.addAnotherRequestedForDocIndex = state.documentIndex;
                                clickAddAnotherW2();
                            } else {
                                logDebug('W2 add another already requested', 'currentDoc=' + String(state.documentIndex));
                            }
                            window.setTimeout(scheduleAttempt, 250);
                            return false;
                        }
                    }

                    var payload = state.payloads[state.documentIndex];
                    if (!payload) { return false; }

                    logDebug('W2 attemptFill start', 'docIndex=' + String(state.documentIndex), 'nextIndex=' + String(state.nextIndex), 'payloadKeys=' + Object.keys(payload).join(','));
                    logDebug('W2 payload keys', Object.keys(payload).join(','), JSON.stringify(payload));
                    logDebug('W2 payload doc snapshot', 'docIndex=' + String(state.documentIndex), JSON.stringify(payload));

                    var orderedKeys = [
                        'wages',
                        'federalIncomeTaxWithheld',
                        'medicareWagesAndTips',
                        'stateIncomeTaxWithheld',
                        'socialSecurityTips',
                        'allocatedTips'
                    ];
                    var definitionsByKey = {};
                    var definitions = fieldDefinitions();
                    var currentRow = rowTargetForDocumentIndex(state.documentIndex);
                    var filledCount = 0;
                    var hasTipValues = !!payload && (
                        Object.prototype.hasOwnProperty.call(payload, 'socialSecurityTips') ||
                        Object.prototype.hasOwnProperty.call(payload, 'allocatedTips')
                    );

                    logDebug('W2 current row', 'docIndex=' + String(state.documentIndex), 'rowCount=' + String(visibleW2Rows().length), 'hasRow=' + String(!!currentRow));
                    if (currentRow) {
                        try {
                            var rowScopeBefore = getTargetScope(currentRow);
                            logDebug('W2 row scope before fill', 'docIndex=' + String(state.documentIndex), 'hasScope=' + String(!!rowScopeBefore), 'raw=' + JSON.stringify(rowScopeBefore && rowScopeBefore.data && rowScopeBefore.data.w2 ? rowScopeBefore.data.w2 : {}));
                        } catch (rowScopeError) {
                            logDebug('W2 row scope before fill error', String(rowScopeError));
                        }
                    }

                    if (hasTipValues && currentRow) {
                        var rowScope = getTargetScope(currentRow);
                        if (rowScope && rowScope.data) {
                            rowScope.data.checkTip = true;
                            if (rowScope.w2 && typeof rowScope.w2 === 'object') {
                                rowScope.w2.checkTip = true;
                            }
                            if (rowScope.w2 && (rowScope.w2.overtime === undefined || rowScope.w2.overtime === null || String(rowScope.w2.overtime).trim() === '')) {
                                rowScope.w2.overtime = '0.00';
                            }
                            if (rowScope.data.w2 && (rowScope.data.w2.overtime === undefined || rowScope.data.w2.overtime === null || String(rowScope.data.w2.overtime).trim() === '')) {
                                rowScope.data.w2.overtime = '0.00';
                            }
                            if (rowScope.data && Array.isArray(rowScope.data.wages)) {
                                var wageRow = rowScope.data.wages[state.documentIndex];
                                if (wageRow && typeof wageRow === 'object') {
                                    wageRow.checkTip = true;
                                }
                                if (wageRow && (wageRow.overtime === undefined || wageRow.overtime === null || String(wageRow.overtime).trim() === '')) {
                                    wageRow.overtime = '0.00';
                                }
                            }
                            if (typeof rowScope.$applyAsync === 'function') {
                                rowScope.$applyAsync();
                            } else if (typeof rowScope.$apply === 'function') {
                                rowScope.$apply();
                            }
                            logDebug('W2 tip section enabled', 'docIndex=' + String(state.documentIndex), 'rowCheckTip=' + String(!!(rowScope.w2 && rowScope.w2.checkTip)), 'dataCheckTip=' + String(!!rowScope.data.checkTip));
                        }
                    }

                    for (var d = 0; d < definitions.length; d += 1) {
                        definitionsByKey[definitions[d].key] = definitions[d];
                    }

                    for (var i = 0; i < orderedKeys.length; i += 1) {
                        var key = orderedKeys[i];
                        var rawValue = payload && Object.prototype.hasOwnProperty.call(payload, key) ? payload[key] : null;
                        if (rawValue === undefined || rawValue === null || rawValue === '') {
                            continue;
                        }

                        var numericValue = typeof rawValue === 'number' ? rawValue : parseW2Amount(rawValue);
                        if (!isFinite(numericValue)) {
                            continue;
                        }

                        var displayValue = formatW2Amount(numericValue);

                        var definition = definitionsByKey[key];
                        if (!definition) {
                            continue;
                        }

                        var target = rowTargetForDefinition(currentRow, definition, state.documentIndex);
                        if (!target) {
                            logDebug('W2 target missing', key, 'docIndex=' + String(state.documentIndex));
                            continue;
                        }

                        logDebug('W2 target chosen', key, 'docIndex=' + String(state.documentIndex), 'label=' + candidateText(target), 'context=' + getElementContext(target));
                        var applied = applyFieldValue(target, definition, numericValue, displayValue);
                        logDebug('W2 field applied', key, 'applied=' + String(applied), 'numeric=' + String(numericValue), 'display=' + displayValue);
                        if (applied) {
                            filledCount += 1;
                        }
                    }

                    if (filledCount === 0) {
                        logDebug('W2 fill produced no applied fields', 'docIndex=' + String(state.documentIndex), 'payload=' + JSON.stringify(payload || {}));
                        window.setTimeout(scheduleAttempt, 250);
                        return false;
                    }

                    syncW2SummaryValues(state, state.documentIndex);

                    try {
                        if (currentRow) {
                            var rowScopeAfter = getTargetScope(currentRow);
                            logDebug('W2 row scope after fill', 'docIndex=' + String(state.documentIndex), 'hasScope=' + String(!!rowScopeAfter), 'raw=' + JSON.stringify(rowScopeAfter && rowScopeAfter.data && rowScopeAfter.data.w2 ? rowScopeAfter.data.w2 : {}));
                        }
                    } catch (rowScopeAfterError) {
                        logDebug('W2 row scope after fill error', String(rowScopeAfterError));
                    }

                    if (state.documentIndex + 1 < state.payloads.length) {
                        if (!state.awaitingAnotherW2) {
                            state.awaitingAnotherW2 = true;
                            state.addAnotherRequestedForDocIndex = state.documentIndex;
                            logDebug('W2 auto advance to next W2', 'currentDoc=' + String(state.documentIndex), 'nextDoc=' + String(state.documentIndex + 1));
                            clickAddAnotherW2();
                        }

                        window.setTimeout(scheduleAttempt, 250);
                        return false;
                    }

                    state.documentIndex += 1;
                    state.nextIndex = 0;
                    if (state.documentIndex >= state.payloads.length) {
                        window.clearInterval(window.__taxFactsW2PrefillInterval);
                        window.__taxFactsW2PrefillInterval = null;
                    }
                    return true;
                }

                function scheduleAttempt() {
                    window.clearTimeout(window.__taxFactsW2PrefillTimer);
                    window.__taxFactsW2PrefillTimer = window.setTimeout(attemptFill, 120);
                }

                window.__taxFactsSetPendingW2Fill = function(payload) {
                    var payloadCount = String(Array.isArray(payload) ? payload.length : (payload ? 1 : 0));

                    logDebug('W2 setPendingFill', 'payloadCount=' + payloadCount, JSON.stringify(payload || {}));
                    window.clearInterval(window.__taxFactsW2PrefillInterval);
                    window.__taxFactsW2PrefillInterval = null;
                    window.clearTimeout(window.__taxFactsW2PrefillTimer);
                    window.__taxFactsW2PrefillTimer = null;
                    window.__taxFactsW2PrefillState = createState(payload || null);
                    if (window.__taxFactsW2PrefillState.payloads.length > 1 && !window.__taxFactsW2PrefillState.bootstrappedAdditionalRows) {
                        window.__taxFactsW2PrefillState.bootstrappedAdditionalRows = true;
                        logDebug('W2 bootstrap multi-doc queue', 'payloadCount=' + String(window.__taxFactsW2PrefillState.payloads.length));
                    }
                    window.clearInterval(window.__taxFactsW2PrefillInterval);
                    window.__taxFactsW2PrefillInterval = window.setInterval(attemptFill, 350);
                    scheduleAttempt();
                    return attemptFill();
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
                  !parent.pendingW2Documents.isEmpty,
                  parent.shouldPopulateQueuedW2Documents,
                  AppConfiguration.isCalculatorURL(parent.currentURLString) else {
                return
            }

            guard let payloadJSON = jsonObjectString(from: w2PayloadArray(from: parent.pendingW2Documents)) else {
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
            let requestID = parent.w2PopulateRequestID
            let shouldSubmitPayload = submittedW2PopulateRequestID != requestID
            let script = shouldSubmitPayload ? """
            (function(payload) {
                try {
                    if (window.__taxFactsSetPendingW2Fill) {
                        return window.__taxFactsSetPendingW2Fill(payload);
                    }

                    return false;
                } catch (error) {
                    return false;
                }
            })(\(payloadJSON));
            """ : """
            (function() {
                try {
                    var state = window.__taxFactsW2PrefillState;
                    if (!state || !state.payloads) {
                        return false;
                    }

                    return state.documentIndex >= state.payloads.length;
                } catch (error) {
                    return false;
                }
            })();
            """

            webView.evaluateJavaScript(script) { [weak self] result, error in
                guard let self else { return }

                if let error {
                    _ = error
                }

                if shouldSubmitPayload {
                    self.submittedW2PopulateRequestID = requestID
                    return
                }

                if let success = result as? Bool, success {
                    self.handledW2PopulateRequestID = self.parent.w2PopulateRequestID
                    self.parent.pendingW2Documents = []
                    self.parent.shouldPopulateQueuedW2Documents = false
                    self.submittedW2PopulateRequestID = -1
                    self.stopW2PrefillRetryLoop()
                    self.parent.onW2PopulationSuccess()
                }
            }
        }

        private func stopW2PrefillRetryLoop(keepPayload: Bool = false) {
            w2PrefillRetryTimer?.invalidate()
            w2PrefillRetryTimer = nil
            w2PrefillRetryCount = 0

            if !keepPayload {
                parent.pendingW2Documents = []
                parent.shouldPopulateQueuedW2Documents = false
                submittedW2PopulateRequestID = -1
            }
        }

        private func w2PayloadDictionary(from fields: W2ExtractedFields) -> [String: Any] {
            var payload: [String: Any] = [:]

            if let value = numericOnlyDouble(fields.wages) {
                payload["wages"] = value
            }

            if let value = numericOnlyDouble(fields.federalIncomeTaxWithheld) {
                payload["federalIncomeTaxWithheld"] = value
            }

            if let value = numericOnlyDouble(fields.medicareWagesAndTips) {
                payload["medicareWagesAndTips"] = value
            }

            if let value = numericOnlyDouble(fields.stateIncomeTaxWithheld) {
                payload["stateIncomeTaxWithheld"] = value
            }

            if let value = numericOnlyDouble(fields.socialSecurityTips) {
                payload["socialSecurityTips"] = value
            } else {
                payload["socialSecurityTips"] = 0.0
            }

            if let value = numericOnlyDouble(fields.allocatedTips) {
                payload["allocatedTips"] = value
            } else {
                payload["allocatedTips"] = 0.0
            }

            return payload
        }

        private func w2PayloadArray(from documents: [W2ExtractedFields]) -> [[String: Any]] {
            documents.map { w2PayloadDictionary(from: $0) }.filter { !$0.isEmpty }
        }

        private func numericOnlyDouble(_ value: String?) -> Double? {
            let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedValue.isEmpty else { return nil }

            let allowedCharacters = CharacterSet(charactersIn: "0123456789.,-")
            let filtered = trimmedValue.unicodeScalars.filter { allowedCharacters.contains($0) }
            let result = String(String.UnicodeScalarView(filtered)).replacingOccurrences(of: ",", with: "")
            guard !result.isEmpty else { return nil }
            return Double(result)
        }

        private func jsonObjectString(from object: Any) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
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
    let onBrowseArticles: () -> Void
    @State private var pendingRemovalArticle: SavedArticle?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isOffline ? "Offline Saved" : "Saved Content")
                        .font(.title2.weight(.semibold))

                    Text("Your saved articles are kept here for 15 days for offline reading.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Group {
                    if manager.articles.isEmpty {
                        VStack(spacing: 0) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)

                            Text("No saved articles yet")
                                .font(.headline)
                                .multilineTextAlignment(.center)

                            Text("Tap the \"Save for offline\" ribbon on any article to download it and read it here later without internet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 6)

                            Button {
                                onBrowseArticles()
                            } label: {
                                Text("Browse Articles")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color(red: 1.0, green: 0.749, blue: 0.027))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                                    onDelete: { pendingRemovalArticle = article }
                                )
                            }
                            .onDelete(perform: manager.deleteArticles)
                        }
                        .listStyle(.insetGrouped)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .alert(item: $pendingRemovalArticle) { article in
                Alert(
                    title: Text("Remove from offline?"),
                    message: Text("This article will no longer be available to read without internet access."),
                    primaryButton: .destructive(Text("Remove"), action: {
                        manager.deleteArticle(id: article.id)
                    }),
                    secondaryButton: .cancel(Text("Keep"))
                )
            }
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
            Label(isSaved ? "Saved offline" : "Read offline", systemImage: isSaved ? "bookmark.fill" : "bookmark")
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

private struct ResultPageSaveButton: View {
    let isSaving: Bool
    let action: () -> Void

    var body: some View {
        FloatingActionButton(
            title: "Save",
            systemImage: "square.and.arrow.down",
            isProcessing: isSaving,
            processingLabel: "Saving result page",
            restingLabel: "Save result page",
            action: action
        )
    }
}

private struct FloatingActionButton: View {
    let title: String
    let systemImage: String
    let isProcessing: Bool
    let processingLabel: String
    let restingLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(title, systemImage: systemImage)
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
        .accessibilityLabel(isProcessing ? processingLabel : restingLabel)
    }
}

private struct CameraCaptureView: UIViewControllerRepresentable {
    let onImageCaptured: (UIImage) -> Void
    let onPermissionDenied: () -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> CameraCaptureViewController {
        CameraCaptureViewController(
            onImageCaptured: { image in
                onImageCaptured(image)
                dismiss()
            },
            onPermissionDenied: {
                dismiss()
                onPermissionDenied()
            },
            onCancel: {
                dismiss()
            }
        )
    }

    func updateUIViewController(_ uiViewController: CameraCaptureViewController, context: Context) {}
}

private struct PDFExportPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let onExportCompleted: () -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .formSheet
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onExportCompleted: onExportCompleted, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onExportCompleted: () -> Void
        let onCancel: () -> Void

        init(onExportCompleted: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.onExportCompleted = onExportCompleted
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            DispatchQueue.main.async {
                self.onExportCompleted()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DispatchQueue.main.async {
                self.onCancel()
            }
        }
    }
}

private final class CameraCaptureViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    private let onImageCaptured: (UIImage) -> Void
    private let onPermissionDenied: () -> Void
    private let onCancel: () -> Void
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "TaxAndFacts.CameraSession")
    private let photoOutput = AVCapturePhotoOutput()
    private let previewView = CameraPreviewView()
    private let captureButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var hasConfiguredSession = false
    private var sessionRunning = false

    init(
        onImageCaptured: @escaping (UIImage) -> Void,
        onPermissionDenied: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onImageCaptured = onImageCaptured
        self.onPermissionDenied = onPermissionDenied
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureInterface()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestAccessIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureInterface() {
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = .black
        view.addSubview(previewView)

        let controlsStack = UIStackView()
        controlsStack.axis = .vertical
        controlsStack.alignment = .center
        controlsStack.spacing = 16
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsStack)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true

        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.setImage(UIImage(systemName: "circle.inset.filled"), for: .normal)
        captureButton.tintColor = .white
        captureButton.backgroundColor = .clear
        captureButton.contentEdgeInsets = .zero
        captureButton.addTarget(self, action: #selector(capturePhoto), for: .touchUpInside)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        controlsStack.addArrangedSubview(captureButton)
        controlsStack.addArrangedSubview(cancelButton)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            controlsStack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            controlsStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            controlsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            controlsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            captureButton.widthAnchor.constraint(equalToConstant: 76),
            captureButton.heightAnchor.constraint(equalToConstant: 76)
        ])

        if let previewLayer = previewView.previewLayer {
            previewLayer.videoGravity = .resizeAspect
        }
    }

    private func requestAccessIfNeeded() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureSessionIfNeeded()
                    } else {
                        self.cancelButton.setTitle("Close", for: .normal)
                        self.onPermissionDenied()
                    }
                }
            }
        case .denied, .restricted:
            cancelButton.setTitle("Close", for: .normal)
            onPermissionDenied()
        @unknown default:
            cancelButton.setTitle("Close", for: .normal)
        }
    }

    private func configureSessionIfNeeded() {
        guard !hasConfiguredSession else {
            startSession()
            return
        }

        hasConfiguredSession = true

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            } else if self.session.canSetSessionPreset(.hd1280x720) {
                self.session.sessionPreset = .hd1280x720
            } else if self.session.canSetSessionPreset(.photo) {
                self.session.sessionPreset = .photo
            }

            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.statusLabel.text = "Unable to start camera."
                    self.cancelButton.setTitle("Close", for: .normal)
                }
                return
            }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }

            if self.session.canAddInput(input) {
                self.session.addInput(input)
            }

            self.photoOutput.isHighResolutionCaptureEnabled = true
            self.session.commitConfiguration()

            DispatchQueue.main.async {
                self.previewView.setSession(self.session)
                self.startSession()
            }
        }
    }

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.sessionRunning else { return }
            self.session.startRunning()
            self.sessionRunning = true
        }
    }

    private func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.sessionRunning else { return }
            self.session.stopRunning()
            self.sessionRunning = false
        }
    }

    @objc private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        settings.isHighResolutionPhotoEnabled = true
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    @objc private func cancelTapped() {
        onCancel()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            return
        }

        onImageCaptured(image)
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    func setSession(_ session: AVCaptureSession) {
        previewLayer?.session = session
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

private enum W2FieldExtractor {
    private struct FieldSpec {
        let labels: [String]
        let preferLargestNumericValue: Bool
    }

    private struct CandidateValue {
        let value: String
        let score: CGFloat
        let numericValue: Double
    }

    private static let wagesSpec = FieldSpec(labels: [
        "box 1 wages tips other compensation",
        "1 wages tips other compensation",
        "w2 wages tips other compensation",
        "w2 wages tips other compensations",
        "w2 wage tips other compensation",
        "w2 wage tips other compensations",
        "wages tips and other comp",
        "wages tips, other comp.",
        "wages tips and other compensation",
        "wages tips and other compensations",
        "wages tips other comp",
        "wages tips other compensation",
        "wages tips other compensations",
        "wage tips and other comp",
        "wage tips and other compensation",
        "wage tips other comp",
        "wage tips other compensation"
    ], preferLargestNumericValue: true)

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
    ], preferLargestNumericValue: false)

    private static let medicareSpec = FieldSpec(labels: [
        "box 5 medicare wages and tips",
        "5 medicare wages and tips",
        "medicare wages and tips",
        "medicare wages tips",
        "medicare wages",
        "madicare wages and tips",
        "madicare wages tips"
    ], preferLargestNumericValue: false)

    private static let socialSecurityTipsSpec = FieldSpec(labels: [
        "box 7 social security tips",
        "box 7 social security tip",
        "box7 social security tips",
        "box7 social security tip",
        "7 social security tips",
        "7 social security tip",
        "social security tips",
        "social security tip"
    ], preferLargestNumericValue: false)

    private static let allocatedTipsSpec = FieldSpec(labels: [
        "box 8 allocated tips",
        "box 8 allocated tip",
        "box8 allocated tips",
        "box8 allocated tip",
        "8 allocated tips",
        "8 allocated tip",
        "allocated tips",
        "allocated tip"
    ], preferLargestNumericValue: false)

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
    ], preferLargestNumericValue: false)

    private static let einSpec = FieldSpec(labels: [
        "employer identification number",
        "employer identification no",
        "employer id number",
        "employer id no",
        "employer ein",
        "ein"
    ], preferLargestNumericValue: false)

    private static var allTargetLabels: [String] {
        [wagesSpec, federalTaxSpec, medicareSpec, socialSecurityTipsSpec, allocatedTipsSpec, stateTaxSpec, einSpec].flatMap(\.labels)
    }

    static func extractFields(from text: String, items: [RecognizedTextItem] = []) -> W2ExtractedFields {
        let fallbackFields = extractFieldsFromText(text)
        let extractedFields = W2ExtractedFields(
            employerIdentificationNumber: extractEmployerIdentificationNumber(from: text) ?? fallbackFields.employerIdentificationNumber,
            wages: extractPositionedValue(from: items, spec: wagesSpec, minimumWholeDollarDigits: 1) ?? fallbackFields.wages,
            federalIncomeTaxWithheld: extractPositionedValue(from: items, spec: federalTaxSpec) ?? fallbackFields.federalIncomeTaxWithheld,
            medicareWagesAndTips: extractPositionedValue(from: items, spec: medicareSpec) ?? fallbackFields.medicareWagesAndTips,
            stateIncomeTaxWithheld: extractPositionedValue(from: items, spec: stateTaxSpec, minimumWholeDollarDigits: 3) ?? fallbackFields.stateIncomeTaxWithheld,
            socialSecurityTips: extractPositionedValue(from: items, spec: socialSecurityTipsSpec, minimumWholeDollarDigits: 4, treatAsTipField: true) ?? fallbackFields.socialSecurityTips,
            allocatedTips: extractPositionedValue(from: items, spec: allocatedTipsSpec, minimumWholeDollarDigits: 4, treatAsTipField: true) ?? fallbackFields.allocatedTips
        )

        return extractedFields
    }

    private static func extractFieldsFromText(_ text: String) -> W2ExtractedFields {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        debugMatchingTipLabels(in: lines, label: "text")

        return W2ExtractedFields(
            employerIdentificationNumber: extractEmployerIdentificationNumber(from: text) ?? extractEmployerIdentificationNumber(from: lines),
            wages: extractValueAfterLabel(from: lines, spec: wagesSpec, minimumWholeDollarDigits: 1),
            federalIncomeTaxWithheld: extractValueAfterLabel(from: lines, spec: federalTaxSpec),
            medicareWagesAndTips: extractValueAfterLabel(from: lines, spec: medicareSpec),
            stateIncomeTaxWithheld: extractValueAfterLabel(from: lines, spec: stateTaxSpec, minimumWholeDollarDigits: 3),
            socialSecurityTips: extractValueAfterLabelStrict(from: lines, spec: socialSecurityTipsSpec, minimumWholeDollarDigits: 3),
            allocatedTips: extractValueAfterLabelStrict(from: lines, spec: allocatedTipsSpec, minimumWholeDollarDigits: 3)
        )
    }

    private static func extractEmployerIdentificationNumber(from text: String) -> String? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return extractEmployerIdentificationNumber(from: lines)
    }

    private static func extractEmployerIdentificationNumber(from lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }

        for (lineIndex, line) in lines.enumerated() where matchesFieldLabel(line, spec: einSpec) {
            let currentText = textAfterBestLabel(in: line, labels: einSpec.labels)
            if let value = firstEmployerIdentificationNumber(in: currentText) {
                return value
            }

            let searchEndIndex = lines[(lineIndex + 1)...].firstIndex { candidateLine in
                let normalized = normalizedSearchText(candidateLine)
                return containsAnyLabel(normalized, labels: allTargetLabels) || containsIgnoredW2Label(candidateLine)
            } ?? lines.endIndex

            for candidateLine in lines[(lineIndex + 1)..<searchEndIndex] {
                if let value = firstEmployerIdentificationNumber(in: candidateLine) {
                    return value
                }
            }
        }

        for line in lines {
            if let value = firstEmployerIdentificationNumber(in: line) {
                return value
            }
        }

        return nil
    }

    private static func firstEmployerIdentificationNumber(in text: String) -> String? {
        let digitsOnly = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        guard digitsOnly.count >= 9 else { return nil }

        let value = String(digitsOnly.prefix(9))
        guard value.count == 9 else { return nil }
        return "\(value.prefix(2))-\(value.suffix(7))"
    }

    private static func debugMatchingTipLabels(in lines: [String], label: String) {
    }

    private static func extractPositionedValue(from items: [RecognizedTextItem], spec: FieldSpec, minimumWholeDollarDigits: Int = 1) -> String? {
        extractPositionedValue(from: items, spec: spec, minimumWholeDollarDigits: minimumWholeDollarDigits, treatAsTipField: false)
    }

    private static func extractPositionedValue(
        from items: [RecognizedTextItem],
        spec: FieldSpec,
        minimumWholeDollarDigits: Int,
        treatAsTipField: Bool
    ) -> String? {
        guard !items.isEmpty else { return nil }

        for (labelIndex, labelItem) in items.enumerated() where matchesFieldLabel(labelItem.text, spec: spec) {
            let isWagesField = spec.labels == wagesSpec.labels
            let isStateField = spec.labels == stateTaxSpec.labels
            let preferLargestValue = !isWagesField && spec.preferLargestNumericValue
            var debugCandidates: [CandidateValue] = []

            if isWagesField {
                let spatialCandidates = items.compactMap { item -> CandidateValue? in
                    guard item != labelItem,
                          !containsAnyLabel(item.text, labels: allTargetLabels),
                          !containsIgnoredW2Label(item.text),
                          let value = bestCurrencyValue(
                            in: normalizedSearchText(item.text),
                            allowsWholeDollars: true,
                            preferLargestValue: true
                          ),
                          isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) else {
                        return nil
                    }

                    let candidate = item.boundingBox
                    let label = labelItem.boundingBox
                    let isBelowLabel = candidate.midY <= label.midY - 0.01
                    let isInLeftColumn = abs(candidate.midX - label.midX) <= max(CGFloat(0.20), label.width * 1.25)
                    guard isBelowLabel, isInLeftColumn else {
                        return nil
                    }

                    let score = abs(candidate.midY - label.maxY) + abs(candidate.midX - label.midX) * 0.5
                    return CandidateValue(value: value, score: score, numericValue: Double(value) ?? 0)
                }

                if let bestSpatialValue = selectCandidateValue(from: spatialCandidates, preferLargestValue: false)?.value {
                    if isWagesField {
                        debugWagesExtraction(
                            labelItem: labelItem,
                            textAfterLabel: textAfterBestLabel(in: labelItem.text, labels: spec.labels),
                            candidateRange: Array(items),
                            candidates: spatialCandidates,
                            selectedValue: bestSpatialValue
                        )
                    } else if isStateField {
                        debugStateExtraction(
                            labelItem: labelItem,
                            candidateRange: Array(items),
                            candidates: spatialCandidates,
                            selectedValue: bestSpatialValue,
                            branch: "spatial"
                        )
                    }
                    return bestSpatialValue
                }
            } else if isStateField {
                let spatialCandidates = items.compactMap { item -> CandidateValue? in
                    guard item != labelItem,
                          !containsAnyLabel(item.text, labels: allTargetLabels),
                          !containsIgnoredW2Label(item.text),
                          let value = bestCurrencyValue(
                            in: normalizedSearchText(item.text),
                            allowsWholeDollars: true,
                            preferLargestValue: false
                          ),
                          isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) else {
                        return nil
                    }

                    let candidate = item.boundingBox
                    let label = labelItem.boundingBox
                    let isBelowLabel = candidate.midY <= label.midY - 0.01
                    let isNearColumn = abs(candidate.midX - label.midX) <= max(CGFloat(0.22), label.width * 1.25)
                    guard isBelowLabel, isNearColumn else {
                        return nil
                    }

                    let score = abs(candidate.midY - label.midY) + abs(candidate.midX - label.midX) * 0.5
                    return CandidateValue(value: value, score: score, numericValue: Double(value) ?? 0)
                }

                if let bestSpatialValue = selectCandidateValue(from: spatialCandidates, preferLargestValue: false)?.value {
                    debugStateExtraction(
                        labelItem: labelItem,
                        candidateRange: Array(items),
                        candidates: spatialCandidates,
                        selectedValue: bestSpatialValue,
                        branch: "spatial"
                    )
                    return bestSpatialValue
                }
            }

            if let value = bestCurrencyValue(
                in: textAfterBestLabel(in: labelItem.text, labels: spec.labels),
                allowsWholeDollars: true,
                preferLargestValue: preferLargestValue
            ),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                if isStateField {
                    debugStateExtraction(
                        labelItem: labelItem,
                        candidateRange: Array(items),
                        candidates: [],
                        selectedValue: value,
                        branch: "inline"
                    )
                }
                return value
            }

            let searchEndIndex = items[(labelIndex + 1)...].firstIndex { item in
                let normalized = normalizedSearchText(item.text)
                return containsAnyLabel(normalized, labels: allTargetLabels) || containsIgnoredW2Label(item.text)
            } ?? items.endIndex
            let candidateRange = items[(labelIndex + 1)..<searchEndIndex]

            let candidates = candidateRange.compactMap { item -> CandidateValue? in
                guard !containsAnyLabel(item.text, labels: allTargetLabels),
                      !containsIgnoredW2Label(item.text),
                      let value = bestCurrencyValue(
                        in: normalizedSearchText(item.text),
                        allowsWholeDollars: true,
                        preferLargestValue: preferLargestValue
                      ),
                      isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) else {
                    return nil
                }

                let lowerBoundaryY = nextLowerW2LabelBoundaryY(in: items, below: labelItem.boundingBox)
                guard isLikelySameW2Box(candidate: item.boundingBox, label: labelItem.boundingBox, lowerBoundaryY: lowerBoundaryY) else {
                    return nil
                }

                let score = spatialScore(candidate: item.boundingBox, label: labelItem.boundingBox)
                return CandidateValue(value: value, score: score, numericValue: Double(value) ?? 0)
            }

            if isWagesField {
                debugCandidates = candidates
            }

            if let bestValue = selectCandidateValue(from: candidates, preferLargestValue: preferLargestValue)?.value {
                if isWagesField {
                    debugWagesExtraction(
                        labelItem: labelItem,
                        textAfterLabel: textAfterBestLabel(in: labelItem.text, labels: spec.labels),
                        candidateRange: Array(candidateRange),
                        candidates: candidates,
                        selectedValue: bestValue
                    )
                } else if isStateField {
                    debugStateExtraction(
                        labelItem: labelItem,
                        candidateRange: Array(candidateRange),
                        candidates: candidates,
                        selectedValue: bestValue,
                        branch: "candidateRange"
                    )
                }
                return bestValue
            }

            if !treatAsTipField,
               let relaxedValue = relaxedNearbyCurrencyValue(
                    from: items,
                    label: labelItem.boundingBox,
                    minimumWholeDollarDigits: minimumWholeDollarDigits,
                    preferLargestValue: preferLargestValue
               ) {
                if isWagesField {
                    debugWagesExtraction(
                        labelItem: labelItem,
                        textAfterLabel: textAfterBestLabel(in: labelItem.text, labels: spec.labels),
                        candidateRange: Array(candidateRange),
                        candidates: debugCandidates,
                        selectedValue: relaxedValue,
                        usedRelaxedFallback: true
                    )
                } else if isStateField {
                    debugStateExtraction(
                        labelItem: labelItem,
                        candidateRange: Array(candidateRange),
                        candidates: debugCandidates,
                        selectedValue: relaxedValue,
                        branch: "relaxed"
                    )
                }
                return relaxedValue
            }

            if isWagesField {
                debugWagesExtraction(
                    labelItem: labelItem,
                    textAfterLabel: textAfterBestLabel(in: labelItem.text, labels: spec.labels),
                    candidateRange: Array(candidateRange),
                    candidates: candidates,
                    selectedValue: nil
                )
            } else if isStateField {
                debugStateExtraction(
                    labelItem: labelItem,
                    candidateRange: Array(candidateRange),
                    candidates: candidates,
                    selectedValue: nil,
                    branch: "none"
                )
            }
        }

        return nil
    }

    private static func isStandaloneNumericLine(_ text: String) -> Bool {
        let normalizedText = normalizedSearchText(text)
        guard !normalizedText.isEmpty else { return false }

        let hasLetters = normalizedText.range(of: #"[a-z]"#, options: .regularExpression) != nil
        guard !hasLetters else { return false }

        return firstCurrencyValue(in: normalizedText, allowsWholeDollars: true) != nil
    }

    private static func extractValueAfterLabel(from lines: [String], spec: FieldSpec, minimumWholeDollarDigits: Int = 1) -> String? {
        for lineIndex in lines.indices {
            let normalizedLine = normalizedSearchText(lines[lineIndex])
            guard matchesFieldLabel(normalizedLine, spec: spec) else {
                continue
            }

            if let value = bestCurrencyValue(
                in: textAfterBestLabel(in: lines[lineIndex], labels: spec.labels),
                allowsWholeDollars: true,
                preferLargestValue: spec.labels == wagesSpec.labels ? false : spec.preferLargestNumericValue
            ),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }

            let nextLineIndex = lines.index(after: lineIndex)
            if nextLineIndex < lines.endIndex,
               !containsAnyLabel(lines[nextLineIndex], labels: allTargetLabels),
               !containsIgnoredW2Label(lines[nextLineIndex]),
               let value = bestCurrencyValue(
                in: normalizedSearchText(lines[nextLineIndex]),
                allowsWholeDollars: true,
                preferLargestValue: spec.labels == wagesSpec.labels ? false : spec.preferLargestNumericValue
               ),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }

            let secondNextLineIndex = lines.index(after: nextLineIndex)
            if secondNextLineIndex < lines.endIndex,
               !containsAnyLabel(lines[secondNextLineIndex], labels: allTargetLabels),
               !containsIgnoredW2Label(lines[secondNextLineIndex]),
               let value = bestCurrencyValue(
                in: normalizedSearchText(lines[secondNextLineIndex]),
                allowsWholeDollars: true,
                preferLargestValue: spec.labels == wagesSpec.labels ? false : spec.preferLargestNumericValue
               ),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }
        }

        return nil
    }

    private static func extractValueAfterLabelStrict(from lines: [String], spec: FieldSpec, minimumWholeDollarDigits: Int = 1) -> String? {
        for (lineIndex, line) in lines.enumerated() {
            let normalizedLine = normalizedSearchText(line)
            guard matchesFieldLabel(normalizedLine, spec: spec) else {
                continue
            }

            if let value = bestCurrencyValue(
                in: textAfterBestLabel(in: line, labels: spec.labels),
                allowsWholeDollars: true,
                preferLargestValue: spec.labels == wagesSpec.labels ? false : spec.preferLargestNumericValue
            ),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }

            let nextLineIndex = lines.index(after: lineIndex)
            if nextLineIndex < lines.endIndex,
               !containsAnyLabel(lines[nextLineIndex], labels: allTargetLabels),
               !containsIgnoredW2Label(lines[nextLineIndex]),
               isStandaloneNumericLine(lines[nextLineIndex]),
               let value = bestCurrencyValue(
                in: normalizedSearchText(lines[nextLineIndex]),
                allowsWholeDollars: true,
                preferLargestValue: spec.labels == wagesSpec.labels ? false : spec.preferLargestNumericValue
               ),
               isAcceptableCurrencyValue(value, minimumWholeDollarDigits: minimumWholeDollarDigits) {
                return value
            }

            let secondNextLineIndex = lines.index(after: nextLineIndex)
            if secondNextLineIndex < lines.endIndex,
               !containsAnyLabel(lines[secondNextLineIndex], labels: allTargetLabels),
               !containsIgnoredW2Label(lines[secondNextLineIndex]),
               isStandaloneNumericLine(lines[secondNextLineIndex]),
               let value = bestCurrencyValue(
                in: normalizedSearchText(lines[secondNextLineIndex]),
                allowsWholeDollars: true,
                preferLargestValue: spec.labels == wagesSpec.labels ? false : spec.preferLargestNumericValue
               ),
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
        let isSameOrBelowLabel = candidateMidY <= labelMidY - 0.01
        let isNearVertically = candidateMidY >= labelMidY - 0.20
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

    private static func matchesFieldLabel(_ text: String, spec: FieldSpec) -> Bool {
        let normalizedText = normalizedSearchText(text)

        let normalizedSpecLabels = normalizedLabels(spec.labels)

        if spec.preferLargestNumericValue {
            let containsActualWageLabel = normalizedSpecLabels.contains { normalizedText.contains($0) }
            let looksLikeTotalSummary = normalizedText.contains("total") && normalizedText.contains("wages") && normalizedText.contains("comp")
            return containsActualWageLabel && !looksLikeTotalSummary
        }

        return normalizedSpecLabels.contains { normalizedText.contains($0) }
    }

    private static func containsAnyLabel(_ text: String, labels: [String]) -> Bool {
        let normalizedText = normalizedSearchText(text)
        return normalizedLabels(labels).contains { normalizedText.contains($0) }
    }

    private static let ignoredW2Labels: [String] = [
        "social security",
        "social security number",
        "social security tax withheld",
        "social security wages",
        "total wages tips and other comp",
        "total wages tips and other compensation",
        "total wages tips and other compensations",
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

    private static func normalizedLabels(_ labels: [String]) -> [String] {
        labels.map { text in
            text
                .lowercased()
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: #"[^a-z0-9.$]+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func firstCurrencyValue(in text: String, allowsWholeDollars: Bool = false) -> String? {
        currencyValues(in: text, allowsWholeDollars: allowsWholeDollars).first
    }

    private static func bestCurrencyValue(in text: String, allowsWholeDollars: Bool = false, preferLargestValue: Bool = false) -> String? {
        let values = currencyValues(in: text, allowsWholeDollars: allowsWholeDollars)
        guard !values.isEmpty else { return nil }

        if preferLargestValue {
            return values.max { left, right in
                (Double(left) ?? 0) < (Double(right) ?? 0)
            }
        }

        return values.first
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
        minimumWholeDollarDigits: Int,
        preferLargestValue: Bool
    ) -> String? {
        let relaxedCandidates = items.compactMap { item -> CandidateValue? in
            guard !containsAnyLabel(item.text, labels: allTargetLabels),
                  !containsIgnoredW2Label(item.text),
                  let value = bestCurrencyValue(
                    in: normalizedSearchText(item.text),
                    allowsWholeDollars: true,
                    preferLargestValue: preferLargestValue
                  ),
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
            return CandidateValue(value: value, score: score, numericValue: Double(value) ?? 0)
        }

        return selectCandidateValue(from: relaxedCandidates, preferLargestValue: preferLargestValue)?.value
    }

    private static func selectCandidateValue(from candidates: [CandidateValue], preferLargestValue: Bool) -> CandidateValue? {
        guard !candidates.isEmpty else { return nil }

        if preferLargestValue {
            return candidates.max { left, right in
                if left.numericValue == right.numericValue {
                    return left.score > right.score
                }

                return left.numericValue < right.numericValue
            }
        }

        return candidates.min(by: { $0.score < $1.score })
    }

    private static func debugWagesExtraction(
        labelItem: RecognizedTextItem,
        textAfterLabel: String,
        candidateRange: [RecognizedTextItem],
        candidates: [CandidateValue],
        selectedValue: String?,
        usedRelaxedFallback: Bool = false
    ) {
    }

    private static func debugStateExtraction(
        labelItem: RecognizedTextItem,
        candidateRange: [RecognizedTextItem],
        candidates: [CandidateValue],
        selectedValue: String?,
        branch: String
    ) {
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

private struct SavedArticleDetailView: View {
    let article: SavedArticle
    let isOffline: Bool
    let onClose: () -> Void

    var body: some View {
        Group {
            if article.htmlString.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "No internet connection",
                        systemImage: "wifi.slash",
                        description: Text("This article hasn't been saved for offline reading. Please connect to the internet to view it.")
                    )

                    Button("Close", action: onClose)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.accentColor, in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ZStack(alignment: .top) {
                    OfflineHTMLView(htmlString: article.htmlString, baseURLString: article.urlString)

                    if isOffline {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                            Text("Reading offline")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.78), in: Capsule())
                        .padding(.top, 12)
                    }
                }
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

 #if false
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
            navigationButton(title: "Saved offline", systemImage: "bookmark", action: onSaved)
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

#endif

#Preview {
    ContentView()
}
