// ============================================================================
// apfel — Apple Intelligence from the command line
// https://github.com/Arthur-Ficial/apfel
//
// A lightweight CLI for Apple's on-device FoundationModels framework.
// No API keys. No cloud. No dependencies. Just your Mac thinking locally.
//
// Usage:
//   apfel "prompt"              — single prompt, plain text response
//   apfel --stream "prompt"     — stream response tokens as they generate
//   apfel --chat                — interactive multi-turn conversation
//   apfel -o json "prompt"      — JSON output for scripting/pipelines
//   echo "prompt" | apfel       — read prompt from stdin
//
// Requirements:
//   - macOS 26 (Tahoe) or later
//   - Swift 6.2+ command line tools
//   - Apple Intelligence enabled in System Settings
//
// License: MIT
// ============================================================================

import FoundationModels
import Foundation

// MARK: - Configuration

/// Semantic version following https://semver.org
let version = "0.1.0"

/// Binary name — used in help text and version output
let appName = "apfel"

/// Model identifier for JSON output. Apple doesn't expose a model name through
/// the FoundationModels API, so we use a descriptive constant.
let modelName = "apple-foundationmodel"

// MARK: - Exit Codes
// Following Unix conventions: 0 = success, 1 = runtime error, 2 = usage error
// See: https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html

let exitSuccess: Int32 = 0
let exitRuntimeError: Int32 = 1   // Model/inference failures
let exitUsageError: Int32 = 2     // Bad arguments, missing prompt

// MARK: - Signal Handling
// Install SIGINT handler before any async work begins.
// Exit code 130 = 128 + SIGINT(2), the Unix convention for signal termination.
// We reset ANSI formatting to prevent terminal corruption after Ctrl+C.

signal(SIGINT) { _ in
    if isatty(STDOUT_FILENO) != 0 {
        FileHandle.standardOutput.write(Data("\u{001B}[0m".utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))
    _exit(130)
}

// MARK: - Output Format

/// Supported output formats for responses.
/// - `plain`: Human-readable text (default). Supports ANSI colors when on a TTY.
/// - `json`: Machine-readable JSON. Single object for prompts, JSONL for chat.
enum OutputFormat: String {
    case plain
    case json
}

// MARK: - Global State
// These flags are set during argument parsing (before any async work) and read
// during execution. Marked `nonisolated(unsafe)` because Swift 6 strict
// concurrency treats global mutable state as @MainActor-isolated by default.
// Safe here: single-threaded CLI, write-once-read-many pattern.

/// True if the NO_COLOR environment variable is set (https://no-color.org)
let noColorEnv = ProcessInfo.processInfo.environment["NO_COLOR"] != nil

/// True if --no-color flag was passed
nonisolated(unsafe) var noColorFlag = false

/// Output format: plain (default) or json
nonisolated(unsafe) var outputFormat: OutputFormat = .plain

/// True if --quiet flag was passed (suppresses headers, prompts, chrome)
nonisolated(unsafe) var quietMode = false

// MARK: - ANSI Colors
// Terminal escape codes for colored output. Only applied when stdout is a TTY
// and neither NO_COLOR env nor --no-color flag is set.

enum Color: String {
    case reset   = "\u{001B}[0m"
    case bold    = "\u{001B}[1m"
    case dim     = "\u{001B}[2m"
    case cyan    = "\u{001B}[36m"
    case green   = "\u{001B}[32m"
    case yellow  = "\u{001B}[33m"
    case magenta = "\u{001B}[35m"
    case red     = "\u{001B}[31m"
}

/// Apply ANSI color codes to text. Returns plain text if:
/// - stdout is not a TTY (piped output)
/// - NO_COLOR environment variable is set
/// - --no-color flag was passed
func styled(_ text: String, _ colors: Color...) -> String {
    let isTerminal = isatty(STDOUT_FILENO) != 0
    guard isTerminal, !noColorEnv, !noColorFlag else { return text }
    let prefix = colors.map(\.rawValue).joined()
    return "\(prefix)\(text)\(Color.reset.rawValue)"
}

// MARK: - Output Helpers
// All diagnostic output (errors, headers, prompts) goes to stderr.
// Only response content goes to stdout. This keeps stdout clean for piping.

let stderr = FileHandle.standardError

/// Print a message to stderr with a trailing newline.
func printStderr(_ message: String) {
    stderr.write(Data("\(message)\n".utf8))
}

/// Print a styled error message to stderr. Format: "error: <message>"
func printError(_ message: String) {
    stderr.write(Data("\(styled("error:", .red, .bold)) \(message)\n".utf8))
}

/// Print the chat mode header (app name, version, separator line).
/// Suppressed in --quiet mode. Routed to stderr in JSON mode.
func printHeader() {
    guard !quietMode else { return }
    let header = styled("Apple Intelligence", .cyan, .bold)
        + styled(" · on-device LLM · \(appName) v\(version)", .dim)
    let line = styled(String(repeating: "─", count: 56), .dim)
    if outputFormat == .json {
        printStderr(header)
        printStderr(line)
    } else {
        print(header)
        print(line)
    }
}

// MARK: - JSON Encoding
// Structured types for JSON output. Uses Codable for type-safe serialization.

/// JSON response for single-prompt mode.
/// Schema:
/// ```json
/// {
///   "model": "apple-foundationmodel",
///   "content": "response text",
///   "metadata": { "on_device": true, "version": "0.1.0" }
/// }
/// ```
struct ApfelResponse: Encodable {
    let model: String
    let content: String
    let metadata: Metadata

    struct Metadata: Encodable {
        let onDevice: Bool
        let version: String

        enum CodingKeys: String, CodingKey {
            case onDevice = "on_device"
            case version
        }
    }
}

/// JSON message for chat JSONL output.
/// Schema: `{"role": "user"|"assistant", "content": "...", "model": "..."}`
/// The `model` field is only present for assistant messages.
struct ChatMessage: Encodable {
    let role: String
    let content: String
    let model: String?
}

/// Encode a value to a JSON string.
/// - Parameters:
///   - value: Any Encodable value
///   - pretty: If true, use pretty-printed formatting (default for single prompts).
///             If false, use compact single-line format (used for JSONL chat output).
/// - Returns: JSON string, or "{}" if encoding fails.
func jsonString(_ value: some Encodable, pretty: Bool = true) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
    guard let data = try? encoder.encode(value),
          let str = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return str
}

// MARK: - Session Factory

/// Create a LanguageModelSession with optional system instructions.
/// The session maintains conversation history for multi-turn chat.
func makeSession(systemPrompt: String?) -> LanguageModelSession {
    if let sys = systemPrompt {
        return LanguageModelSession(instructions: sys)
    }
    return LanguageModelSession()
}

// MARK: - Stream Helper

/// Stream a response from the model, optionally printing deltas to stdout.
///
/// FoundationModels returns cumulative snapshots (each snapshot contains the full
/// response so far), so we compute deltas by tracking the previous content length.
///
/// - Parameters:
///   - session: The language model session to use
///   - prompt: The user's input text
///   - printDelta: If true, print each new chunk to stdout as it arrives.
///                 Set to false when buffering for JSON output.
/// - Returns: The complete response text after all chunks have been received.
func collectStream(
    _ session: LanguageModelSession,
    prompt: String,
    printDelta: Bool
) async throws -> String {
    let response = session.streamResponse(to: prompt)
    var prev = ""
    for try await snapshot in response {
        let content = snapshot.content
        // Only process if new content has been added (cumulative snapshots)
        if content.count > prev.count {
            let idx = content.index(content.startIndex, offsetBy: prev.count)
            let delta = String(content[idx...])
            if printDelta {
                print(delta, terminator: "")
                fflush(stdout)  // Flush immediately for real-time streaming
            }
        }
        prev = content
    }
    return prev
}

// MARK: - Commands

/// Handle a single (non-interactive) prompt.
///
/// Behavior depends on output format:
/// - **plain**: Print response directly. If streaming, print tokens as they arrive.
/// - **json**: Buffer the complete response, then emit a single JSON object.
///             Streaming is used internally for buffering but output isn't shown
///             until the response is complete (to ensure valid JSON).
func singlePrompt(_ prompt: String, systemPrompt: String?, stream: Bool) async throws {
    let session = makeSession(systemPrompt: systemPrompt)

    switch outputFormat {
    case .plain:
        if stream {
            let _ = try await collectStream(session, prompt: prompt, printDelta: true)
            print()  // Trailing newline after streamed output
        } else {
            let response = try await session.respond(to: prompt)
            print(response.content)
        }

    case .json:
        // Buffer the full response for valid JSON, regardless of stream flag
        let content: String
        if stream {
            content = try await collectStream(session, prompt: prompt, printDelta: false)
        } else {
            let response = try await session.respond(to: prompt)
            content = response.content
        }
        let obj = ApfelResponse(
            model: modelName,
            content: content,
            metadata: .init(onDevice: true, version: version)
        )
        print(jsonString(obj))
    }
}

/// Run an interactive multi-turn chat session.
///
/// Reads user input from stdin in a loop, sends each message to the model,
/// and streams the response. Maintains conversation context across turns
/// via the LanguageModelSession.
///
/// Behavior depends on output format:
/// - **plain**: Colored prompts ("you›" / "ai›"), streamed responses, header/footer.
/// - **json**: JSONL output (one JSON object per line). User and assistant messages
///             are each a separate line. All chrome (prompts, headers) goes to stderr.
///
/// Exits on: "quit", "exit", EOF (Ctrl+D).
func chat(systemPrompt: String?) async throws {
    // Chat mode requires interactive input — can't read from a pipe
    guard isatty(STDIN_FILENO) != 0 else {
        printError("--chat requires an interactive terminal (stdin must be a TTY)")
        exit(exitUsageError)
    }

    let session = makeSession(systemPrompt: systemPrompt)
    var turn = 0

    // Print header and hints (suppressed in quiet mode, routed to stderr in JSON mode)
    printHeader()
    if !quietMode {
        if let sys = systemPrompt {
            let sysLine = styled("system: ", .magenta, .bold) + styled(sys, .dim)
            if outputFormat == .json {
                printStderr(sysLine)
            } else {
                print(sysLine)
            }
        }
        let hint = styled("Type 'quit' to exit.\n", .dim)
        if outputFormat == .json {
            printStderr(hint)
        } else {
            print(hint)
        }
    }

    // Main chat loop
    while true {
        // Show input prompt (stderr in JSON mode to keep stdout clean)
        if !quietMode {
            let prompt = styled("you› ", .green, .bold)
            if outputFormat == .json {
                stderr.write(Data(prompt.utf8))
            } else {
                print(prompt, terminator: "")
            }
        }
        fflush(stdout)

        // Read user input (nil = EOF / Ctrl+D)
        guard let input = readLine() else { break }
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed.lowercased() == "quit" || trimmed.lowercased() == "exit" { break }

        turn += 1

        // In JSON mode, emit the user's message as JSONL before the response
        if outputFormat == .json {
            print(jsonString(
                ChatMessage(role: "user", content: trimmed, model: nil),
                pretty: false
            ))
            fflush(stdout)
        }

        // Show "ai›" prompt in plain mode
        if !quietMode && outputFormat == .plain {
            print(styled(" ai› ", .cyan, .bold), terminator: "")
            fflush(stdout)
        }

        // Generate and output the response
        switch outputFormat {
        case .plain:
            let _ = try await collectStream(session, prompt: trimmed, printDelta: true)
            print("\n")  // Blank line between turns for readability

        case .json:
            // Buffer full response, then emit as single JSONL line
            let content = try await collectStream(session, prompt: trimmed, printDelta: false)
            print(jsonString(
                ChatMessage(role: "assistant", content: content, model: modelName),
                pretty: false
            ))
            fflush(stdout)
        }
    }

    if !quietMode {
        let bye = styled("\nGoodbye.", .dim)
        if outputFormat == .json {
            printStderr(bye)
        } else {
            print(bye)
        }
    }
}

// MARK: - Usage

/// Print the help text. Styled with ANSI colors when on a TTY.
func printUsage() {
    print("""
    \(styled(appName, .cyan, .bold)) v\(version) — Apple Intelligence from the command line

    \(styled("USAGE:", .yellow, .bold))
      \(appName) [OPTIONS] <prompt>       Send a single prompt
      \(appName) --chat                   Interactive conversation
      \(appName) --stream <prompt>        Stream a single response

    \(styled("OPTIONS:", .yellow, .bold))
      -s, --system <text>     Set a system prompt to guide the model
      -o, --output <format>   Output format: plain, json [default: plain]
      -q, --quiet             Suppress non-essential output
          --no-color           Disable colored output
      -h, --help              Show this help
      -v, --version           Print version

    \(styled("ENVIRONMENT:", .yellow, .bold))
      NO_COLOR                Disable colored output (https://no-color.org)

    \(styled("EXAMPLES:", .yellow, .bold))
      \(appName) "What is the capital of Austria?"
      \(appName) --stream "Write a haiku about code"
      \(appName) -s "You are a pirate" --chat
      \(appName) -s "Be concise" "Explain recursion"
      echo "Summarize this" | \(appName)
      \(appName) -o json "Translate to German: hello"
      \(appName) -o json "List 3 colors" | jq .content
    """)
}

// MARK: - Argument Parsing
// Hand-rolled argument parser. Keeps the project dependency-free.
// Processes flags left-to-right. Remaining non-flag arguments are joined
// as the prompt text. This allows natural usage like: apfel Hello world

var args = Array(CommandLine.arguments.dropFirst())

// When stdin is piped and no arguments given, read the prompt from stdin.
// This enables: echo "question" | apfel
if args.isEmpty {
    if isatty(STDIN_FILENO) == 0 {
        var lines: [String] = []
        while let line = readLine(strippingNewline: false) {
            lines.append(line)
        }
        let input = lines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty {
            do {
                try await singlePrompt(input, systemPrompt: nil, stream: true)
                exit(exitSuccess)
            } catch {
                printError(error.localizedDescription)
                exit(exitRuntimeError)
            }
        }
    }
    printUsage()
    exit(exitUsageError)
}

// Parse flags and collect the prompt
var systemPrompt: String? = nil
var mode: String = "single"
var prompt: String = ""

var i = 0
while i < args.count {
    switch args[i] {
    case "-h", "--help":
        printUsage()
        exit(exitSuccess)

    case "-v", "--version":
        print("\(appName) v\(version)")
        exit(exitSuccess)

    case "-s", "--system":
        i += 1
        guard i < args.count else {
            printError("--system requires a value")
            exit(exitUsageError)
        }
        systemPrompt = args[i]

    case "-o", "--output":
        i += 1
        guard i < args.count else {
            printError("--output requires a value (plain or json)")
            exit(exitUsageError)
        }
        guard let fmt = OutputFormat(rawValue: args[i]) else {
            printError("unknown output format: \(args[i]) (use plain or json)")
            exit(exitUsageError)
        }
        outputFormat = fmt

    case "-q", "--quiet":
        quietMode = true

    case "--no-color":
        noColorFlag = true

    case "--chat":
        mode = "chat"

    case "--stream":
        mode = "stream"

    default:
        if args[i].hasPrefix("-") {
            printError("unknown option: \(args[i])")
            exit(exitUsageError)
        }
        // All remaining arguments form the prompt (no quoting needed for multi-word)
        prompt = args[i...].joined(separator: " ")
        i = args.count
        continue
    }
    i += 1
}

// MARK: - Dispatch
// Route to the appropriate command based on parsed mode.
// Top-level do/catch ensures runtime errors (model failures) exit with code 1.

do {
    switch mode {
    case "chat":
        try await chat(systemPrompt: systemPrompt)

    case "stream":
        guard !prompt.isEmpty else {
            printError("no prompt provided")
            exit(exitUsageError)
        }
        try await singlePrompt(prompt, systemPrompt: systemPrompt, stream: true)

    default:
        guard !prompt.isEmpty else {
            printError("no prompt provided")
            exit(exitUsageError)
        }
        try await singlePrompt(prompt, systemPrompt: systemPrompt, stream: false)
    }
} catch {
    printError(error.localizedDescription)
    exit(exitRuntimeError)
}
