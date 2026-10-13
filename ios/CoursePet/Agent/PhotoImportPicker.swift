// MARK: - 拍照 / 相册选图导入课表
// 替代 PhotosPicker：PhotosPicker 在 iOS 16.1 偶发"点了啥都没出"，
// 这里用 UIKit 老 API（UIImagePickerController），iOS 13+ 稳如狗。
// 用法：父视图直接用 .photoImportSheet(onPicked:) 修饰符。
import SwiftUI
import UIKit

extension View {
    /// 弹出「拍照 / 从相册选」选择 → 走 UIImagePickerController → 拿到 UIImage
    /// - Parameters:
    ///   - isPresented: 绑定控制弹层显隐
    ///   - onPicked: 拿到图后回调（父视图负责调 Vision 识别）
    func photoImportSheet(
        isPresented: Binding<Bool>,
        onPicked: @escaping (UIImage) -> Void
    ) -> some View {
        self
            .modifier(PhotoImportSheetModifier(isPresented: isPresented, onPicked: onPicked))
    }
}

private struct PhotoImportSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onPicked: (UIImage) -> Void
    @State private var showSourceDialog = false
    @State private var pickerSource: UIImagePickerController.SourceType = .photoLibrary

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "选择图片来源",
                isPresented: $showSourceDialog,
                titleVisibility: .visible
            ) {
                Button("拍照") {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        // 模拟器无相机，降级到相册
                        pickerSource = .photoLibrary
                        isPresented = true
                        return
                    }
                    pickerSource = .camera
                    isPresented = true
                }
                Button("从相册选") {
                    pickerSource = .photoLibrary
                    isPresented = true
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $isPresented) {
                ImagePicker(sourceType: pickerSource) { image in
                    onPicked(image)
                }
            }
            .onChange(of: isPresented) { newValue in
                // 父视图把 isPresented 置 true 时，先弹选择 dialog
                if newValue {
                    showSourceDialog = true
                }
            }
    }
}

/// UIImagePickerController 的 SwiftUI 桥（iOS 13+ 稳）
struct ImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onPicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (UIImage) -> Void
        init(onPicked: @escaping (UIImage) -> Void) { self.onPicked = onPicked }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onPicked(image)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            // dismiss 由 sheet 自动处理，这里只关回调
        }
    }
}