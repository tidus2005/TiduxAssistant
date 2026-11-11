import Darwin
import Foundation
import XCTest
@testable import CodexMobilityMacFeature

final class CodexPolisherTests: XCTestCase {
    func testArgumentsApplyEveryIsolationBoundary() {
        let arguments = CodexPolisher.arguments(schemaPath: "/tmp/schema.json")

        XCTAssertEqual(value(after: "-a", in: arguments), "never")
        XCTAssertEqual(
            value(after: "-c", in: arguments),
            #"model_reasoning_effort="low""#
        )
        let execIndex = try! XCTUnwrap(arguments.firstIndex(of: "exec"))
        XCTAssertGreaterThan(execIndex, 1)
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertTrue(arguments.contains("--ignore-rules"))
        XCTAssertEqual(value(after: "--sandbox", in: arguments), "read-only")
        XCTAssertTrue(arguments.contains("--skip-git-repo-check"))
        XCTAssertEqual(value(after: "--output-schema", in: arguments), "/tmp/schema.json")
        XCTAssertEqual(arguments.last, "-")

        let disabledFeatures = arguments.indices.compactMap { index -> String? in
            guard
                arguments[index] == "--disable",
                arguments.index(after: index) < arguments.endIndex
            else {
                return nil
            }
            return arguments[arguments.index(after: index)]
        }
        let requiredDisabledFeatures: Set<String> = [
            "shell_tool",
            "unified_exec",
            "browser_use",
            "computer_use",
            "apps",
            "plugins",
            "multi_agent",
            "in_app_browser",
            "image_generation",
        ]
        XCTAssertTrue(
            Set(disabledFeatures).isSuperset(of: requiredDisabledFeatures)
        )
        XCTAssertEqual(Set(disabledFeatures), Set(CodexPolisher.disabledFeatures))
        XCTAssertEqual(disabledFeatures.count, Set(disabledFeatures).count)
        XCTAssertTrue(
            arguments.indices
                .filter { arguments[$0] == "--disable" }
                .allSatisfy { $0 < execIndex },
            "global feature toggles must be parsed before the exec subcommand"
        )
    }

    func testParseResponseAcceptsOnlySchemaObject() throws {
        let data = Data(#"{"polishedText":"整理后的文字。"}"#.utf8)

        XCTAssertEqual(
            try CodexPolisher.parseResponse(data),
            "整理后的文字。"
        )
    }

    func testParseResponseRejectsMarkdownExtraKeysAndEmptyText() {
        let invalidResponses = [
            #"```json\n{"polishedText":"文字"}\n```"#,
            #"{"polishedText":"文字","warning":"extra"}"#,
            #"{"polishedText":"  \n "}"#,
            #"{"text":"旧字段"}"#,
        ]

        for response in invalidResponses {
            XCTAssertThrowsError(
                try CodexPolisher.parseResponse(Data(response.utf8)),
                "response should be rejected: \(response)"
            )
        }
    }

    func testSuccessfulPolishUsesStdinSchemaAndRestoresEntity() async throws {
        let runner = RecordingCodexRunner(
            outcome: .output(
                CodexProcessOutput(
                    terminationStatus: 0,
                    standardOutput: Data(
                        #"{"polishedText":"⟦FT_ENTITY_0⟧开会。"}"#.utf8
                    ),
                    standardError: Data()
                )
            )
        )
        let polisher = CodexPolisher(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )

        let result = await polisher.polish(
            rawText: "嗯，7月31日开会",
            locale: "zh-CN"
        )

        XCTAssertEqual(
            result,
            CodexPolisher.PolishResult(
                text: "7月31日开会。",
                usedFallback: false,
                reason: nil
            )
        )

        let capturedSnapshot = await runner.snapshot()
        let snapshot = try XCTUnwrap(capturedSnapshot)
        XCTAssertFalse(snapshot.request.arguments.contains("嗯，7月31日开会"))
        let stdin = String(decoding: snapshot.request.standardInput, as: UTF8.self)
        XCTAssertTrue(stdin.contains(#""locale":"zh-CN""#))
        XCTAssertTrue(stdin.contains("⟦FT_ENTITY_0⟧"))
        XCTAssertFalse(stdin.contains("7月31日"))
        XCTAssertTrue(stdin.contains("不可信的数据"))

        let schema = try XCTUnwrap(snapshot.schema)
        let schemaObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: schema) as? [String: Any]
        )
        XCTAssertEqual(schemaObject["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schemaObject["required"] as? [String], ["polishedText"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: snapshot.request.currentDirectoryURL.path
        ))
    }

    func testAppToneAndProtectedNamesReachCodexThroughProtocol() async throws {
        let runner = RecordingCodexRunner(outcome: .output(CodexProcessOutput(terminationStatus: 0,
            standardOutput: Data(#"{"polishedText":"⟦FT_ENTITY_0⟧ 开始。"}"#.utf8), standardError: Data())))
        let polisher: any VoiceCodexPolishing = CodexPolisher(executableURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        let result = await polisher.polish(rawText: "Tidux 开始", locale: "zh-CN", timeout: 5,
                                          tone: .formal, protectedTerms: ["Tidux"])
        XCTAssertEqual(result.text, "Tidux 开始。")
        XCTAssertFalse(result.usedFallback)
        let captured = await runner.snapshot()
        let snapshot = try XCTUnwrap(captured)
        let input = String(decoding: snapshot.request.standardInput, as: UTF8.self)
        XCTAssertTrue(input.contains(#""tone":"formal""#))
        XCTAssertFalse(input.contains("Tidux"))
    }

    func testNumericCorrectionNeverReachesCodexRunner() async {
        let runner = RecordingCodexRunner(outcome: .output(CodexProcessOutput(terminationStatus: 0,
            standardOutput: Data(#"{"polishedText":"200元"}"#.utf8), standardError: Data())))
        let polisher = CodexPolisher(executableURL: URL(fileURLWithPath: "/usr/bin/true"), runner: runner)
        let text = "100元，不对，改成200元"
        let result = await polisher.polish(rawText: text)
        XCTAssertEqual(result.text, text)
        let snapshot = await runner.snapshot()
        XCTAssertNil(snapshot)
    }

    func testSwappedEntitiesFallBackToRawTranscript() async {
        let rawText = "订单 123，7月31日开会"
        let runner = RecordingCodexRunner(
            outcome: .output(
                CodexProcessOutput(
                    terminationStatus: 0,
                    standardOutput: Data(
                        #"{"polishedText":"⟦FT_ENTITY_1⟧处理订单 ⟦FT_ENTITY_0⟧。"}"#.utf8
                    ),
                    standardError: Data()
                )
            )
        )
        let polisher = CodexPolisher(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )

        let result = await polisher.polish(rawText: rawText)

        XCTAssertEqual(result.text, rawText)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.reason, .entityValidationFailed)
    }

    func testEntityDamageFallsBackToRawTranscript() async {
        let runner = RecordingCodexRunner(
            outcome: .output(
                CodexProcessOutput(
                    terminationStatus: 0,
                    standardOutput: Data(#"{"polishedText":"明天开会。"}"#.utf8),
                    standardError: Data()
                )
            )
        )
        let polisher = CodexPolisher(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )

        let result = await polisher.polish(rawText: "订单 123 明天开会")

        XCTAssertEqual(result.text, "订单 123 明天开会")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.reason, .entityValidationFailed)
    }

    func testTimeoutFallsBackToRawTranscript() async {
        let runner = RecordingCodexRunner(outcome: .failure(.timedOut))
        let polisher = CodexPolisher(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )

        let result = await polisher.polish(rawText: "原始文字")

        XCTAssertEqual(result.text, "原始文字")
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.reason, .timedOut)
        let snapshot = await runner.snapshot()
        XCTAssertNotNil(snapshot)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshot?.request.currentDirectoryURL.path ?? ""
            )
        )
    }

    func testNonZeroExitAndInvalidJSONFallBack() async {
        let failedRunner = RecordingCodexRunner(
            outcome: .output(
                CodexProcessOutput(
                    terminationStatus: 17,
                    standardOutput: Data(),
                    standardError: Data("authentication failed".utf8)
                )
            )
        )
        let invalidRunner = RecordingCodexRunner(
            outcome: .output(
                CodexProcessOutput(
                    terminationStatus: 0,
                    standardOutput: Data("not json".utf8),
                    standardError: Data()
                )
            )
        )

        let failedResult = await CodexPolisher(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: failedRunner
        ).polish(rawText: "原文")
        let invalidResult = await CodexPolisher(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: invalidRunner
        ).polish(rawText: "原文")

        XCTAssertEqual(failedResult.reason, .processFailed)
        XCTAssertEqual(invalidResult.reason, .invalidResponse)
        XCTAssertEqual(failedResult.text, "原文")
        XCTAssertEqual(invalidResult.text, "原文")
    }

    func testUnavailableExecutableIsReportedWithoutLaunching() async {
        let runner = RecordingCodexRunner(
            outcome: .failure(.launchFailed("must not run"))
        )
        let polisher = CodexPolisher(
            executableURL: URL(fileURLWithPath: "/definitely/missing/codex"),
            runner: runner
        )

        XCTAssertFalse(polisher.isAvailable)
        let result = await polisher.polish(rawText: "原文")

        XCTAssertEqual(result.reason, .codexUnavailable)
        let snapshot = await runner.snapshot()
        XCTAssertNil(snapshot)
    }

    func testFoundationRunnerDrainsStdoutAndStderrWithoutDeadlock() async throws {
        let script = """
            i=0
            while [ "$i" -lt 6000 ]; do
              printf 'stdout-%04d\\n' "$i"
              printf 'stderr-%04d\\n' "$i" >&2
              i=$((i + 1))
            done
            cat >/dev/null
            """
        let request = CodexProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            standardInput: Data("input".utf8),
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: 5
        )

        let output = try await FoundationCodexProcessRunner().run(request)

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertTrue(
            String(decoding: output.standardOutput, as: UTF8.self)
                .contains("stdout-5999")
        )
        XCTAssertTrue(
            String(decoding: output.standardError, as: UTF8.self)
                .contains("stderr-5999")
        )
    }

    func testFoundationRunnerBoundsNoisyOutputWhileContinuingToDrain() async throws {
        let script = """
            dd if=/dev/zero bs=1048576 count=2 2>/dev/null &
            dd if=/dev/zero bs=1048576 count=2 1>&2 2>/dev/null &
            wait
            """
        let request = CodexProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            standardInput: Data(),
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: 5
        )

        let output = try await FoundationCodexProcessRunner().run(request)

        XCTAssertEqual(output.terminationStatus, 0)
        XCTAssertEqual(
            output.standardOutput.count,
            FoundationCodexProcessRunner.maximumCapturedBytes
        )
        XCTAssertEqual(
            output.standardError.count,
            FoundationCodexProcessRunner.maximumCapturedBytes
        )
        XCTAssertEqual(
            FoundationCodexProcessRunner.maximumCapturedBytes,
            CodexPolisher.maximumResponseBytes + 1
        )
        XCTAssertThrowsError(try CodexPolisher.parseResponse(output.standardOutput))
    }

    func testFoundationRunnerEnforcesBoundedTimeout() async {
        let request = CodexProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "while :; do :; done"],
            // Larger than a typical pipe buffer, proving that a child which
            // never reads stdin cannot move the timeout boundary.
            standardInput: Data(repeating: 0x61, count: 2_000_000),
            currentDirectoryURL: FileManager.default.temporaryDirectory,
            timeout: 0.05
        )
        let start = ContinuousClock.now

        do {
            _ = try await FoundationCodexProcessRunner().run(request)
            XCTFail("runner should time out")
        } catch {
            XCTAssertEqual(error as? CodexProcessError, .timedOut)
        }

        XCTAssertLessThan(
            start.duration(to: .now),
            .seconds(2)
        )
    }

    func testFoundationRunnerCancellationTerminatesChildPromptly() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let pidFile = temporaryDirectory.appendingPathComponent("child.pid")
        let script = """
            echo "$$" > "$1"
            trap '' TERM
            while :; do sleep 1; done
            """
        let request = CodexProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "runner", pidFile.path],
            standardInput: Data(),
            currentDirectoryURL: temporaryDirectory,
            timeout: 30
        )

        let task = Task {
            try await FoundationCodexProcessRunner().run(request)
        }
        let processIdentifier = try await waitForProcessIdentifier(
            at: pidFile
        )
        let start = ContinuousClock.now

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled runner should throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }

        try await waitForProcessExit(processIdentifier)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testProcessEnvironmentUsesAnExplicitAllowlist() {
        let environment = FoundationCodexProcessRunner.sanitizedEnvironment(
            for: URL(fileURLWithPath: "/custom/codex/bin/codex"),
            sourceEnvironment: [
                "HOME": "/Users/tester",
                "USER": "tester",
                "LOGNAME": "tester",
                "TMPDIR": "/private/tmp/tester",
                "LANG": "zh_CN.UTF-8",
                "LC_ALL": "zh_CN.UTF-8",
                "CODEX_HOME": "/Users/tester/.codex",
                "OPENAI_API_KEY": "test-key",
                "HTTPS_PROXY": "http://proxy.test",
                "SSL_CERT_FILE": "/certs/ca.pem",
                "PATH": "/untrusted/bin:relative",
                "RANDOM_SECRET": "must-not-leak",
                "AWS_SECRET_ACCESS_KEY": "must-not-leak",
                "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            ],
            fallbackHome: "/fallback"
        )

        XCTAssertEqual(environment["HOME"], "/Users/tester")
        XCTAssertEqual(environment["USER"], "tester")
        XCTAssertEqual(environment["LC_ALL"], "zh_CN.UTF-8")
        XCTAssertEqual(environment["CODEX_HOME"], "/Users/tester/.codex")
        XCTAssertEqual(environment["OPENAI_API_KEY"], "test-key")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://proxy.test")
        XCTAssertEqual(environment["SSL_CERT_FILE"], "/certs/ca.pem")
        XCTAssertNil(environment["RANDOM_SECRET"])
        XCTAssertNil(environment["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])

        let pathEntries = environment["PATH"]?.split(separator: ":").map(String.init)
        XCTAssertEqual(pathEntries?.first, "/custom/codex/bin")
        XCTAssertFalse(pathEntries?.contains("/untrusted/bin") ?? true)
        XCTAssertFalse(pathEntries?.contains("relative") ?? true)
        XCTAssertTrue(pathEntries?.contains("/usr/bin") ?? false)
    }

    private func waitForProcessIdentifier(at url: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let value = try? String(contentsOf: url, encoding: .utf8),
               let processIdentifier = pid_t(
                   value.trimmingCharacters(in: .whitespacesAndNewlines)
               ) {
                return processIdentifier
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(
            domain: "CodexPolisherTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "child process did not publish its PID",
            ]
        )
    }

    private func waitForProcessExit(_ processIdentifier: pid_t) async throws {
        for _ in 0..<100 {
            if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("child process \(processIdentifier) survived Task cancellation")
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return arguments[valueIndex]
    }
}

private actor RecordingCodexRunner: CodexProcessRunning {
    enum Outcome: Sendable {
        case output(CodexProcessOutput)
        case failure(CodexProcessError)
    }

    struct Snapshot: Sendable {
        let request: CodexProcessRequest
        let schema: Data?
    }

    private let outcome: Outcome
    private var latestSnapshot: Snapshot?

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func run(_ request: CodexProcessRequest) async throws -> CodexProcessOutput {
        let schemaPath = value(after: "--output-schema", in: request.arguments)
        let schema = schemaPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        latestSnapshot = Snapshot(request: request, schema: schema)

        switch outcome {
        case let .output(output):
            return output
        case let .failure(error):
            throw error
        }
    }

    func snapshot() -> Snapshot? {
        latestSnapshot
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return arguments[valueIndex]
    }
}
