import Foundation
import CLlama

// Thin, UI-free wrapper around llama.cpp (statically linked, see
// scripts/build_llama.sh). One engine = one loaded model + one context.
// All calls are serialized; generation is synchronous and meant to run on a
// background queue (MeetingSummarizer does that).

public struct LLMOptions: Sendable {
    /// Context window in tokens (prompt + answer).
    public var contextTokens: Int
    /// Offload to the GPU (Metal) when one is available. The Intel slice is
    /// CPU-only regardless.
    public var useGPU: Bool
    public var threads: Int
    /// Prompt tokens per llama_decode call; also the cancellation granularity
    /// while the prompt is being read.
    public var batchTokens: Int

    public init(contextTokens: Int = LLMOptions.recommendedContextTokens, useGPU: Bool = true,
                threads: Int = LLMOptions.recommendedThreads, batchTokens: Int = 512) {
        self.contextTokens = contextTokens
        self.useGPU = useGPU
        self.threads = threads
        self.batchTokens = batchTokens
    }

    /// 16k tokens on 8 GB Macs, 32k with 16 GB or more. The model's attention
    /// cache is small (only 1 layer in 4 keeps a KV cache), so 16k costs
    /// about 0.5 GB on top of the 2.7 GB of weights.
    public static var recommendedContextTokens: Int {
        #if os(iOS)
        // iPhone: the app gets only part of the RAM; long meetings go map-reduce.
        return 8_192
        #else
        return ProcessInfo.processInfo.physicalMemory >= 15 * (1 << 30) ? 32_768 : 16_384
        #endif
    }

    /// Performance cores (Apple silicon) or half the logical CPUs, 1…8.
    public static var recommendedThreads: Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return min(8, max(1, Int(value)))
        }
        return min(8, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
}

public struct SamplingOptions: Sendable {
    /// Low temperature: factual, nearly deterministic. 0 = greedy.
    public var temperature: Float
    public var topK: Int32
    public var topP: Float
    public var minP: Float
    /// Mild repetition penalty against loops in long lists (1 = off).
    public var repeatPenalty: Float
    public var repeatLastN: Int32
    public var seed: UInt32

    public init(temperature: Float = 0.2, topK: Int32 = 40, topP: Float = 0.9, minP: Float = 0.05,
                repeatPenalty: Float = 1.05, repeatLastN: Int32 = 256, seed: UInt32 = 42) {
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
        self.seed = seed
    }

    public static let factual = SamplingOptions()
    public static let greedy = SamplingOptions(temperature: 0, repeatPenalty: 1.05)
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String
    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// How the model expects a conversation to be laid out. Message contents are
/// always tokenized as plain text (special tokens are NOT parsed in them), so
/// a transcript that contains "<|im_start|>" cannot forge a turn.
public struct ChatFormat: Sendable {
    public var turnStart: @Sendable (ChatMessage.Role) -> String
    public var turnEnd: String
    /// Inserted right after the assistant turn starts (e.g. an empty
    /// thinking block, which switches hybrid models to non-thinking mode).
    public var assistantPreamble: String

    public init(turnStart: @escaping @Sendable (ChatMessage.Role) -> String, turnEnd: String, assistantPreamble: String) {
        self.turnStart = turnStart
        self.turnEnd = turnEnd
        self.assistantPreamble = assistantPreamble
    }

    /// ChatML as used by Qwen3/Qwen3.5, with thinking switched off exactly
    /// like the official template does for `enable_thinking=false`.
    public static let chatMLNoThinking = ChatFormat(
        turnStart: { "<|im_start|>\($0.rawValue)\n" },
        turnEnd: "<|im_end|>\n",
        assistantPreamble: "<think>\n\n</think>\n\n")
}

public struct GenerationProgress: Sendable {
    public var promptTokensDone: Int
    public var promptTokens: Int
    public var generatedTokens: Int
    public var maxTokens: Int
}

public struct GenerationResult: Sendable {
    public var text: String
    public var promptTokens: Int
    public var generatedTokens: Int
    public var promptSeconds: Double
    public var generationSeconds: Double
    /// true when the answer was cut by `maxTokens`.
    public var hitTokenLimit: Bool

    public var promptTokensPerSecond: Double { promptSeconds > 0 ? Double(promptTokens) / promptSeconds : 0 }
    public var tokensPerSecond: Double { generationSeconds > 0 ? Double(generatedTokens) / generationSeconds : 0 }
}

public enum LLMError: Error, LocalizedError {
    case modelLoad(String)
    case context
    case tokenize
    case promptTooLong(tokens: Int, limit: Int)
    case decode(Int32)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .modelLoad(let s): return "Не удалось загрузить языковую модель: \(s)"
        case .context: return "Не удалось подготовить языковую модель (не хватает памяти?)."
        case .tokenize: return "Не удалось разобрать текст для модели."
        case .promptTooLong(let t, let l): return "Текст слишком длинный для модели (\(t) из \(l) токенов)."
        case .decode(let c): return "Языковая модель остановилась с ошибкой (\(c))."
        case .cancelled: return "Остановлено."
        }
    }
}

/// Last lines of llama.cpp's own log (info and above), for diagnostics and
/// the self-test. Never contains transcript text: llama.cpp logs only model
/// and device information.
public enum LlamaLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var partial = ""

    static func append(_ level: ggml_log_level, _ text: String) {
        if level == GGML_LOG_LEVEL_DEBUG { return }
        lock.lock(); defer { lock.unlock() }
        partial += text
        while let nl = partial.firstIndex(of: "\n") {
            let line = String(partial[..<nl])
            partial = String(partial[partial.index(after: nl)...])
            if !line.isEmpty { lines.append(line) }
        }
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    public static var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

/// Thread-safe flag + check closure read by llama.cpp's C callbacks.
final class AbortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var check: (() -> Bool)?
    func set(_ c: (() -> Bool)?) { lock.lock(); check = c; lock.unlock() }
    var shouldAbort: Bool {
        lock.lock(); let c = check; lock.unlock()
        return c?() ?? false
    }
}

public final class LlamaEngine: @unchecked Sendable {
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let vocab: OpaquePointer
    private let lock = NSLock()
    private let abort: AbortBox
    private let format: ChatFormat
    private let batchTokens: Int

    public let contextTokens: Int
    /// A GPU device was available and the model was offloaded to it.
    public let usesGPU: Bool
    public let deviceDescription: String
    public let modelBytes: UInt64
    public let loadSeconds: Double

    /// One-time process setup: logging into LlamaLog, backends.
    /// METEORA_LLM_FORCE_CPU=1 hides Metal from ggml entirely (CI VMs whose
    /// paravirtualized GPU misbehaves); it must be set before the first load.
    private static let backend: Void = {
        if ProcessInfo.processInfo.environment["METEORA_LLM_FORCE_CPU"] == "1" {
            setenv("GGML_METAL_DEVICES", "0", 1)
        }
        llama_log_set({ level, text, _ in
            guard let text else { return }
            LlamaLog.append(level, String(cString: text))
        }, nil)
        llama_backend_init()
    }()

    /// GPU devices ggml registered (Metal on Apple silicon; none on Intel).
    public static var gpuDevices: [String] {
        _ = backend
        var out: [String] = []
        for type in [GGML_BACKEND_DEVICE_TYPE_GPU, GGML_BACKEND_DEVICE_TYPE_IGPU] {
            if let dev = ggml_backend_dev_by_type(type) {
                out.append(ggml_backend_dev_description(dev).map { String(cString: $0) } ?? "GPU")
            }
        }
        return out
    }

    /// Loads a GGUF model. Throws `.cancelled` if `isCancelled` turns true
    /// while the weights are being read.
    public init(modelPath: URL, options: LLMOptions = LLMOptions(), format: ChatFormat = .chatMLNoThinking,
                isCancelled: @escaping () -> Bool = { false }) throws {
        _ = Self.backend
        let t0 = Date()
        let box = AbortBox()
        let batch = max(32, options.batchTokens)
        let threads = Int32(max(1, options.threads))

        let gpus = Self.gpuDevices
        let offload = options.useGPU && !gpus.isEmpty

        var mp = llama_model_default_params()
        // CPU only: an empty, NULL-terminated device list keeps every tensor
        // and the cache in main memory.
        let noDevices = UnsafeMutablePointer<ggml_backend_dev_t?>.allocate(capacity: 1)
        noDevices.initialize(to: nil)
        defer { noDevices.deallocate() }
        if offload {
            mp.n_gpu_layers = -1
        } else {
            mp.n_gpu_layers = 0
            mp.devices = noDevices
        }
        box.set(isCancelled)
        mp.progress_callback = { _, data in
            guard let data else { return true }
            return !Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue().shouldAbort
        }
        mp.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()

        guard let m = llama_model_load_from_file(modelPath.path, mp) else {
            box.set(nil)
            if isCancelled() { throw LLMError.cancelled }
            let reason = LlamaLog.recent.last(where: { $0.contains("error") || $0.contains("failed") }) ?? "формат файла"
            throw LLMError.modelLoad(reason)
        }

        let trained = Int(llama_model_n_ctx_train(m))
        let nCtx = max(1024, trained > 0 ? min(options.contextTokens, trained) : options.contextTokens)
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(nCtx)
        cp.n_batch = UInt32(batch)
        cp.n_ubatch = UInt32(batch)
        cp.n_seq_max = 1
        cp.n_threads = threads
        cp.n_threads_batch = threads
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        cp.no_perf = true
        if !offload {
            cp.offload_kqv = false
            cp.op_offload = false
        }
        cp.abort_callback = { data in
            guard let data else { return false }
            return Unmanaged<AbortBox>.fromOpaque(data).takeUnretainedValue().shouldAbort
        }
        cp.abort_callback_data = Unmanaged.passUnretained(box).toOpaque()

        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            box.set(nil)
            throw LLMError.context
        }
        guard let v = llama_model_get_vocab(m) else {
            llama_free(c)
            llama_model_free(m)
            box.set(nil)
            throw LLMError.modelLoad("нет словаря")
        }
        box.set(nil)
        model = m
        ctx = c
        vocab = v
        abort = box
        self.format = format
        batchTokens = batch
        contextTokens = Int(llama_n_ctx(c))
        usesGPU = offload
        deviceDescription = offload ? (gpus.first ?? "GPU") : "CPU, \(threads) потоков"
        modelBytes = llama_model_size(m)
        loadSeconds = Date().timeIntervalSince(t0)
    }

    deinit {
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: Tokens

    /// Tokens of plain text (special-token syntax is NOT interpreted).
    public func countTokens(_ text: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return (try? tokenize(text, special: false).count) ?? text.utf8.count / 2
    }

    private func tokenize(_ text: String, special: Bool) throws -> [llama_token] {
        let len = text.utf8.count
        if len == 0 { return [] }
        guard len < Int(Int32.max) / 2 else { throw LLMError.tokenize }
        var capacity = len + 8
        var tokens = [llama_token](repeating: 0, count: capacity)
        var n = llama_tokenize(vocab, text, Int32(len), &tokens, Int32(capacity), false, special)
        if n < 0 {
            guard n != Int32.min else { throw LLMError.tokenize }
            capacity = Int(-n)
            tokens = [llama_token](repeating: 0, count: capacity)
            n = llama_tokenize(vocab, text, Int32(len), &tokens, Int32(capacity), false, special)
        }
        guard n >= 0 else { throw LLMError.tokenize }
        return Array(tokens.prefix(Int(n)))
    }

    /// Conversation → tokens. Template markers are tokenized with special
    /// tokens enabled; message contents never are.
    private func promptTokens(_ messages: [ChatMessage], assistantPrefix: String) throws -> [llama_token] {
        var out: [llama_token] = []
        if llama_vocab_get_add_bos(vocab) { out.append(llama_vocab_bos(vocab)) }
        for m in messages {
            out += try tokenize(format.turnStart(m.role), special: true)
            out += try tokenize(m.content, special: false)
            out += try tokenize(format.turnEnd, special: true)
        }
        out += try tokenize(format.turnStart(.assistant) + format.assistantPreamble, special: true)
        out += try tokenize(assistantPrefix, special: false)
        return out
    }

    /// Tokens the conversation would take, without generating.
    public func countPromptTokens(_ messages: [ChatMessage], assistantPrefix: String = "") -> Int {
        lock.lock(); defer { lock.unlock() }
        return (try? promptTokens(messages, assistantPrefix: assistantPrefix).count) ?? Int.max / 4
    }

    // MARK: Generation

    /// Generates the assistant's answer. `assistantPrefix` is fed to the
    /// model as the beginning of its answer (e.g. "{" to start JSON) and is
    /// NOT included in `text`. `stop` is checked every few tokens with the
    /// text so far; returning true ends generation early.
    public func generate(_ messages: [ChatMessage], assistantPrefix: String = "", maxTokens: Int,
                         sampling: SamplingOptions = .factual,
                         isCancelled: @escaping () -> Bool = { false },
                         stop: ((String) -> Bool)? = nil,
                         progress: ((GenerationProgress) -> Void)? = nil) throws -> GenerationResult {
        lock.lock(); defer { lock.unlock() }
        abort.set(isCancelled)
        defer { abort.set(nil) }

        var tokens = try promptTokens(messages, assistantPrefix: assistantPrefix)
        let limit = contextTokens - 8
        guard tokens.count + maxTokens <= limit else {
            throw LLMError.promptTooLong(tokens: tokens.count + maxTokens, limit: limit)
        }
        if let mem = llama_get_memory(ctx) { llama_memory_clear(mem, true) }

        guard let chain = makeSampler(sampling) else { throw LLMError.context }
        defer { llama_sampler_free(chain) }

        // Read the prompt.
        let t0 = Date()
        var done = 0
        while done < tokens.count {
            if isCancelled() { throw LLMError.cancelled }
            let n = min(batchTokens, tokens.count - done)
            let rc: Int32 = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress! + done, Int32(n)))
            }
            if rc == 2 || isCancelled() { throw LLMError.cancelled }
            guard rc == 0 else { throw LLMError.decode(rc) }
            done += n
            progress?(GenerationProgress(promptTokensDone: done, promptTokens: tokens.count,
                                         generatedTokens: 0, maxTokens: maxTokens))
        }
        let t1 = Date()

        // Write the answer.
        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        var generated = 0
        var hitLimit = true
        while generated < maxTokens {
            if isCancelled() { throw LLMError.cancelled }
            var token = llama_sampler_sample(chain, ctx, -1)  // also accepts the token
            if llama_vocab_is_eog(vocab, token) { hitLimit = false; break }
            var capacity = Int32(piece.count)
            var n = llama_token_to_piece(vocab, token, &piece, capacity, 0, false)
            if n < 0 {
                capacity = -n + 1
                piece = [CChar](repeating: 0, count: Int(capacity))
                n = llama_token_to_piece(vocab, token, &piece, capacity, 0, false)
            }
            if n > 0 { bytes += piece.prefix(Int(n)).map { UInt8(bitPattern: $0) } }
            generated += 1
            if generated % 8 == 0 {
                progress?(GenerationProgress(promptTokensDone: tokens.count, promptTokens: tokens.count,
                                             generatedTokens: generated, maxTokens: maxTokens))
                if let stop, stop(String(decoding: bytes, as: UTF8.self)) { hitLimit = false; break }
            }
            if generated >= maxTokens { break }
            let rc: Int32 = withUnsafeMutablePointer(to: &token) { p in
                llama_decode(ctx, llama_batch_get_one(p, 1))
            }
            if rc == 2 || isCancelled() { throw LLMError.cancelled }
            guard rc == 0 else { throw LLMError.decode(rc) }
        }
        let t2 = Date()
        tokens.removeAll()
        let text = String(decoding: bytes, as: UTF8.self)
        return GenerationResult(text: text, promptTokens: done, generatedTokens: generated,
                                promptSeconds: t1.timeIntervalSince(t0), generationSeconds: t2.timeIntervalSince(t1),
                                hitTokenLimit: hitLimit && generated >= maxTokens)
    }

    private func makeSampler(_ s: SamplingOptions) -> UnsafeMutablePointer<llama_sampler>? {
        var params = llama_sampler_chain_default_params()
        params.no_perf = true
        guard let chain = llama_sampler_chain_init(params) else { return nil }
        if s.temperature <= 0 {
            if s.repeatPenalty != 1 {
                llama_sampler_chain_add(chain, llama_sampler_init_top_k(max(1, s.topK)))
                llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), s.repeatLastN,
                                                                            s.repeatPenalty, 0, 0))
            }
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(max(1, s.topK)))
        if s.repeatPenalty != 1 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), s.repeatLastN,
                                                                        s.repeatPenalty, 0, 0))
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(s.minP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(s.seed))
        return chain
    }
}
