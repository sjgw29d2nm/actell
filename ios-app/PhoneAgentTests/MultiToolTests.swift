import XCTest
import SwiftAgentKit
import ProviderCore
@testable import PhoneAgent

private actor BatchBridge: DeviceBridge {
    var events: [String] = []
    let failInput: Bool
    let appQueryError: AppError?
    init(failInput: Bool = false, appQueryError: AppError? = nil) {
        self.failInput = failInput; self.appQueryError = appQueryError
    }
    func screenshot() async throws -> FrameImage {
        events.append("screenshot")
        return FrameImage(id: UUID().uuidString, png: Data(), width: 100, height: 100, capturedAt: Date(), isDemo: true)
    }
    func tap(x: Int, y: Int, imageID: String) async throws {
        events.append("tap")
        if failInput { throw AppError.unknownOutcome }
    }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int, durationMS: Int, imageID: String) async throws { events.append("drag") }
    func installedApplications() async throws -> Data {
        events.append("list_apps")
        if let appQueryError { throw appQueryError }
        return Data("[]".utf8)
    }
    func stop() async { events.append("stop") }
    func granted() { events.append("approve") }
}

private actor BatchRequestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct BatchProvider: ModelProvider {
    static let name = "synthetic-batch"
    let configuration = ProviderConfiguration(name: name, baseURL: URL(string: "https://invalid.invalid")!, defaultModel: "fixture")
    let batches: [[ModelToolCall]]
    var expectedErrors: Set<String> = []
    var requestCounter: BatchRequestCounter?
    func complete(_ request: ModelRequest) async throws -> ModelResponse {
        await requestCounter?.record()
        let turn = request.messages.filter { !($0.toolCalls ?? []).isEmpty }.count
        let results = request.messages.filter { $0.role == .tool }
        let expected = batches.prefix(turn).flatMap { $0 }.map(\.id)
        XCTAssertEqual(results.map(\.toolCallId), expected.map(Optional.some), "Every result must reach the next model turn once, in order")
        for result in results {
            XCTAssertEqual(result.content.contains("ERROR"), expectedErrors.contains(result.toolCallId ?? ""))
        }
        if turn >= batches.count {
            return ModelResponse(text: "batch finished", finishReason: .stop, request: request, providerName: Self.name)
        }
        return ModelResponse(text: "", finishReason: .toolCalls, toolCalls: batches[turn], request: request, providerName: Self.name)
    }
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    for call in response.toolCalls { continuation.yield(.toolCall(call)) }
                    if !response.text.isEmpty { continuation.yield(.text(response.text)) }
                    continuation.yield(.finish(reason: response.finishReason, usage: nil)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class MultiToolTests: XCTestCase {
    private func call(_ id: String, _ name: String, _ arguments: String = "{}") -> ModelToolCall { .init(id: id, name: name, arguments: arguments) }
    private let tap = "{\"x\":10,\"y\":20,\"purpose\":\"synthetic tap\"}"
    private let skill: SkillPackage = try! SkillPackage.make(documents: ["SKILL.md": "---\nname: batch-guide\ndescription: Synthetic batch reference\n---\nBATCH_REFERENCE"])
    private func skillCall() -> ModelToolCall {
        call("skills", "load_skill", String(decoding: try! JSONEncoder().encode(["id": skill.id.uuidString, "revision": skill.revision]), as: UTF8.self))
    }
    private func runner(_ batches: [[ModelToolCall]], bridge: BatchBridge, errors: Set<String> = [], approval: (@Sendable (Approval) async -> Bool)? = nil) -> Agent {
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: approval ?? { _ in await bridge.granted(); return true }, onImage: { _, _ in }, onReceipt: { _ in })
        let devices: [any AgentTool] = ["screenshot", "tap", "drag", "wait", "finish"].map { DeviceTool(name: $0, coordinator: coordinator) }
        let tools = devices + [SkillTool(name: "load_skill", catalog: SkillCatalog(packages: [skill]), canRead: { true })]
        return Agent(config: AgentConfig(provider: BatchProvider(batches: batches, expectedErrors: errors), enableRepairRetry: false, tools: tools, loopDetection: nil, parallelToolCalls: false))
    }
    private func connectionRunner(_ calls: [ModelToolCall], bridge: BatchBridge, requests: BatchRequestCounter,
                                  errors: Set<String>) -> (Agent, ActionCoordinator) {
        let coordinator = ActionCoordinator(bridge: bridge, limits: AgentLimits(), approve: { _ in true },
                                            onImage: { _, _ in }, onReceipt: { _ in })
        let tools: [any AgentTool] = ["list_apps", "screenshot", "wait"].map { DeviceTool(name: $0, coordinator: coordinator) }
        let provider = BatchProvider(batches: [calls], expectedErrors: errors, requestCounter: requests)
        return (Agent(config: AgentConfig(provider: provider, enableRepairRetry: false, tools: tools,
                                         loopDetection: nil, parallelToolCalls: false)), coordinator)
    }

    func testTerminalDeviceConnectionFailureStopsBatchAndModelWithoutLosingFirstError() async throws {
        let message = "等待手机操控连接超时。synthetic connection failure"
        let bridge = BatchBridge(appQueryError: .deviceConnectionFailed(message)), requests = BatchRequestCounter()
        let calls = [call("connection", "list_apps"), call("later-screen", "screenshot"), call("later-apps", "list_apps")]
        let (agent, coordinator) = connectionRunner(calls, bridge: bridge, requests: requests, errors: ["connection"])
        var finalReplies: [String] = []
        for try await event in agent.runStreamingTagged("synthetic device task") {
            if case .turnCompleted(let text, let wasToolCallTurn) = event, !wasToolCallTurn { finalReplies.append(text) }
        }
        let events = await bridge.events, requestCount = await requests.count
        XCTAssertEqual(events, ["list_apps", "stop"], "A terminal connection error must not dispatch any following device calls")
        XCTAssertEqual(requestCount, 1, "A terminal connection error must stop before a second model request")
        XCTAssertTrue(finalReplies.isEmpty, "Tool narration is not a successful final answer")
        let results = agent.conversation.messages.flatMap { $0.toolResults ?? [] }
        XCTAssertEqual(results.map(\.toolCallId), calls.map(\.id))
        XCTAssertTrue(results.allSatisfy(\.isError))
        XCTAssertEqual(results.first?.result, message)
        XCTAssertTrue(results.dropFirst().allSatisfy { $0.result.contains("未执行") })
        let terminal = await coordinator.terminalDeviceFailureMessage
        XCTAssertEqual(terminal, message, "Skipped follow-up calls must not hide the first connection error")
        _ = await coordinator.recordFailure(AppError.unavailable("本轮已停止，此工具未执行。"))
        let retained = await coordinator.terminalDeviceFailureMessage
        XCTAssertEqual(retained, message)
    }

    func testOrdinaryUnavailableStillAllowsNextDeviceCallAndModelReply() async throws {
        let message = "synthetic temporary tool unavailable"
        let bridge = BatchBridge(appQueryError: .unavailable(message)), requests = BatchRequestCounter()
        let calls = [call("temporary", "list_apps"), call("next-screen", "screenshot")]
        let (agent, coordinator) = connectionRunner(calls, bridge: bridge, requests: requests, errors: ["temporary"])
        let answer = try await agent.run("synthetic ordinary tool failure")
        let events = await bridge.events, requestCount = await requests.count
        XCTAssertEqual(answer, "batch finished")
        XCTAssertEqual(events, ["list_apps", "screenshot"], "An ordinary unavailable error must not stop the device batch")
        XCTAssertEqual(requestCount, 2, "An ordinary error must still reach the next model response")
        let results = agent.conversation.messages.flatMap { $0.toolResults ?? [] }
        XCTAssertEqual(results.map(\.toolCallId), calls.map(\.id))
        XCTAssertEqual(results.first?.result, message)
        XCTAssertTrue(results.first?.isError == true)
        XCTAssertTrue(results.last?.isError == false)
        let terminal = await coordinator.terminalDeviceFailureMessage
        XCTAssertNil(terminal)
    }

    func testKnownSequenceKeepsPerActionApprovalWithoutIntermediateCaptures() async throws {
        let bridge = BatchBridge()
        let calls = [call("s", "screenshot"), call("t1", "tap", tap),
                     call("w", "wait", "{\"duration_ms\":1}"), call("t2", "tap", tap),
                     call("d", "drag", "{\"from_x\":10,\"from_y\":20,\"to_x\":30,\"to_y\":40,\"duration_ms\":200,\"purpose\":\"known next step\"}")]
        _ = try await runner([calls], bridge: bridge).run("synthetic")
        let events = await bridge.events
        XCTAssertEqual(events, ["screenshot", "approve", "tap", "approve", "tap", "approve", "drag"])
    }

    func testOrderedMixedBatchRepeatsObservationsAndKeepsPerActionApproval() async throws {
        let bridge = BatchBridge()
        let calls = [call("s1", "screenshot"), call("t1", "tap", tap), skillCall(), call("s2", "screenshot"), call("t2", "tap", tap)]
        let agent = runner([calls, [call("s3", "screenshot")]], bridge: bridge)
        var answer = ""
        for try await event in agent.runStreamingTagged("synthetic") {
            if case .turnCompleted(let text, let tools) = event, !tools { answer = text }
        }
        XCTAssertEqual(answer, "batch finished")
        let events = await bridge.events
        XCTAssertEqual(events, ["screenshot", "approve", "tap", "screenshot", "approve", "tap", "screenshot"])
    }
    func testUnknownInputReachesModelThenFreshObservationAllowsDifferentAction() async throws {
        let bridge = BatchBridge(failInput: true)
        let batches = [[call("s1", "screenshot"), call("t1", "tap", tap)],
                       [call("s2", "screenshot")],
                       [call("d", "drag", "{\"from_x\":10,\"from_y\":20,\"to_x\":30,\"to_y\":40,\"duration_ms\":200,\"purpose\":\"observed next step\"}"), skillCall()]]
        let result = try await runner(batches, bridge: bridge, errors: ["t1"]).run("synthetic")
        XCTAssertEqual(result, "batch finished")
        let events = await bridge.events
        XCTAssertEqual(events, ["screenshot", "approve", "tap", "screenshot", "approve", "drag"])
    }
    func testValidationErrorCanBeReportedThenFollowedByFreshObservation() async throws {
        let bridge = BatchBridge()
        let calls = [call("bad", "wait", "{\"duration_ms\":0}"), call("s", "screenshot"), call("t", "tap", tap)]
        _ = try await runner([calls], bridge: bridge, errors: ["bad"]).run("synthetic")
        let events = await bridge.events
        XCTAssertEqual(events, ["screenshot", "approve", "tap"])
    }
    func testDuplicateIDsRejectWholeBatchAndReusedIDsNeverReplay() async throws {
        for batches in [
            [[call("same", "screenshot"), call("same", "tap", tap)]],
            [[call("old", "screenshot")], [call("new", "screenshot"), call("old", "tap", tap)]]
        ] {
            let bridge = BatchBridge()
            do { _ = try await runner(batches, bridge: bridge).run("synthetic"); XCTFail("Repeated ID must fail before dispatch") }
            catch { XCTAssertTrue(error.localizedDescription.contains("ID")) }
            let events = await bridge.events
            XCTAssertEqual(events, batches.count == 1 ? [] : ["screenshot"])
        }
    }
    func testDeniedActionStopsRemainingBatchIncludingReadOnlyTools() async throws {
        let bridge = BatchBridge()
        let calls = [call("s", "screenshot"), call("deny", "tap", tap), call("later", "screenshot"), skillCall()]
        let agent = runner([calls], bridge: bridge, approval: { _ in false })
        _ = try await agent.run("synthetic")
        let events = await bridge.events
        XCTAssertEqual(events, ["screenshot", "stop"])
        let results = agent.conversation.messages.flatMap { $0.toolResults ?? [] }
        XCTAssertEqual(results.map(\.toolCallId), calls.map(\.id))
        XCTAssertTrue(results.dropFirst().allSatisfy(\.isError))
        XCTAssertTrue(results.last?.result.contains("未执行") == true)
    }
    func testCancellationDuringBatchNeverStartsFollowingTool() async throws {
        let bridge = BatchBridge(), waiting = expectation(description: "wait started")
        let agent = runner([[call("wait", "wait", "{\"duration_ms\":3000}"), call("later", "screenshot")]], bridge: bridge)
        agent.addObserver(BlockObserver { event in
            if case .toolExecutionStarted(let call) = event, call.id == "wait" { waiting.fulfill() }
        })
        let task = Task { try await agent.run("synthetic") }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel(); _ = try? await task.value
        let events = await bridge.events
        XCTAssertEqual(events, ["stop"])
        XCTAssertTrue(agent.conversation.messages.flatMap { $0.toolResults ?? [] }.contains { $0.toolCallId == "later" && $0.isError })
    }
}
