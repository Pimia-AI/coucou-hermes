import Foundation
import Security

// MARK: - Keychain helpers

enum Keychain {
    static let service = "fr.louisraille.NotchBuddy"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete existing item first (update pattern)
        let lookup: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(lookup as CFDictionary)
        // Add with strictest access control:
        // WhenUnlockedThisDeviceOnly = accessible only while Mac is unlocked,
        // never synced to iCloud, never migrated to another device.
        let item: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Keychain cache (reads each key ONCE at launch; all subsequent access via dict)

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let allKeys = [
        "anthropic-api-key",
        "hermes-api-key",
        "resend-api-key", "resend-from",
        "n8n-url", "n8n-api-key",
        "vercel-token",
        "github-token",
        "stripe-api-key",
        "calcom-api-key",
        "notion-api-key",
    ]

    /// Keys already looked up, so a missing one is not re-queried on every read.
    private var probed: Set<String> = []

    private init() {
        // Deliberately empty. Reading the Keychain here hung the whole launch:
        // SettingsView's @State initialisers call into this singleton, and SwiftUI
        // evaluates them while building the Settings scene — before
        // applicationDidFinishLaunching. An item whose ACL does not match the
        // running binary makes SecItemCopyMatching put up an authorization dialog,
        // and for an LSUIElement agent that dialog never reaches the user. The app
        // stayed alive with no menu bar item, no island and no hook socket, with
        // nothing logged anywhere to say why.
        //
        // Ad-hoc signed builds hit this constantly: the ACL is bound to the code
        // identity, so every local rebuild is a different app to macOS.
        //
        // Reads are lazy instead. The first one happens when something actually
        // needs a secret — sending a chat, opening Settings — by which point the
        // app is up and any dialog is attached to something the user just did.
    }

    /// Thread-safe read. Loads from the Keychain on first use, then caches.
    func get(_ key: String) -> String? {
        lock.withLock {
            if let cached = cache[key] { return cached }
            if probed.contains(key) { return nil }
            probed.insert(key)
            let value = Keychain.load(key: key)
            if let value { cache[key] = value }
            return value
        }
    }

    /// Updates cache + persists to Keychain.
    func set(_ key: String, value: String) {
        lock.withLock { cache[key] = value }
        Keychain.save(key: key, value: value)
    }

    /// Removes from cache + Keychain only if the key was previously set.
    func remove(_ key: String) {
        let had = lock.withLock { () -> Bool in
            let exists = cache[key] != nil
            cache[key] = nil
            return exists
        }
        if had { Keychain.delete(key: key) }
    }
}

// MARK: - Hermes agent service
//
// Talks to the local Hermes gateway (gateway/platforms/api_server.py), NOT to
// api.anthropic.com. The endpoint is OpenAI-compatible but it is not a model
// proxy: each request drives a real Hermes agent turn, with its toolsets,
// skills and subagents. Subagents it spawns surface as pills here via the
// shell-hook bridge in ~/.hermes/coucou-bridge.
//
// The key is a full-access credential: that endpoint dispatches terminal-capable
// work, which is why Hermes refuses to start without a strong one and binds
// 127.0.0.1 only. It lives in the Keychain like every other secret.

@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let endpoint = URL(string: "http://127.0.0.1:8642/v1/chat/completions")!
    private let model = "hermes-agent"
    /// An agent turn may run tools, search and spawn subagents; the old 45 s
    /// Anthropic timeout would cut off most real work.
    private let requestTimeout: TimeInterval = 300

    var apiKey: String? { KeychainStore.shared.get("hermes-api-key") }

    // Multi-turn conversation (OpenAI shape: content is a plain string)
    private var conversationMessages: [[String: Any]] = []

    func clearConversation() {
        conversationMessages = []
    }

    private let systemPrompt = """
    You are Mochi, a personal AI assistant embedded in the notch of this Mac. \
    Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
    No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.
    """

    // MARK: - Chat (multi-turn)

    func chat(query: String, context: PromptContext?, state: AppState) async {
        guard let key = apiKey, !key.isEmpty else {
            await showError("Hermes key missing. Open settings.", state: state)
            return
        }

        var parts: [String] = []
        // Context on the first message only.
        if conversationMessages.isEmpty, let context = context {
            parts.append(describe(context))
        }
        parts.append(query)

        conversationMessages.append(["role": "user", "content": parts.joined(separator: "\n\n")])

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": systemPrompt]] + conversationMessages,
            "stream": false,
        ]

        do {
            // Append an empty assistant message and grow it as deltas arrive.
            state.chatHistory.append(ChatMessage(role: .assistant, content: ""))
            let index = state.chatHistory.count - 1
            state.stateOverride = nil
            state.view = .prompt

            let reply = try await streamCompletion(body: body, key: key) { chunk in
                guard index < state.chatHistory.count else { return }
                state.chatHistory[index].content += chunk
            }

            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                state.chatHistory.remove(at: index)
                await showError("No reply from Hermes.", state: state)
                conversationMessages.removeLast()
                return
            }
            state.chatHistory[index].content = clean
            conversationMessages.append(["role": "assistant", "content": clean])
            VoiceEngine.shared.speak(clean)
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            if let last = state.chatHistory.last, last.role == .assistant, last.content.isEmpty {
                state.chatHistory.removeLast()
            }
            conversationMessages.removeLast()
            await showError(friendlyError(error), state: state)
        }
    }

    // MARK: - Structured search

    func search(query: String, context: PromptContext?, state: AppState) async {
        guard let key = apiKey, !key.isEmpty else {
            await showError("Hermes key missing. Open settings to configure it.", state: state)
            return
        }

        let userText = context.map { "\(describe($0))\n\nRequest: \(query)" } ?? query

        let system = """
        You are an assistant built into the notch of a Mac. Reply in English, short and precise.
        Reply ONLY with valid JSON in this exact format:
        {"title":"...","items":[{"label":"...","detail":"...","url":"..."}],"note":"..."}
        Maximum 3 items. "url" is optional. "note" is optional.
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userText],
            ],
            "stream": false,
        ]

        do {
            // Streamed too: a structured search can trip the approval gate just
            // as easily, and on the non-streaming path that request has nowhere
            // to go. The text is only used once complete.
            let text = try await streamCompletion(body: body, key: key) { _ in }
            await handleResult(text, state: state)
        } catch {
            await showError(friendlyError(error), state: state)
        }
    }

    // MARK: - Streaming
    //
    // The chat streams for one reason beyond the nicer typing effect: a
    // dangerous-command approval only reaches the caller as an `approval.request`
    // SSE event. With `stream: false` the gateway has no channel to ask on, so
    // the request sits unanswered until it expires — and Hermes' contract is that
    // silence is not consent, so the action is denied. A plugin approval
    // transport does not help: that surface is CLI-only, and the gateway
    // resolves approvals through `_await_gateway_decision` instead.

    private let runsURL = URL(string: "http://127.0.0.1:8642/v1/runs")!

    /// Run one streamed completion. `onContent` receives each text delta.
    /// Returns the full reply once the stream ends.
    private func streamCompletion(body: [String: Any], key: String,
                                  onContent: @escaping (String) -> Void) async throws -> String {
        var streamed = body
        streamed["stream"] = true

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: streamed)
        // No overall timeout: a turn can legitimately sit waiting for the user
        // to answer an approval. The per-read timeout still applies.
        request.timeoutInterval = 3600

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Hermes", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "gateway returned \(status)"])
        }

        var reply = ""
        var eventName = ""
        var data = ""
        var lineCount = 0
        var frameCount = 0
        VoiceEngine.shared.vlog("stream: connected \(http.statusCode)")

        // SSE frames: optional `event:` line, one or more `data:` lines, blank line.
        for try await line in bytes.lines {
            lineCount += 1
            if lineCount <= 3 { VoiceEngine.shared.vlog("stream line \(lineCount): \(line.prefix(60))") }
            if line.isEmpty {
                if !data.isEmpty {
                    frameCount += 1
                    await handleFrame(event: eventName, json: data, key: key,
                                      reply: &reply, onContent: onContent)
                }
                eventName = ""; data = ""
                continue
            }
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        if !data.isEmpty {
            await handleFrame(event: eventName, json: data, key: key,
                              reply: &reply, onContent: onContent)
        }
        VoiceEngine.shared.vlog("stream: \(lineCount) lines, \(frameCount) frames, \(reply.count) chars")
        return reply
    }

    private func handleFrame(event: String, json: String, key: String,
                             reply: inout String, onContent: @escaping (String) -> Void) async {
        if json == "[DONE]" { return }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return }

        if event == "approval.request" {
            await presentApproval(parsed, key: key)
            return
        }
        // Ignore hermes.status / hermes.tool.progress: the pills already show that.
        guard event.isEmpty else { return }

        if let choices = parsed["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let chunk = delta["content"] as? String, !chunk.isEmpty {
            reply += chunk
            onContent(chunk)
        }
    }

    // MARK: - Gateway approvals

    /// Put the request on the island and wait for a button. Hermes holds the run
    /// until the decision is posted, so blocking here is what we want.
    private func presentApproval(_ event: [String: Any], key: String) async {
        let state = AppState.shared
        let runId = event["run_id"] as? String ?? ""
        let requestId = event["request_id"] as? String
        let command = event["command"] as? String ?? event["description"] as? String ?? "command"
        let allowed = Set(event["choices"] as? [String] ?? ["once", "deny"])

        let choice: String = await withCheckedContinuation { continuation in
            var resumed = false
            state.gatewayApprovalHandler = { decision in
                guard !resumed else { return }
                resumed = true
                // Coucou's buttons speak allow/always/deny; Hermes wants
                // once/session/always/deny, and only the ones it offered.
                let mapped: String
                switch decision {
                case "allow":  mapped = "once"
                case "always": mapped = allowed.contains("always") ? "always"
                                      : (allowed.contains("session") ? "session" : "once")
                default:       mapped = "deny"
                }
                continuation.resume(returning: mapped)
            }
            state.pendingApproval = ApprovalInfo(sessionId: runId, tool: "Hermes", command: command)
            state.isPinned = true
            state.stateOverride = .approval
            state.view = .approval
            SoundEngine.shared.play("approval")
        }

        state.gatewayApprovalHandler = nil
        await postApproval(runId: runId, requestId: requestId, choice: choice, key: key)
    }

    private func postApproval(runId: String, requestId: String?, choice: String, key: String) async {
        guard !runId.isEmpty else { return }
        var request = URLRequest(url: runsURL.appendingPathComponent(runId).appendingPathComponent("approval"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var payload: [String: Any] = ["choice": choice]
        if let requestId, !requestId.isEmpty { payload["request_id"] = requestId }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 30
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 { NSLog("Hermes: approval POST returned \(status)") }
        } catch {
            NSLog("Hermes: approval POST failed: \(error.localizedDescription)")
        }
    }

    // MARK: - API call

    private func callAPI(body: [String: Any], key: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = requestTimeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "Hermes", code: status, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    /// OpenAI envelope: choices[0].message.content.
    private func assistantText(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.isEmpty else { return nil }
        return text
    }

    /// The gateway not running is the one failure worth naming precisely —
    /// everything else is already a readable message from the server.
    private func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain,
           ns.code == NSURLErrorCannotConnectToHost || ns.code == NSURLErrorNetworkConnectionLost {
            return "Hermes gateway not reachable. Start it with: hermes gateway run"
        }
        if ns.domain == "Hermes", ns.code == 401 || ns.code == 403 {
            return "Hermes rejected the key. Check API_SERVER_KEY."
        }
        return "Error: \(error.localizedDescription)"
    }

    // MARK: - Context description
    //
    // Files are passed by PATH, not inlined: Hermes runs on this machine and
    // reads them with its own tools, so there is no base64 round trip and no
    // 200 KB ceiling — a whole PDF or repo file just works.

    private func describe(_ context: PromptContext) -> String {
        switch context {
        case .window(let app, let title, let url):
            var text = "Context — App: \(app), Window: \(title)"
            if let url = url { text += ", URL: \(url)" }
            return text
        case .file(let name, let fileURL):
            if let fileURL = fileURL {
                return "Context — the user attached this file, read it yourself: \(fileURL.path)"
            }
            return "Context — file: \(name)"
        }
    }

    // MARK: - Chat result handler

    private func handleChatResult(_ data: Data, state: AppState) async {
        guard let text = assistantText(data) else {
            await showError("Unexpected gateway response.", state: state)
            return
        }

        conversationMessages.append(["role": "assistant", "content": text])
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.chatHistory.append(ChatMessage(role: .assistant, content: reply))
        // No-op unless the user turned voice on; never blocks the reply appearing.
        VoiceEngine.shared.speak(reply)

        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    // MARK: - Structured result handler

    private func handleResult(_ raw: String, state: AppState) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            await showError("No reply from Hermes.", state: state)
            return
        }

        // Strip markdown code fences if present, then extract the JSON object
        let cleanText: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            cleanText = String(text[start...end])
        } else {
            cleanText = text
        }

        if let resultData = cleanText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            let title  = parsed["title"] as? String ?? "Result"
            let note   = parsed["note"] as? String
            var items: [ResultItem] = []
            if let rawItems = parsed["items"] as? [[String: Any]] {
                for item in rawItems.prefix(3) {
                    items.append(ResultItem(
                        label:  item["label"]  as? String ?? "",
                        detail: item["detail"] as? String ?? "",
                        url:    item["url"]    as? String
                    ))
                }
            }
            state.searchResult = SearchResult(title: title, items: items, note: note)
        } else {
            let lines = cleanText.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(3)
            state.searchResult = SearchResult(
                title: "Hermes' response",
                items: lines.map { ResultItem(label: $0, detail: "", url: nil) },
                note: nil
            )
        }

        state.stateOverride = nil
        state.view = .result
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
    }

    private func showError(_ message: String, state: AppState) async {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }
}
