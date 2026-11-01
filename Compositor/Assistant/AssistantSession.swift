import Foundation
import Observation

/// One row of the assistant's chat.
struct AssistantEntry: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, tool, toolFailure, error }
    let id = UUID()
    let role: Role
    let text: String
}

/// One project window's assistant: the chat, and the loop that sends it to the model and carries out the tools it
/// calls. Nothing here is saved with the project.
@MainActor @Observable
final class AssistantSession {
    static let modelKey = "assistant.model"
    /// Model calls one request may make before it's stopped, tool calls included.
    static let stepLimit = 25

    static let systemPrompt = """
    You are an assistant inside Compositor, a macOS image editor. You change the open document by calling tools; every \
    change shows on the canvas as it happens and can be undone with ⌘Z.
    Coordinates are document pixels with a top-left origin. Call get_document_info first when you need to know about \
    the document. "1920p", or "1920" without a side, means the long edge.
    To highlight text in a document (a scan, screenshot or photo of a page), call recognize_text, pick the lines that \
    match, then call highlight_lines with their ids; use one call per color. When the user says "these", "here" or \
    "the selected lines", call recognize_text with within_selection: true.
    You can't see the image: only the recognized text and the document's details. If a tool returns an error, fix the \
    arguments and try again, or tell the user what's in the way.
    Ask the user only when a request is truly ambiguous. When finished, say briefly what you did.
    """

    private(set) var entries: [AssistantEntry] = []
    var draft = ""
    private(set) var isRunning = false
    @ObservationIgnored private var messages: [ChatMessage] = [.system(AssistantSession.systemPrompt)]
    @ObservationIgnored private var task: Task<Void, Never>?
    let tools: AssistantToolRunner
    @ObservationIgnored var client = OpenRouterClient()
    let session: EditorSession

    init(session: EditorSession, controller: ProjectController) {
        self.session = session
        tools = AssistantToolRunner(session: session, controller: controller)
    }

    /// The model in Settings, or DeepSeek's chat model.
    var model: String {
        let stored = UserDefaults.standard.string(forKey: Self.modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? OpenRouterClient.defaultModel : stored
    }

    var canSend: Bool {
        !isRunning && session.document != nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        guard let key = AssistantKeychain.read() else {
            AssistantKeyState.shared.refresh()
            entries.append(AssistantEntry(role: .error, text: OpenRouterError.missingKey.localizedDescription))
            return
        }
        draft = ""
        entries.append(AssistantEntry(role: .user, text: text))
        // The note goes to the model only, so "these lines" needs no extra round trip to find the selection.
        messages.append(.user(contextNote() + "\n\n" + text))
        isRunning = true
        task = Task { [weak self] in
            await self?.run(apiKey: key)
        }
    }

    /// Cancels the request in flight and any tool calls still to come.
    func stop() {
        task?.cancel()
    }

    /// Starts the conversation over. Not while a request runs: Stop first, so its last rows don't land in the new chat.
    func clear() {
        guard !isRunning else { return }
        entries = []
        messages = [.system(Self.systemPrompt)]
        tools.forgetRecognizedText()
    }

    /// A line about the document sent ahead of each request.
    func contextNote() -> String {
        guard let document = session.document else { return "[Context: no document is open.]" }
        let resolution = document.resolution.formatted(.number.precision(.fractionLength(0...1)))
        let layers = document.layers.count == 1 ? "1 layer" : "\(document.layers.count) layers"
        let selection: String
        switch AssistantToolRunner.selectionBounds(session.selection) {
        case .object(let box) where box["empty"] == nil:
            func value(_ key: String) -> String {
                if case .number(let number)? = box[key] { return String(Int(number)) }
                return "?"
            }
            selection = "selection at x \(value("x")), y \(value("y")), \(value("width")) × \(value("height")) px"
        case .object: selection = "an empty selection"
        default: selection = "no selection"
        }
        return "[Context: canvas \(document.width) × \(document.height) px at \(resolution) ppi, \(layers), \(selection).]"
    }

    private func run(apiKey: String) async {
        defer {
            isRunning = false
            task = nil
        }
        do {
            for _ in 0..<Self.stepLimit {
                try Task.checkCancellation()
                let request = ChatRequest(model: model, messages: messages, tools: AssistantTool.definitions)
                let reply = try await client.complete(request, apiKey: apiKey)
                try Task.checkCancellation()
                var answer = reply
                answer.role = "assistant"
                messages.append(answer)
                if let text = reply.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    entries.append(AssistantEntry(role: .assistant, text: text))
                }
                guard let calls = reply.toolCalls, !calls.isEmpty else { return }
                for call in calls {
                    // A stop between calls leaves the rest answered as cancelled, below.
                    try Task.checkCancellation()
                    let outcome = await tools.run(call)
                    messages.append(.tool(call.id, content: outcome.content))
                    entries.append(AssistantEntry(role: outcome.failed ? .toolFailure : .tool, text: outcome.summary))
                }
            }
            entries.append(AssistantEntry(role: .error, text: "Stopped after \(Self.stepLimit) steps. Ask again to carry on."))
        } catch {
            answerUnansweredCalls()
            if Self.isCancellation(error) {
                entries.append(AssistantEntry(role: .error, text: "Stopped."))
            } else {
                entries.append(AssistantEntry(role: .error, text: error.localizedDescription))
            }
        }
    }

    /// The API rejects a conversation where a tool call has no result, so calls a stop or error cut off get one.
    private func answerUnansweredCalls() {
        guard let index = messages.lastIndex(where: { $0.role == "assistant" }), let calls = messages[index].toolCalls else { return }
        let answered = Set(messages[(index + 1)...].compactMap(\.toolCallID))
        for call in calls where !answered.contains(call.id) {
            messages.append(.tool(call.id, content: JSONValue.object(["error": .string("Cancelled by the user.")]).encodedString))
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
