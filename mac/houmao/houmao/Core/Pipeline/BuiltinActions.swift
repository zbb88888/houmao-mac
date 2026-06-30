import Foundation

// MARK: - translate

/// `$translate` — translates the input text between Chinese and other
/// languages, using the pipeline's resolved model.
struct TranslateAction: PipelineAction {
    let name = "translate"

    func run(_ context: PipelineContext) async throws -> PipelineContext {
        guard let model = context.model else {
            throw PipelineError.missingModel(action: name)
        }
        let client = AiTxtClient(
            baseURL: model.provider.apiHost,
            model: model.model,
            apiKey: model.provider.apiKey
        )
        let prompt = """
        Translate the following text. If it is Chinese, translate it into English; \
        otherwise translate it into Chinese. Output only the translated text, with no \
        explanation, labels, or surrounding quotes.

        ---
        \(context.text)
        """
        let result = try await client.ask(question: prompt, attachments: [])
        var output = context
        output.text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return output
    }
}

// MARK: - summarize

/// `$summarize` — produces a concise summary in the input's original language.
struct SummarizeAction: PipelineAction {
    let name = "summarize"

    func run(_ context: PipelineContext) async throws -> PipelineContext {
        guard let model = context.model else {
            throw PipelineError.missingModel(action: name)
        }
        let client = AiTxtClient(
            baseURL: model.provider.apiHost,
            model: model.model,
            apiKey: model.provider.apiKey
        )
        let prompt = """
        Summarize the following text concisely, in its original language. Output only \
        the summary, with no preamble or labels.

        ---
        \(context.text)
        """
        let result = try await client.ask(question: prompt, attachments: [])
        var output = context
        output.text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return output
    }
}

// MARK: - save

/// `$save` — appends the current text to the notes store. The text payload is
/// passed through unchanged so the pipeline can continue.
struct SaveNoteAction: PipelineAction {
    let name = "save"
    let writer: any NoteWriting

    init(writer: any NoteWriting) {
        self.writer = writer
    }

    func run(_ context: PipelineContext) async throws -> PipelineContext {
        let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PipelineError.emptyInput }
        try await writer.append(Note(content: text))
        return context
    }
}
