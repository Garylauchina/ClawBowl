import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import Speech
import AVFoundation

/// 底部聊天输入栏（支持图片、文件附件、语音输入、引用回复）
struct ChatInputBar: View {
    @Binding var text: String
    @Binding var selectedAttachment: Attachment?
    @Binding var replyingTo: Message?
    let isLoading: Bool
    let onSend: () -> Void
    var onStop: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var showImagePicker = false
    @State private var showDocumentPicker = false
    @State private var showFileTooLargeAlert = false
    @State private var rejectedFileName = ""

    // ── 语音输入状态 ──
    @StateObject private var speechManager = SpeechRecognitionManager()

    /// 文件大小限制 100MB（与 Cloudflare 免费版上限对齐，base64 编码后 ≈133MB）
    private let maxFileSize = 100 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            // 引用回复预览条
            if let reply = replyingTo {
                replyPreview(reply)
            }

            // 附件预览条
            if let att = selectedAttachment {
                attachmentPreview(att)
            }

            // 录音状态提示条
            if speechManager.isRecording {
                recordingIndicator
            }

            // 输入行
            HStack(alignment: .bottom, spacing: 6) {
                // 图片选择按钮
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: selectedAttachment?.isImage == true ? "photo.fill" : "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(selectedAttachment?.isImage == true ? .blue : .secondary)
                        .frame(width: 32, height: 36)
                }
                .disabled(isLoading || speechManager.isRecording)

                // 文件选择按钮（回形针）
                Button {
                    showDocumentPicker = true
                } label: {
                    Image(systemName: selectedAttachment != nil && !(selectedAttachment!.isImage) ? "paperclip.circle.fill" : "paperclip")
                        .font(.system(size: 20))
                        .foregroundStyle(selectedAttachment != nil && !(selectedAttachment!.isImage) ? .blue : .secondary)
                        .frame(width: 32, height: 36)
                }
                .disabled(isLoading || speechManager.isRecording)

                // 输入框
                TextField(inputPlaceholder, text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .focused($isFocused)
                    .disabled(isLoading)
                    .onSubmit {
                        if canSend && !isLoading {
                            onSend()
                        }
                    }
                    .onChange(of: isFocused) { _, focused in
                        if focused { checkPasteboardForImage() }
                    }

                // Stop / 发送 / 语音 按钮（智能切换）
                if isLoading {
                    // AI 处理中 → Stop 按钮
                    Button {
                        onStop?()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.red)
                    }
                } else if canSend {
                    // 有内容时显示发送按钮
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.blue)
                    }
                } else {
                    // 无内容时显示语音按钮（按住说话，松开停止）
                    Image(systemName: speechManager.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 20))
                        .foregroundStyle(speechManager.isRecording ? .red : .secondary)
                        .frame(width: 34, height: 34)
                        .background(speechManager.isRecording ? Color.red.opacity(0.15) : Color.clear)
                        .clipShape(Circle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    if !speechManager.isRecording {
                                        speechManager.startRecording()
                                    }
                                }
                                .onEnded { _ in
                                    if speechManager.isRecording {
                                        speechManager.stopRecording()
                                    }
                                }
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(attachment: $selectedAttachment)
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(
                attachment: $selectedAttachment,
                maxFileSize: maxFileSize,
                onFileTooLarge: { filename in
                    rejectedFileName = filename
                    showFileTooLargeAlert = true
                }
            )
        }
        .alert("文件过大", isPresented: $showFileTooLargeAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("\"\(rejectedFileName)\" 超过 100MB 限制，请选择较小的文件。")
        }
        .alert("粘贴图片", isPresented: $showPasteImageAlert) {
            Button("粘贴") {
                if let img = UIPasteboard.general.image {
                    let maxDim: CGFloat = 512
                    var sz = img.size
                    if max(sz.width, sz.height) > maxDim {
                        let scale = maxDim / max(sz.width, sz.height)
                        sz = CGSize(width: sz.width * scale, height: sz.height * scale)
                    }
                    let renderer = UIGraphicsImageRenderer(size: sz)
                    let resized = renderer.image { _ in img.draw(in: CGRect(origin: .zero, size: sz)) }
                    if let data = resized.jpegData(compressionQuality: 0.4) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedAttachment = Attachment(
                                filename: "paste_\(UUID().uuidString.prefix(8)).jpg",
                                data: data,
                                mimeType: "image/jpeg"
                            )
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("剪贴板中有图片，是否粘贴为附件？")
        }
        .alert("无法使用语音", isPresented: $speechManager.showPermissionAlert) {
            Button("去设置", role: .none) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(speechManager.permissionMessage)
        }
        .onChange(of: speechManager.transcribedText) { _, newValue in
            if !newValue.isEmpty {
                text = newValue
            }
        }
    }

    // MARK: - 录音状态指示条

    private var recordingIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .opacity(speechManager.isRecording ? 1 : 0)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: speechManager.isRecording)
            Text("正在听取，松开结束")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.systemGray6).opacity(0.5))
    }

    private var inputPlaceholder: String {
        if isLoading { return "AI 正在处理..." }
        if speechManager.isRecording { return "语音识别中..." }
        return "输入消息..."
    }

    /// 引用回复预览条
    private func replyPreview(_ msg: Message) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.blue)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(msg.role == .user ? "你" : "AI 助手")
                    .font(.caption2.bold())
                    .foregroundColor(.blue)
                Text(msg.quotePreview)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    replyingTo = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.systemGray6).opacity(0.5))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 附件预览条（图片缩略图 或 文件图标+文件名）
    @ViewBuilder
    private func attachmentPreview(_ att: Attachment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if att.isImage, let uiImage = UIImage(data: att.data) {
                // 图片缩略图
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // 文件图标
                Image(systemName: fileIcon(for: att.mimeType))
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                    .frame(width: 60, height: 60)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(att.isImage ? "已选择图片" : att.filename)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(att.isImage ? "发送后将由 AI 分析" : att.formattedSize)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedAttachment = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemGray6).opacity(0.5))
    }

    /// Detect image in pasteboard when input becomes focused
    @State private var showPasteImageAlert = false

    private func checkPasteboardForImage() {
        guard selectedAttachment == nil,
              UIPasteboard.general.hasImages,
              UIPasteboard.general.image != nil else { return }
        showPasteImageAlert = true
    }

    /// 有文字或有附件即可发送（isLoading 时由 Stop 按钮接管，不走此分支）
    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachment = selectedAttachment != nil
        return hasText || hasAttachment
    }

    /// 根据 MIME type 返回合适的 SF Symbol
    private func fileIcon(for mimeType: String) -> String {
        switch mimeType {
        case let m where m.contains("pdf"):
            return "doc.richtext"
        case let m where m.contains("word") || m.contains("document"):
            return "doc.text"
        case let m where m.contains("spreadsheet") || m.contains("excel"):
            return "tablecells"
        case let m where m.contains("presentation") || m.contains("powerpoint"):
            return "rectangle.split.3x3"
        case let m where m.contains("text") || m.contains("json") || m.contains("xml") || m.contains("csv"):
            return "doc.plaintext"
        case let m where m.contains("zip") || m.contains("archive") || m.contains("compressed"):
            return "doc.zipper"
        case let m where m.contains("audio"):
            return "waveform"
        case let m where m.contains("video"):
            return "film"
        default:
            return "doc"
        }
    }
}

// MARK: - PHPicker 封装（图片选择器）

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var attachment: Attachment?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()

            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }

            provider.loadObject(ofClass: UIImage.self) { object, _ in
                if let uiImage = object as? UIImage {
                    // 压缩为 JPEG
                    let maxDim: CGFloat = 512
                    var targetSize = uiImage.size
                    if max(targetSize.width, targetSize.height) > maxDim {
                        let scale = maxDim / max(targetSize.width, targetSize.height)
                        targetSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
                    }
                    let renderer = UIGraphicsImageRenderer(size: targetSize)
                    let resized = renderer.image { _ in
                        uiImage.draw(in: CGRect(origin: .zero, size: targetSize))
                    }
                    guard let jpegData = resized.jpegData(compressionQuality: 0.4) else { return }

                    let att = Attachment(
                        filename: "photo_\(UUID().uuidString.prefix(8)).jpg",
                        data: jpegData,
                        mimeType: "image/jpeg"
                    )
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.parent.attachment = att
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Document Picker 封装（通用文件选择器）

struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var attachment: Attachment?
    let maxFileSize: Int
    var onFileTooLarge: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            // 获取安全访问权限
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)

                // 检查文件大小
                guard data.count <= parent.maxFileSize else {
                    let filename = url.lastPathComponent
                    DispatchQueue.main.async {
                        self.parent.onFileTooLarge?(filename)
                    }
                    return
                }

                let filename = url.lastPathComponent
                let mimeType = Self.mimeType(for: url)

                let att = Attachment(
                    filename: filename,
                    data: data,
                    mimeType: mimeType
                )
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.parent.attachment = att
                    }
                }
            } catch {
                // 读取失败，忽略
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // 取消时不做任何操作
        }

        /// 根据文件 URL 推断 MIME type
        static func mimeType(for url: URL) -> String {
            if let utType = UTType(filenameExtension: url.pathExtension) {
                return utType.preferredMIMEType ?? "application/octet-stream"
            }
            return "application/octet-stream"
        }
    }
}

// MARK: - Speech Recognition Manager

/// 语音识别管理器：使用 iOS Speech 框架进行本地实时转写
/// 支持"按住说话、松开停止"模式：
///   - startRecording() 异步请求权限后开始录音
///   - stopRecording() 立即停止；如果录音尚未开始（权限回调中），标记 pendingStop
///   - beginRecording() 检查 pendingStop，若已松手则不启动
class SpeechRecognitionManager: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    @Published var showPermissionAlert = false
    @Published var permissionMessage = ""

    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isInitialized = false

    /// 关键：用户已松手但权限回调还没返回时，标记为 true
    private var pendingStop = false

    private func ensureInitialized() {
        guard !isInitialized else { return }
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        audioEngine = AVAudioEngine()
        isInitialized = true
    }

    func startRecording() {
        pendingStop = false  // 清除上次残留的停止标记

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 权限回调返回时，检查用户是否已经松手
                if self.pendingStop { return }

                switch status {
                case .authorized:
                    self.checkMicrophoneAndStart()
                case .denied, .restricted:
                    self.permissionMessage = "请在系统设置中允许 ClawBowl 使用语音识别功能。"
                    self.showPermissionAlert = true
                case .notDetermined:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func checkMicrophoneAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.pendingStop { return }

                if granted {
                    self.beginRecording()
                } else {
                    self.permissionMessage = "请在系统设置中允许 ClawBowl 使用麦克风。"
                    self.showPermissionAlert = true
                }
            }
        }
    }

    private func beginRecording() {
        // 再次检查：用户可能在极短间隔内松手
        if pendingStop {
            pendingStop = false
            return
        }

        ensureInitialized()

        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            permissionMessage = "语音识别服务暂不可用，请稍后再试。"
            showPermissionAlert = true
            return
        }

        guard let audioEngine = audioEngine else { return }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }

        recognitionRequest.shouldReportPartialResults = true

        if speechRecognizer.supportsOnDeviceRecognition {
            recognitionRequest.requiresOnDeviceRecognition = true
        }

        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                DispatchQueue.main.async {
                    self.transcribedText = result.bestTranscription.formattedString
                }
            }

            if error != nil || (result?.isFinal ?? false) {
                DispatchQueue.main.async {
                    self.stopAudioEngine()
                    self.isRecording = false
                }
            }
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.transcribedText = ""
                self.isRecording = true
            }
        } catch {
            stopAudioEngine()
        }
    }

    func stopRecording() {
        pendingStop = true  // 无论录音是否已开始，都标记

        if isRecording {
            // 录音已在进行，正常停止
            recognitionRequest?.endAudio()
            stopAudioEngine()
            DispatchQueue.main.async {
                self.isRecording = false
            }
        }
        // 如果 isRecording == false，说明权限回调还没返回，
        // pendingStop 会在回调中阻止录音启动
    }

    private func stopAudioEngine() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest = nil
        recognitionTask = nil
    }
}

#Preview {
    VStack {
        Spacer()
        ChatInputBar(text: .constant(""), selectedAttachment: .constant(nil), replyingTo: .constant(nil), isLoading: false, onSend: {})
        ChatInputBar(text: .constant(""), selectedAttachment: .constant(nil), replyingTo: .constant(nil), isLoading: true, onSend: {}, onStop: {})
    }
}
