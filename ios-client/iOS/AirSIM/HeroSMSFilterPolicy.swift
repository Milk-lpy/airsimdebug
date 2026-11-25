import Foundation

enum HeroSMSDisposition: Equatable {
    case inbox, manual, suspicious, promotion, androidBlocked

    var label: String {
        switch self {
        case .inbox: return "收件箱"
        case .manual: return "自定义规则"
        case .androidBlocked: return "安卓已拦截"
        case .suspicious: return "疑似诈骗"
        case .promotion: return "营销推广"
        }
    }
}

struct HeroSMSFilterRule: Codable, Identifiable, Equatable {
    enum Target: String, Codable, CaseIterable {
        case sender, content
    }
    var id: UUID = UUID()
    var target: Target
    var keyword: String
}

struct HeroSMSFilterPreferences {
    static let legacyKey = "airsim.hero.sms-filter-rules"
    static let presetsKey = "airsim.hero.sms-presets-enabled-v1"
    static let allowKey = "airsim.hero.sms-allowed-senders-v1"
    var defaults: UserDefaults = .standard

    var presetsEnabled: Bool {
        get { defaults.object(forKey: Self.presetsKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.presetsKey) }
    }
    var allowedSenders: [String] { defaults.stringArray(forKey: Self.allowKey) ?? [] }
    func allow(sender: String) {
        let value = HeroSMSFilterPolicy.normalizeSender(sender)
        guard !value.isEmpty, !allowedSenders.contains(value), allowedSenders.count < 250 else { return }
        defaults.set(allowedSenders + [value], forKey: Self.allowKey)
    }
    func removeAllowed(sender: String) {
        defaults.set(allowedSenders.filter { $0 != sender }, forKey: Self.allowKey)
    }
    private var legacyObject: Any? { defaults.object(forKey: Self.legacyKey) }
    var legacyRules: [HeroSMSFilterRule]? {
        guard let object = legacyObject else { return [] }
        if let raw = object as? String, raw.isEmpty { return [] }
        guard let data = (object as? Data) ?? (object as? String).map({ Data($0.utf8) }),
              data.count <= 512 * 1024 else { return nil }
        return try? JSONDecoder().decode([HeroSMSFilterRule].self, from: data)
    }
    @discardableResult
    func replaceLegacyRules(_ rules: [HeroSMSFilterRule]) -> Bool {
        guard legacyRules != nil, let encoded = try? JSONEncoder().encode(rules),
              encoded.count <= 512 * 1024 else { return false }
        if legacyObject is Data { defaults.set(encoded, forKey: Self.legacyKey) }
        else { defaults.set(String(decoding: encoded, as: UTF8.self), forKey: Self.legacyKey) }
        return true
    }
}

/// Only user-authored rules and allow-list are sent over the existing authenticated Agent route.
struct AndroidSMSAlertFilter: Encodable, Equatable, Sendable {
    struct Rule: Encodable, Equatable, Sendable {
        let target: String
        let keyword: String
    }
    let allow: [String]
    let rules: [Rule]

    init(_ prefs: HeroSMSFilterPreferences = .init()) {
        let a = prefs.allowedSenders
        let r = prefs.legacyRules ?? []
        // Keep the paired gateway packet below its 32 KiB limit; fail open rather than load a partial rule set.
        if a.count <= 250, r.count <= 250,
           a.allSatisfy({ $0.utf8.count <= 256 }), r.allSatisfy({ $0.keyword.utf8.count <= 256 }),
           (a.reduce(0) { $0 + $1.utf8.count } + r.reduce(0) { $0 + $1.keyword.utf8.count }) <= 4096 {
            allow = a
            rules = r.map { .init(target: $0.target.rawValue, keyword: $0.keyword) }
        } else {
            allow = []
            rules = []
        }
    }
}

// Selected vocabulary adapted from boommanpro/ios-sms-guard (MIT).
// App-local classification only. Presets are deliberately stricter than upstream.
enum HeroSMSFilterPolicy {
    static let source = "https://github.com/boommanpro/ios-sms-guard/blob/main/Shared/PresetRules.swift"
    private static let otpWords = ["验证码", "驗證碼", "动态密码", "動態密碼", "校验码", "verification code", "one-time password", "otp"]
    private static let transactionWords = ["取件码", "取貨碼", "快递已签收", "快递已揽收",
                                           "还款", "信用卡账单", "信用卡帳單", "交易提醒", "余额不足"]
    private static let optOut = ["回t退订", "回td退订", "回复t退订", "回复td退订", "退订回t", "退订回td"]
    private static let marketing = ["优惠", "促销", "折扣", "秒杀", "满减", "领券", "優惠", "折扣券"]
    private static let fraudPatterns = [
        ["恭喜您获得", "点击链接领取"],
        ["安全账户", "转账"], ["安全账户", "汇款"],
        ["兼职日结", "刷单"]
    ]
    private static let otpDigits = try? NSRegularExpression(pattern: #"(?<![0-9])[0-9]{4,8}(?![0-9])"#)
    private static let smsURL = try? NSRegularExpression(pattern: #"https?://[^\s]+"#)

    static func normalized(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func normalizeSender(_ sender: String) -> String {
        let folded = normalized(sender)
        let compact = folded.filter { !" -().".contains($0) }
        guard !compact.isEmpty, compact.allSatisfy({ $0.isASCII && $0.isNumber || $0 == "+" }) else { return folded }
        if compact.hasPrefix("+86"), compact.count == 14 { return String(compact.dropFirst(3)) }
        return compact
    }
    // Never decide from a truncated preview, which can omit an OTP or transaction marker.
    static func shouldPresentNotification(sender: String, text: String, code: String?,
                                          outgoing: Bool, knownContact: Bool, complete: Bool = true,
                                          preferences: HeroSMSFilterPreferences = .init()) -> Bool {
        guard !outgoing else { return false }
        guard complete else { return true }
        return classify(sender: sender, text: text, code: code, outgoing: false,
                        knownContact: knownContact, preferences: preferences) == .inbox
    }

    static func classify(sender: String, text: String, code: String?, outgoing: Bool, knownContact: Bool,
                         preferences: HeroSMSFilterPreferences) -> HeroSMSDisposition {
        classify(sender: sender, text: text, code: code, outgoing: outgoing, knownContact: knownContact,
                 presetsEnabled: preferences.presetsEnabled, allowed: Set(preferences.allowedSenders),
                 rules: preferences.legacyRules ?? [])
    }
    static func classify(sender: String, text: String, code: String?, outgoing: Bool, knownContact: Bool,
                         presetsEnabled: Bool, allowed: Set<String>, rules: [HeroSMSFilterRule]) -> HeroSMSDisposition {
        let from = normalizeSender(sender)
        guard !outgoing, !allowed.contains(from) else { return .inbox }
        let body = normalized(String(text.prefix(8192)))
        let range = NSRange(body.startIndex..., in: body)
        let hasOTP = code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || (otpWords.contains { body.contains($0) }
                && otpDigits?.firstMatch(in: body, range: range) != nil)
        if hasOTP { return .inbox }
        if rules.contains(where: { rule in
            let term = normalized(rule.keyword)
            guard !term.isEmpty else { return false }
            return rule.target == .sender ? from == normalizeSender(term) : body.contains(term)
        }) { return .manual }
        guard presetsEnabled, !knownContact, !transactionWords.contains(where: { body.contains($0) }) else { return .inbox }
        for (i, pair) in fraudPatterns.enumerated() where pair.allSatisfy({ body.contains($0) }) {
            if i != 0 || smsURL?.firstMatch(in: body, range: range) != nil { return .suspicious }
        }
        if optOut.contains(where: { body.contains($0) }) && marketing.contains(where: { body.contains($0) }) {
            return .promotion
        }
        return .inbox
    }
}
