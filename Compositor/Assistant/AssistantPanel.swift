import SwiftUI

/// View › Show Assistant: a chat beside the Layers panel. Requests in plain language are carried out with the app's
/// own edits, each shown on the canvas as it happens and undone with ⌘Z like any other.
struct AssistantPanel: View {
    @Bindable var assistant: AssistantSession
    var width: CGFloat = 300
    static let widths: ClosedRange<Double> = 260...480
    @Environment(\.openSettings) private var openSettings
    @FocusState private var inputFocused: Bool
    private var keys = AssistantKeyState.shared

    init(assistant: AssistantSession, width: CGFloat = 300) {
        self.assistant = assistant
        self.width = width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if assistant.session.document == nil {
                AssistantUnavailableView("No document", systemImage: "bubble.left.and.text.bubble.right") {
                    Text("Create a canvas or open a file, then ask the assistant to change it.")
                }
            } else if !keys.hasKey {
                AssistantUnavailableView("Add an OpenRouter API key", systemImage: "key") {
                    Text("The assistant sends your requests to a model through OpenRouter.")
                    // VERIFY(macOS): openSettings opens the Settings scene from this Window-based app.
                    Button("Open Settings…") { openSettings() }.controlSize(.regular).padding(.top, 4)
                }
            } else {
                messageList
            }
            Divider()
            composer
        }
        .frame(width: width)
        .onAppear { keys.refresh() }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("Assistant").font(.system(size: 12, weight: .semibold))
            Spacer()
            Button { assistant.clear() } label: {
                Image(systemName: "trash").foregroundStyle(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Clear the conversation").accessibilityLabel("Clear the conversation")
            .disabled(assistant.isRunning || assistant.entries.isEmpty)
        }
        .frame(height: 30)
        .padding(.leading, 18).padding(.trailing, 10).padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if assistant.entries.isEmpty {
                        Text("Try “Resize to 1920 wide, then export as PNG”, or select some lines of a page and say “make these pink”.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(assistant.entries) { entry in
                        AssistantEntryRow(entry: entry).id(entry.id)
                    }
                    if assistant.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Working…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .onChange(of: assistant.entries.count) { _, _ in
                guard let last = assistant.entries.last?.id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if assistant.draft.isEmpty {
                    Text(assistant.session.document == nil ? "No document open" : "Ask for a change…")
                        .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $assistant.draft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($inputFocused)
                    // VERIFY(macOS): Return reaches this handler before the text view inserts a newline, and Shift-Return
                    // (ignored here) still types one.
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        if assistant.canSend { assistant.send() }
                        return .handled
                    }
                    .padding(.vertical, 4)
            }
            .frame(height: 72)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.1)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(inputFocused ? Color.accentColor.opacity(0.7) : Color(white: 0.28)))
            HStack {
                Text("Return sends · ⇧Return new line").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if assistant.isRunning {
                    Button("Stop") { assistant.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop the request (⌘.)")
                } else {
                    Button("Send") { assistant.send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!assistant.canSend || !keys.hasKey)
                }
            }
        }
        .padding(12)
        .disabled(assistant.session.document == nil)
    }
}

private struct AssistantEntryRow: View {
    let entry: AssistantEntry

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 28)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.28)))
            }
        case .assistant:
            Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .tool, .toolFailure:
            Label {
                Text(entry.text).textSelection(.enabled)
            } icon: {
                Image(systemName: entry.role == .tool ? "checkmark.circle" : "exclamationmark.triangle")
            }
            .font(.caption)
            .foregroundStyle(entry.role == .tool ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        case .error:
            Label { Text(entry.text).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.circle") }
                .font(.callout).foregroundStyle(.orange)
        }
    }
}

/// The panel's empty states, as the Layers panel draws its own.
private struct AssistantUnavailableView<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 25, weight: .light))
            Text(title).font(.callout.weight(.medium))
            content()
                .font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary).padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Settings › Assistant: the OpenRouter key (kept in the keychain) and the model.
struct AssistantSettingsView: View {
    @AppStorage(AssistantSession.modelKey) private var model = OpenRouterClient.defaultModel
    @State private var key = ""
    @State private var message: String?
    private var keys = AssistantKeyState.shared

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $key, prompt: Text(keys.hasKey ? "Saved in the keychain" : "sk-or-…"))
                HStack {
                    Button("Save Key") { save(key) }.disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove Key") { save("") }.disabled(!keys.hasKey)
                    Spacer()
                    Link("Get a key", destination: URL(string: "https://openrouter.ai/keys")!)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("OpenRouter")
            }
            Section {
                TextField("Model", text: $model, prompt: Text(OpenRouterClient.defaultModel))
                Text("An OpenRouter model id that supports tool calls. The assistant never sends the image itself: only the "
                     + "text it recognizes on this Mac and the document’s size, layers and selection.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Model")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { keys.refresh() }
    }

    private func save(_ value: String) {
        do {
            try AssistantKeychain.save(value)
            key = ""
            message = value.isEmpty ? "Key removed." : "Key saved in the keychain."
        } catch {
            message = error.localizedDescription
        }
        keys.refresh()
    }
}
