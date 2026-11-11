import Foundation

public enum WristReplyPolicy {
    public static let headphonesKey = "wristReply.autoHeadphones"
    public static let speakerKey = "wristReply.autoSpeaker"
    public static let conciseKey = "wristReply.concise"
    public static func shouldPlay(headphones: Bool, autoHeadphones: Bool, autoSpeaker: Bool, recording: Bool, active: Bool) -> Bool {
        guard active, !recording else { return false }
        return headphones ? autoHeadphones : autoSpeaker
    }
    public static func preview(_ text: String, limit: Int = 140) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(1, limit))) + "…"
    }
    public static let promptInstruction = "请按手表阅读场景回答：先一句结论，最多三个简短要点，总体尽量不超过120个汉字。若关键条件不能省略，请保留；不要为了简短虚构结论。"
}
