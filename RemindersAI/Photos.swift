import PhotosUI
import SwiftUI
import UIKit

/// A photo picked for the next message, already shrunk for upload.
struct PendingPhoto: Identifiable, Equatable {
    let id = UUID()
    let jpeg: Data
    let thumbnail: UIImage
}

enum PhotoPrep {
    /// The longest side Claude reads at full detail; larger images are scaled down by the API anyway.
    static let maxSide: CGFloat = 1568

    /// A JPEG of at most `maxSide` pixels on the long side, and a small thumbnail.
    nonisolated static func prepare(_ image: UIImage) -> PendingPhoto? {
        let scaled = resized(image, maxSide: maxSide)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.8) else { return nil }
        return PendingPhoto(jpeg: jpeg, thumbnail: resized(image, maxSide: 240))
    }

    nonisolated static func prepare(_ data: Data) -> PendingPhoto? {
        UIImage(data: data).flatMap(prepare)
    }

    nonisolated private static func resized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // Drawing also bakes in the photo's orientation, which JPEG export would otherwise keep as metadata.
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// The system camera, for taking a photo to add to a message. iPhone only.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Photos already sent, fetched from the server once and kept for the session.
@MainActor
final class AttachmentImages {
    static let shared = AttachmentImages()
    private var cache: [String: UIImage] = [:]

    func image(_ id: String, session: Session) async -> UIImage? {
        if let cached = cache[id] { return cached }
        guard let data = try? await session.data("/api/attachments/\(id)"), let image = UIImage(data: data) else { return nil }
        cache[id] = image
        return image
    }

    func clear() { cache = [:] }
}

/// A sent photo in the conversation; tap to see it full size.
struct AttachmentThumbnail: View {
    let attachment: Attachment
    @Environment(Session.self) private var session
    @State private var image: UIImage?
    @State private var showingFull = false

    var body: some View {
        Button {
            if image != nil { showingFull = true }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemFill))
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo")
        .task(id: attachment.id) { image = await AttachmentImages.shared.image(attachment.id, session: session) }
        .fullScreenCover(isPresented: $showingFull) {
            if let image { PhotoViewer(image: image) }
        }
    }
}

struct PhotoViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(zoom)
                .gesture(MagnifyGesture().onChanged { zoom = max(1, min($0.magnification, 5)) }.onEnded { _ in
                    withAnimation { if zoom < 1.1 { zoom = 1 } }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .topBarLeading) {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Photo", image: Image(uiImage: image)))
                    }
                }
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
