import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var viewModel = SearchAgentViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: viewModel.messages) { _, newValue in
                    guard let lastID = newValue.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }

            Divider()
            inputBar
        }
    }

    private var header: some View {
        HStack {
            Label("AI Search Agent", systemImage: "magnifyingglass.circle.fill")
                .font(.headline)
            Spacer()
            if viewModel.isBusy {
                Text("생성 중")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("질문을 입력하세요", text: $viewModel.inputText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(viewModel.isInputLocked)
                .onSubmit {
                    viewModel.send()
                }

            if viewModel.showStopButton {
                Button {
                    viewModel.stopGeneration()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    ContentView()
}

struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom) {
            if message.role == .assistant {
                bubbleContent
                Spacer(minLength: 36)
            } else {
                Spacer(minLength: 36)
                bubbleContent
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(message.role == .assistant ? Color(uiColor: .secondarySystemFill) : Color.accentColor)

            Group {
                if message.isLoading {
                    LoadingDotsView()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    AnimatedAssistantText(
                        text: message.text,
                        showCursor: message.isAnimating
                    )
                    .font(.body)
                    .foregroundStyle(message.role == .assistant ? Color.primary : Color.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 320, alignment: message.role == .assistant ? .leading : .trailing)
    }
}

struct LoadingDotsView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { timeline in
            let frame = Int(timeline.date.timeIntervalSinceReferenceDate * 5) % 3

            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(.secondary)
                            .frame(width: 8, height: 8)
                            .scaleEffect(frame == index ? 1.22 : 0.82)
                            .opacity(frame == index ? 1 : 0.3)
                    }
                }
                Text("답변 생성 중")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AnimatedAssistantText: View {
    let text: String
    let showCursor: Bool

    var body: some View {
        if showCursor {
            TimelineView(.animation(minimumInterval: 0.45)) { timeline in
                let cursorVisible = Int(timeline.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2)
                Text(text + (cursorVisible ? "▍" : " "))
            }
        } else {
            Text(text)
        }
    }
}

@MainActor
final class SearchAgentViewModel: ObservableObject {
    @Published var inputText = ""
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var phase: AgentPhase = .idle

    private let api: SearchAgentAPI
    private var runningTask: Task<Void, Never>?

    init(api: SearchAgentAPI = SearchAgentAPI()) {
        self.api = api
    }

    var isBusy: Bool {
        phase == .loading || phase == .animating
    }

    var isInputLocked: Bool {
        phase == .loading
    }

    var showStopButton: Bool {
        isBusy
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    func send() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return }

        inputText = ""
        messages.append(ChatMessage(role: .user, text: question))

        let assistantID = UUID()
        messages.append(
            ChatMessage(
                id: assistantID,
                role: .assistant,
                text: "",
                isLoading: true,
                isAnimating: false
            )
        )

        phase = .loading
        runningTask?.cancel()

        runningTask = Task { [weak self] in
            guard let self else { return }

            do {
                let answer = try await api.ask(question: question)
                try Task.checkCancellation()
                try await animateAssistantAnswer(answer, messageID: assistantID)

                if !Task.isCancelled {
                    phase = .idle
                }
            } catch is CancellationError {
                applyStopStateIfNeeded(for: assistantID)
            } catch {
                markFailure(error, messageID: assistantID)
            }

            runningTask = nil
        }
    }

    func stopGeneration() {
        runningTask?.cancel()
        runningTask = nil
        applyStopStateToLatestAssistantMessage()
        phase = .idle
    }

    private func animateAssistantAnswer(_ answer: String, messageID: UUID) async throws {
        updateMessage(id: messageID) { message in
            message.isLoading = false
            message.isAnimating = true
            message.text = ""
        }
        phase = .animating

        var rendered = ""
        for character in answer {
            try Task.checkCancellation()

            rendered.append(character)
            updateMessage(id: messageID) { message in
                message.text = rendered
            }

            let delay = delayForTyping(character)
            try await Task.sleep(nanoseconds: delay)
        }

        updateMessage(id: messageID) { message in
            message.isAnimating = false
        }
    }

    private func delayForTyping(_ character: Character) -> UInt64 {
        switch character {
        case " ":
            return 14_000_000
        case "\n":
            return 75_000_000
        case ".", "!", "?":
            return 200_000_000
        case ",", ";", ":":
            return 130_000_000
        default:
            return 18_000_000 + UInt64.random(in: 0...12_000_000)
        }
    }

    private func applyStopStateIfNeeded(for messageID: UUID) {
        updateMessage(id: messageID) { message in
            message.isLoading = false
            message.isAnimating = false
            if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message.text = "생성을 중지했습니다."
            }
        }
        phase = .idle
    }

    private func applyStopStateToLatestAssistantMessage() {
        guard let index = messages.lastIndex(where: { $0.role == .assistant && ($0.isLoading || $0.isAnimating) }) else {
            return
        }

        messages[index].isLoading = false
        messages[index].isAnimating = false
        if messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages[index].text = "생성을 중지했습니다."
        }
    }

    private func markFailure(_ error: Error, messageID: UUID) {
        updateMessage(id: messageID) { message in
            message.isLoading = false
            message.isAnimating = false
            message.text = "오류가 발생했습니다: \(error.localizedDescription)"
        }
        phase = .idle
    }

    private func updateMessage(id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[index])
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var isLoading: Bool = false
    var isAnimating: Bool = false

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isLoading: Bool = false,
        isAnimating: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isLoading = isLoading
        self.isAnimating = isAnimating
    }
}

enum AgentPhase {
    case idle
    case loading
    case animating
}

struct SearchAgentAPI {
    // 실제 API를 연결할 때 URL을 넣으세요.
    var endpoint: URL? = nil

    func ask(question: String) async throws -> String {
        guard let endpoint else {
            try await Task.sleep(nanoseconds: 1_600_000_000)
            return """
            "\(question)"에 대한 검색 결과를 정리했습니다.

            1) 핵심 개념 요약
            2) 실무에서 바로 쓸 수 있는 체크리스트
            3) 다음 단계 액션 아이템

            원하시면 방금 결과를 더 짧은 버전으로 다시 작성해드릴게요.
            """
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(AskRequest(question: question))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw APIClientError.invalidStatusCode
        }

        let decoded = try JSONDecoder().decode(AskResponse.self, from: data)
        return decoded.answer
    }
}

private struct AskRequest: Encodable {
    let question: String
}

private struct AskResponse: Decodable {
    let answer: String
}

private enum APIClientError: LocalizedError {
    case invalidStatusCode

    var errorDescription: String? {
        switch self {
        case .invalidStatusCode:
            return "서버 응답 상태 코드가 올바르지 않습니다."
        }
    }
}
