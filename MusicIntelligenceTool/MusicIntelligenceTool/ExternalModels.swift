import Foundation
import Observation
import Security

enum CloudProvider: String, Codable, CaseIterable, Identifiable {
    case openAI, openRouter
    var id: Self { self }
    var title: String { self == .openAI ? "OpenAI API／兼容服务" : "OpenRouter" }
    var baseURL: String { self == .openAI ? "https://api.openai.com/v1" : "https://openrouter.ai/api/v1" }
}

enum CloudAPIStyle: String, Codable, CaseIterable, Identifiable {
    case chat, responses
    var id: Self { self }
    var title: String { self == .chat ? "Chat Completions" : "Responses" }
    var path: String { self == .chat ? "chat/completions" : "responses" }
}

enum CloudOutputMode: String, Codable, CaseIterable, Identifiable {
    case prompt, schema
    var id: Self { self }
    var title: String { self == .schema ? "严格 JSON Schema" : "提示词 JSON（本地校验）" }
}

struct ModelConnection: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name = "新连接"
    var provider = CloudProvider.openAI
    var baseURL = CloudProvider.openAI.baseURL
    var model = ""
    var apiStyle = CloudAPIStyle.chat
    var outputMode = CloudOutputMode.prompt
    var legacyTokenLimit = false
    var maxOutputTokens = 4096
    var maxAudioSeconds = 120.0
    var timeoutSeconds = 120.0
    var upstream = ""
    var allowProviderFallbacks = false
    var declaredAudio: Bool?
    var declaredSchema: Bool?
    var catalogSignature: String?
    var verifiedTextAt: Date?
    var verifiedAudioAt: Date?
    var credentialAccount: String?
    var audioAvailable: Bool { verifiedAudioAt != nil || (catalogSignature == validationSignature && declaredAudio == true) }

    var credentialOrigin: String? {
        guard let url = try? endpoint("models"), let scheme = url.scheme, let host = url.host else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host.lowercased()):\(port)"
    }

    var validationSignature: String {
        SongRecord.digest(Data([provider.rawValue, baseURL, model, apiStyle.rawValue, outputMode.rawValue,
                               upstream, String(allowProviderFallbacks), String(legacyTokenLimit)].joined(separator: "\n").utf8))
    }

    func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else {
            throw CloudError.configuration("请输入 HTTPS API 基础地址；本机服务可使用 HTTP。地址不能包含密钥、查询参数或账号。")
        }
        return url.appendingPathComponent(path)
    }

    func validate() throws {
        _ = try endpoint(apiStyle.path)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !model.contains(where: \.isNewline), (256...32768).contains(maxOutputTokens),
              maxAudioSeconds.isFinite, (1...600).contains(maxAudioSeconds),
              timeoutSeconds.isFinite, (10...600).contains(timeoutSeconds) else {
            throw CloudError.configuration("请填写连接名和模型 ID；输出上限为 256–32768，音频上限为 1–600 秒，超时为 10–600 秒。")
        }
    }
}

protocol CloudCredentialStore {
    func read(_ id: String) throws -> String?
    func write(_ value: String?, for id: String) throws
}

struct KeychainCredentials: CloudCredentialStore {
    private let service = "MusicIntelligenceTool.ExternalModels"

    func read(_ id: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: id,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw CloudError.configuration("无法读取钥匙串中的密钥（\(status)）。")
        }
        return key
    }

    func write(_ value: String?, for id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: id]
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CloudError.configuration("无法删除钥匙串中的密钥（\(status)）。")
            }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudError.configuration("无法保存密钥到钥匙串（\(status)）。") }
    }
}

@MainActor @Observable
final class ExternalModels {
    struct Configuration: Codable {
        var connections: [ModelConnection] = []
        var textConnectionID: String?
        var audioConnectionID: String?

        var suggestedTextConnectionID: String? {
            let preferred = connections.first { $0.id == textConnectionID } ?? connections.first
            guard let preferred, preferred.verifiedTextAt == nil, preferred.verifiedAudioAt != nil else {
                return preferred?.id
            }
            // The first connection can be saved as both defaults. An audio check
            // only validates audio requests, so prefer a verified text connection on the same service.
            return connections.first {
                $0.verifiedTextAt != nil && $0.provider == preferred.provider && $0.baseURL == preferred.baseURL
            }?.id ?? preferred.id
        }
    }
    private(set) var configuration = Configuration()
    private(set) var loadError: String?
    private let file: URL
    private let credentials: CloudCredentialStore

    init(directory: URL, credentials: CloudCredentialStore = KeychainCredentials()) {
        file = directory.appendingPathComponent("connections.json")
        self.credentials = credentials
        if FileManager.default.fileExists(atPath: file.path) {
            do { configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file)) }
            catch { loadError = "外部模型配置无法读取，请修复 \(file.path)。原文件已保留。" }
        }
    }

    func key(for connection: ModelConnection) throws -> String {
        guard let saved = configuration.connections.first(where: { $0.id == connection.id }) else {
            throw CloudError.configuration("请先在外部模型设置中保存此连接的 API Key。")
        }
        guard let origin = connection.credentialOrigin, origin == saved.credentialOrigin else {
            throw CloudError.configuration("API 来源已更换，请为新地址输入新的 API Key。")
        }
        guard let key = try credentials.read(saved.credentialAccount ?? saved.id), !key.isEmpty else {
            throw CloudError.configuration("请先在外部模型设置中保存此连接的 API Key。")
        }
        return key
    }

    func save(_ connection: ModelConnection, newKey: String = "") throws {
        try connection.validate()
        if let loadError { throw CloudError.configuration(loadError) }
        var next = configuration
        var saved = connection
        let index = next.connections.firstIndex { $0.id == connection.id }
        let old = index.map { next.connections[$0] }
        if let old, old.credentialOrigin != saved.credentialOrigin, newKey.isEmpty {
            throw CloudError.configuration("API 来源已更换，请为新地址输入新的 API Key。")
        }
        if let old, old.validationSignature != saved.validationSignature || !newKey.isEmpty {
            saved.verifiedTextAt = nil
            saved.verifiedAudioAt = nil
        }
        if saved.catalogSignature != saved.validationSignature { saved.declaredAudio = nil; saved.declaredSchema = nil }
        let newAccount = newKey.isEmpty ? nil : UUID().uuidString
        saved.credentialAccount = newAccount ?? old?.credentialAccount
        if let index { next.connections[index] = saved }
        else { next.connections.append(saved) }
        if next.textConnectionID == nil { next.textConnectionID = saved.id }
        if next.audioConnectionID == nil { next.audioConnectionID = saved.id }
        // Keep the old credential in place until the new origin and its account
        // are saved together. Legacy connections use their ID as the account.
        if let newAccount {
            try credentials.write(newKey, for: newAccount)
            do { try persist(next) }
            catch {
                try? credentials.write(nil, for: newAccount)
                throw error
            }
            if let old { try credentials.write(nil, for: old.credentialAccount ?? old.id) }
        } else {
            try persist(next)
        }
    }

    func assign(_ id: String?, to task: CloudTaskKind) throws {
        var next = configuration
        if task == .audio { next.audioConnectionID = id } else { next.textConnectionID = id }
        try persist(next)
    }

    func delete(_ id: String) throws {
        guard let connection = configuration.connections.first(where: { $0.id == id }) else { return }
        var next = configuration
        next.connections.removeAll { $0.id == id }
        if next.textConnectionID == id { next.textConnectionID = nil }
        if next.audioConnectionID == id { next.audioConnectionID = nil }
        try credentials.write(nil, for: connection.credentialAccount ?? id)
        try persist(next)
    }

    func recordVerification(_ connection: ModelConnection, task: CloudTaskKind) throws {
        guard let index = configuration.connections.firstIndex(where: { $0.id == connection.id }),
              configuration.connections[index].validationSignature == connection.validationSignature else { return }
        var next = configuration
        if task == .audio { next.connections[index].verifiedAudioAt = Date() }
        else { next.connections[index].verifiedTextAt = Date() }
        try persist(next)
    }

    private func persist(_ next: Configuration) throws {
        if let loadError { throw CloudError.configuration(loadError) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        configuration = next
    }
}
