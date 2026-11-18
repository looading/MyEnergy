import Foundation
import MyEnergyCore

/// 临时报告不会自动改变，因此在展示时再次判断样本是否仍在有效时间内。
enum HealthReferencePresentation {
    static func recoveryStatus(_ recovery: RecoverySummary, now: Date = Date()) -> RecoveryStatus {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              let value = recovery.latestMS, value.isFinite, value > 0,
              let sampledAt = recovery.sampledAt, sampledAt.timeIntervalSinceReferenceDate.isFinite,
              sampledAt <= now else { return .unavailable }
        if now.timeIntervalSince(sampledAt) > 24 * 60 * 60 { return .stale }
        // 过期只是时间状态；时钟调整后仍依据原报告的个人历史判断，不伪造对照。
        if recovery.status == .stale {
            return recovery.historyDays >= 7 && recovery.baselineMS.map({ $0.isFinite && $0 > 0 }) == true
                ? .ready : .insufficientHistory
        }
        return recovery.status
    }

    static func recoveryText(_ recovery: RecoverySummary, now: Date = Date()) -> String {
        switch recoveryStatus(recovery, now: now) {
        case .unavailable: "暂无可显示的 HRV 数据。可能尚无样本，或当前没有可读取的项目。"
        case .insufficientHistory: "正在积累个人历史，已有 \(recovery.historyDays) 个有效日。"
        case .stale: "最近样本已超过 24 小时，请留意采样时间。"
        case .ready: "已有足够历史，可查看与个人基线的对照。"
        }
    }
}
