// MARK: - App 跳转探测器（设置 → 诊断 → 探测跳转能力）
//
// 这是排障工具，不是日常功能。存在的理由只有一个：
// 国内中小 App 的私有 scheme 没有公开来源可查，只能靠真机自测 ——
// 详细背景见 Support/SchemeProbe.swift 的文件头注释。
//
// 用法：点「快速探测」→ 看哪一行命中 → 点「复制报告」把结果发回来，
// 命中的那条会被写进 ScanAppRouter 的规则表，之后扫码就能直接唤起它。
import SwiftUI
import UIKit

struct SchemeProbeView: View {
    @Environment(\.dismiss) private var dismiss

    /// 快速探测（canOpenURL，不跳转）
    @State private var quickResults: [SchemeProbeResult] = []
    @State private var quickRan = false

    /// 深度探测（open，会跳转；命中即停）
    @State private var deepResults: [SchemeProbeResult] = []
    @State private var deepHit: SchemeProbeItem?
    @State private var deepRunning = false

    @State private var toast: String?

    private var items: [SchemeProbeItem] { SchemeProbe.zhidaoCandidates }

    /// 最终结论：深度探测命中优先，否则取快速探测的第一个命中项
    private var hit: SchemeProbeItem? {
        deepHit ?? quickResults.first(where: { $0.available })?.item
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    introCard
                    quickCard
                    if quickRan { quickListCard }
                    deepCard
                    if !deepResults.isEmpty { deepListCard }
                    if let hit { conclusionCard(hit) }
                    if quickRan || !deepResults.isEmpty { reportCard }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 48)
            }
            .background(
                LinearGradient(colors: PagePalette.settings,
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
            .navigationTitle("跳转探测器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.bottom, 44)
            }
        }
        .onChange(of: toast) { value in
            guard value != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { toast = nil }
        }
    }

    // MARK: 说明

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这个页面在干什么", systemImage: "questionmark.circle")
                .font(.subheadline.bold())
            Text("知到（智慧树）这类 App 的私有跳转标识（scheme）没有公开来源可查："
                 + "社区清单不收录、官网没配通用链接、应用商店页面也不写。"
                 + "所以只能在你手机上当场问系统：这批候选里哪个真有 App 认领。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("测出来之后把报告发回来，命中那条会被写进扫码规则表。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .glassRowCard()
    }

    // MARK: 快速探测

    private var quickCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("快速探测", systemImage: "bolt.fill")
                .font(.subheadline.bold())
            Text("全部 \(items.count) 个候选一次测完，**不会跳出 App**。"
                 + "用的是系统查询接口，要求候选在 App 配置里预先声明过 —— "
                 + "所以它说「没有」可能是真没装，也可能是没声明，这两种情况它分不出来。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                quickResults = SchemeProbe.quick(items)
                quickRan = true
                let n = quickResults.filter(\.available).count
                toast = n > 0 ? "命中 \(n) 个" : "全部未命中，试深度探测"
            } label: {
                Text("开始快速探测")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .glassRowCard()
    }

    private var quickListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(quickResults) { r in
                HStack(spacing: 10) {
                    Image(systemName: r.available ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundColor(r.available ? .green : .secondary)
                        .font(.footnote)
                    Text("\(r.item.scheme)://")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(r.available ? .primary : .secondary)
                    Spacer(minLength: 8)
                    Text(r.item.origin)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 1)
            }
        }
        .glassRowCard()
    }

    // MARK: 深度探测

    private var deepCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("深度探测（兜底）", systemImage: "arrow.up.forward.app")
                .font(.subheadline.bold())
            Text("不受「预先声明」限制，任何候选都能试，不存在数量上限。"
                 + "代价是**每命中一个，对方 App 会真的被打开** —— 所以你可能会被弹到知到（或者别的 App）里。"
                 + "命中第一个就停，不会连着甩你很多次。")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("只在上面全部未命中时才需要这步。")
                .font(.caption2)
                .foregroundColor(.secondary)
            Button {
                guard !deepRunning else { return }
                deepRunning = true
                deepResults = []
                deepHit = nil
                SchemeProbe.deep(items) { results, found in
                    deepResults = results
                    deepHit = found
                    deepRunning = false
                    if found == nil { toast = "全部无响应" }
                }
            } label: {
                HStack(spacing: 8) {
                    if deepRunning { ProgressView().scaleEffect(0.7) }
                    Text(deepRunning ? "探测中…" : "开始深度探测")
                        .font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(deepRunning)
        }
        .glassRowCard()
    }

    private var deepListCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(deepResults) { r in
                HStack(spacing: 10) {
                    Image(systemName: r.available ? "checkmark.seal.fill" : "minus.circle")
                        .foregroundColor(r.available ? .orange : .secondary)
                        .font(.footnote)
                    Text("\(r.item.scheme)://")
                        .font(.system(size: 12, design: .monospaced))
                    Spacer(minLength: 8)
                    Text(r.available ? "被接走" : "无响应")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 1)
            }
        }
        .glassRowCard()
    }

    // MARK: 结论

    private func conclusionCard(_ item: SchemeProbeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("测到了", systemImage: "checkmark.seal.fill")
                .font(.subheadline.bold())
                .foregroundColor(.green)
            Text("\(item.scheme)://")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
            Text("命名习惯：\(item.origin)")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                UIPasteboard.general.string = "\(item.scheme)://"
                toast = "已复制"
            } label: {
                Text("复制这个 scheme")
                    .font(.caption.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .glassRowCard()
    }

    // MARK: 报告

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("把报告发回来", systemImage: "doc.on.doc")
                .font(.subheadline.bold())
            Text("本机没有 Xcode、看不到日志，这段文本就是最直接的排障信息。")
                .font(.caption)
                .foregroundColor(.secondary)
            Button {
                let text = SchemeProbe.report(quick: quickResults,
                                              deep: deepResults,
                                              hit: hit)
                UIPasteboard.general.string = text
                toast = "报告已复制"
            } label: {
                Text("复制报告")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .glassRowCard()
    }
}
