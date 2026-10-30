import Foundation

public enum Mood: String, CaseIterable {
    case welcome, idle, focus, happy, hot, dizzy, puzzled, sleepy, low, shy, message
    public var asset: String { switch self {
    case .welcome: return "23.14.18"; case .idle: return "23.14.12"
    case .focus: return "23.13.57"; case .happy: return "23.14.05"
    case .hot: return "23.14.42"; case .dizzy: return "23.13.41"
    case .puzzled: return "23.13.49"; case .sleepy: return "23.15.06"
    case .low: return "23.14.54"; case .shy: return "23.13.20"
    case .message: return "23.13.33"
    }}
    public var title: String { switch self {
    case .welcome: return "欢迎回来"; case .idle: return "陪着你"
    case .focus: return "专注中"; case .happy: return "好耶"
    case .hot: return "有点忙"; case .dizzy: return "忙晕了"
    case .puzzled: return "在找什么呀"; case .sleepy: return "困困"
    case .low: return "快没电啦"; case .shy: return "被摸摸了"
    case .message: return "有新动静"
    }}
}
public struct Snapshot {
    public init() {}
    public var cpu = 0.0, battery: Int? = nil, charging = false
    public var apps = 0, windows: Int? = nil, folders: Int? = nil, documents: Int? = nil
    public var front = "桌面", idle = 0.0, awake = 0.0
    public var badges = 0, notification = "", notificationNodes = 0
}
public struct Decision {
    public var mood: Mood
    public var text: String
    public init(mood: Mood, text: String) { self.mood = mood; self.text = text }
}
public func decide(_ s: Snapshot, screenTimeout: Double, greeting: Bool) -> Decision {
    if greeting { return Decision(mood: .welcome, text: "你回来啦！今天也一起加油～") }
    if let b = s.battery, b <= 15 && !s.charging { return Decision(mood: .low, text: "只剩 \(b)% 电啦，给电脑充充电吧。") }
    if s.idle > 60 && screenTimeout > 0 && s.idle >= max(60, screenTimeout - 35) { return Decision(mood: .sleepy, text: "闲置了一会儿，屏幕可能快休息啦…") }
    if s.cpu > 83 { return Decision(mood: .dizzy, text: "CPU \(Int(s.cpu))%，电脑忙晕啦…") }
    if s.cpu > 55 || (s.windows ?? 0) > 24 || s.apps > 22 { return Decision(mood: .hot, text: "\(s.apps) 个软件在运行，慢慢来，我陪你。") }
    if s.awake > 50 * 60 && s.idle < 60 { return Decision(mood: .sleepy, text: "连续用电脑快 \(Int(s.awake / 60)) 分钟啦，伸个懒腰？") }
    if s.idle > 180 { return Decision(mood: .sleepy, text: "我在这里等你… zZ") }
    let n = s.front.lowercased()
    if n.contains("code") || n.contains("xcode") || n.contains("terminal") || n.contains("终端") { return Decision(mood: .focus, text: "在 \(s.front) 写代码呀，我安静陪你。") }
    if n.contains("wps") || n.contains("word") || n.contains("pages") || n.contains("excel") || n.contains("powerpoint") { return Decision(mood: .focus, text: "文档时间！和你一起认真工作。") }
    if n.contains("finder") || n.contains("访达") { return Decision(mood: .puzzled, text: "找文件吗？整理好就不会迷路啦。") }
    if s.charging { return Decision(mood: .happy, text: "正在补充能量！我也精神起来啦。") }
    return Decision(mood: .idle, text: "你用 \(s.front)，我在旁边陪你。")
}

