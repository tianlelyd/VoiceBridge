import Foundation

// MARK: - im.message.receive_v1 事件

struct FeishuEventWrapper: Codable {
    let schema: String?
    let header: FeishuEventHeader?
    let event: FeishuEvent?
}

struct FeishuEventHeader: Codable {
    let eventId: String?
    let eventType: String?
    let createTime: String?
    let token: String?
    let appId: String?
    let tenantKey: String?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case eventType = "event_type"
        case createTime = "create_time"
        case token, appId = "app_id", tenantKey = "tenant_key"
    }
}

struct FeishuEvent: Codable {
    let sender: FeishuSender?
    let message: FeishuMessage?
    let eventKey: String?

    enum CodingKeys: String, CodingKey {
        case sender
        case message
        case eventKey = "event_key"
    }
}

struct FeishuSender: Codable {
    let senderId: FeishuSenderId?
    let senderType: String?

    enum CodingKeys: String, CodingKey {
        case senderId = "sender_id"
        case senderType = "sender_type"
    }
}

struct FeishuSenderId: Codable {
    let unionId: String?
    let userId: String?
    let openId: String?

    enum CodingKeys: String, CodingKey {
        case unionId = "union_id"
        case userId = "user_id"
        case openId = "open_id"
    }
}

struct FeishuMessage: Codable {
    let messageId: String?
    let messageType: String?
    let content: String?
    let chatId: String?
    let chatType: String?
    let createTime: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case messageType = "message_type"
        case content
        case chatId = "chat_id"
        case chatType = "chat_type"
        case createTime = "create_time"
    }

    /// 从 content JSON 字符串中提取纯文本
    var plainText: String? {
        guard messageType == "text", let content else { return nil }
        guard let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = dict["text"] as? String else {
            return nil
        }
        return text
    }
}
