import SwiftUI
import UniformTypeIdentifiers

// MARK: - FileTransferView
//
// 文件选择 + 发送确认页
// 支持多选，显示文件名/大小，确认后回调给 RemoteSession.sendFiles

struct FileTransferView: View {

    let onSend: ([URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedURLs: [URL]   = []
    @State private var showPicker            = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient.lrBgGradient.ignoresSafeArea()

                VStack(spacing: 20) {
                    // 说明卡片
                    infoCard

                    // 已选文件列表
                    if !selectedURLs.isEmpty {
                        fileList
                    }

                    // 选择按钮
                    selectButton

                    // 发送按钮
                    if !selectedURLs.isEmpty {
                        sendButton
                    }

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("发送文件到 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(Color.lrAccent)
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker(selectedURLs: $selectedURLs)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.lrAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text("文件将保存到 Mac 的下载文件夹")
                    .font(.lrBodyMedium)
                    .foregroundStyle(Color.lrTextPrimary)
                Text("~/Downloads  |  通过 TCP 局域网传输")
                    .font(.lrCaption)
                    .foregroundStyle(Color.lrTextTertiary)
            }
            Spacer()
        }
        .padding(16)
        .liquidGlass(cornerRadius: 14)
    }

    // MARK: - File List

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已选择 \(selectedURLs.count) 个文件")
                    .font(.lrCaption)
                    .foregroundStyle(Color.lrTextTertiary)
                Spacer()
                Button("清空") {
                    withAnimation(.spring(bounce: 0.2)) { selectedURLs.removeAll() }
                }
                .font(.lrButtonSmall)
                .foregroundStyle(Color.lrRed)
            }

            VStack(spacing: 6) {
                ForEach(selectedURLs, id: \.self) { url in
                    FileRow(url: url) {
                        withAnimation { selectedURLs.removeAll { $0 == url } }
                    }
                }
            }
        }
    }

    // MARK: - Buttons

    private var selectButton: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17, weight: .medium))
                Text(selectedURLs.isEmpty ? "选择文件" : "继续添加文件")
                    .font(.lrButton)
            }
            .foregroundStyle(Color.lrAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .liquidGlass(cornerRadius: 14, borderOpacity: 0.7, tint: Color.lrAccent)
        }
    }

    private var sendButton: some View {
        Button {
            onSend(selectedURLs)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("发送 \(selectedURLs.count) 个文件")
                    .font(.lrButton)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(LinearGradient.lrAccentGradient)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.lrAccent.opacity(0.4), radius: 10, x: 0, y: 4)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - FileRow

private struct FileRow: View {
    let url:      URL
    let onRemove: () -> Void

    private var fileSize: String {
        guard let attrs  = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size   = attrs[.size] as? Int64 else { return "未知大小" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private var fileIcon: String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv":                   return "video"
        case "mp3", "aac", "wav", "flac":                  return "music.note"
        case "pdf":                                         return "doc.richtext"
        case "zip", "gz", "tar", "rar":                    return "archivebox"
        case "swift", "kt", "py", "js", "ts":              return "chevron.left.forwardslash.chevron.right"
        default:                                            return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fileIcon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.lrAccent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.lrBodyMedium)
                    .foregroundStyle(Color.lrTextPrimary)
                    .lineLimit(1)
                Text(fileSize)
                    .font(.lrMono)
                    .foregroundStyle(Color.lrTextTertiary)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.lrRed.opacity(0.8))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 12)
    }
}

// MARK: - DocumentPicker (UIKit wrapper)

private struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var selectedURLs: [URL]
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: true
        )
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .formSheet
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            // 追加（去重）
            for url in urls {
                if !parent.selectedURLs.contains(url) {
                    parent.selectedURLs.append(url)
                }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
