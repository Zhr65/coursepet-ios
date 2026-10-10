// MARK: - 短信监听 · 路径 B（正规兜底：快捷指令「收到信息」自动化 → App Intent）
// iOS 不给第三方 App 读短信的公开权限，但快捷指令的自动化自带「收到信息」触发器——
// 它能拿到发件人和全文，再通过 App Intent 把内容转交给我们，等价于一条"系统代跑"的通道。
// 这条路径在 App 被杀时也能跑（系统后台拉起进程执行 perform），与路径 A（私有 API）
// 互为兜底；同一条短信双路都送到时，由 SMSEventRouter 的 60 秒去重挡掉重复。
// 配置步骤见设置 → 短信助手 里的引导（一次配好永久有效）。
import AppIntents

struct ReceiveSMSIntent: AppIntent {
    static let title: LocalizedStringResource = "处理短信"
    static let description = IntentDescription(
        "把收到的短信交给宠物管家：快递自动记取件码、验证码自动复制、银行扣款弹提醒、学校通知记进记忆")

    // Shortcuts 自动化里把「发件人」「信息内容」变量绑到这两个参数；
    // default 空串保证没绑变量时手动跑也不报错
    @Parameter(title: "发件人", default: "")
    var sender: String

    @Parameter(title: "内容", default: "")
    var content: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 后台拉起执行：handle 全程主线程、无 UI 依赖，本地通知照常弹
        SMSSyncManager.lastReceivedAt = Date()
        let summary = SMSEventRouter.handle(sender: sender, text: content)
        // IntentDialog 只支持插值初始化，不能传入拼接后的 String 变量（同 PetIntents 约定）
        return .result(dialog: IntentDialog("\(summary)"))
    }
}
