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
    // 内部独立状态：来源对话框 vs 真正的 UIImagePicker 界面必须分开驱动，
    // 否则两者会同时抢同一个 sheet 槽位导致对话框闪退、再点无反应（2026-10-14 修）。
    @State private var showImagePicker = false
    @State private var pickerSource: UIImagePickerController.SourceType = .photoLibrary

    func body(content: Content) -> some View {
        content
            // 外部 binding 只负责"来源选择对话框"
            .confirmationDialog(
                "选择图片来源",
                isPresented: $isPresented,
                titleVisibility: .visible
            ) {
                Button("拍照") {
                    // 关掉对话框、再开 picker，做一次干净的 handoff，避免同事务双弹
                    isPresented = false
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                        // 无相机（如模拟器）→ 降级到相册
                        pickerSource = .photoLibrary
                        showImagePicker = true
                        return
                    }
                    pickerSource = .camera
                    showImagePicker = true
                }
                Button("从相册选") {
                    isPresented = false
                    pickerSource = .photoLibrary
                    showImagePicker = true
                }
                Button("取消", role: .cancel) {
                    isPresented = false
                }
            }
            // picker 界面用内部 state 单独驱动
            .sheet(isPresented: $showImagePicker, onDismiss: { showImagePicker = false }) {
                ImagePicker(sourceType: pickerSource) { image in
                    showImagePicker = false
                    // 延一帧：等 picker sheet 先 dismiss，再触发父视图的结果 sheet，
                    // 否则"正在 dismiss 又 present"会被 iOS 吞掉
                    DispatchQueue.main.async {
                        onPicked(image)
                    }
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