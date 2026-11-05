import Foundation
import Testing

@testable import MCP

@Suite("Client incoming request tests")
struct ClientIncomingRequestTests {
    private static let schema = Elicitation.RequestSchema(
        properties: ["confirm": ["type": "boolean"]]
    )

    @Test("The client reads other messages while a request handler waits")
    func testClientReadsWhileHandlerWaits() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "TestServer", version: "1.0")
        let client = Client(
            name: "TestClient", version: "1.0", capabilities: .init(elicitation: .init()))

        let handlerStarted = Signal()
        let answer = Signal()
        await client.withElicitationHandler { _ in
            await handlerStarted.fire()
            await answer.wait()
            return CreateElicitation.Result(action: .accept, content: ["confirm": true])
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let elicitation = Task {
            try await server.requestElicitation(message: "Confirm?", requestedSchema: Self.schema)
        }
        await handlerStarted.wait()

        // The handler still waits. The response to the ping must arrive.
        try await withTimeout(.seconds(5)) {
            try await client.ping()
        }

        await answer.fire()
        let result = try await withTimeout(.seconds(5)) {
            try await elicitation.value
        }
        #expect(result.action == .accept)

        await server.stop()
        await client.disconnect()
    }

    @Test("Disconnect cancels a waiting request handler")
    func testDisconnectCancelsWaitingHandler() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(name: "TestServer", version: "1.0")
        let client = Client(
            name: "TestClient", version: "1.0", capabilities: .init(elicitation: .init()))

        let handlerStarted = Signal()
        let handlerCancelled = Signal()
        await client.withElicitationHandler { _ in
            await handlerStarted.fire()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                await handlerCancelled.fire()
            }
            return CreateElicitation.Result(action: .cancel)
        }

        try await server.start(transport: serverTransport)
        try await client.connect(transport: clientTransport)

        let elicitation = Task {
            try? await server.requestElicitation(message: "Confirm?", requestedSchema: Self.schema)
        }
        await handlerStarted.wait()

        try await withTimeout(.seconds(5)) {
            await client.disconnect()
            await handlerCancelled.wait()
        }

        elicitation.cancel()
        await server.stop()
    }

    @Test("A cancel notification from the server cancels the handler and sends no response")
    func testServerCancelNotificationCancelsHandler() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "TestClient", version: "1.0", capabilities: .init(elicitation: .init()))

        let handlerStarted = Signal()
        let handlerCancelled = Signal()
        await client.withElicitationHandler { _ in
            await handlerStarted.fire()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                await handlerCancelled.fire()
                throw error
            }
            return CreateElicitation.Result(action: .accept)
        }
        try await connect(client, to: transport)

        await transport.queue(data: elicitationRequest(id: "e1"))
        await handlerStarted.wait()
        await transport.queue(data: cancelNotification(id: "e1"))

        try await withTimeout(.seconds(5)) {
            await handlerCancelled.wait()
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await responses(to: "e1", in: transport).isEmpty)

        await client.disconnect()
    }

    @Test("A duplicate request ID is ignored and the first handler stays tracked")
    func testDuplicateRequestID() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "TestClient", version: "1.0", capabilities: .init(elicitation: .init()))

        let calls = Counter()
        let handlerStarted = Signal()
        let handlerCancelled = Signal()
        await client.withElicitationHandler { _ in
            await calls.increment()
            await handlerStarted.fire()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                await handlerCancelled.fire()
            }
            return CreateElicitation.Result(action: .cancel)
        }
        try await connect(client, to: transport)

        await transport.queue(data: elicitationRequest(id: "d1"))
        await handlerStarted.wait()
        await transport.queue(data: elicitationRequest(id: "d1"))

        // Wait until the client reads the duplicate. The client reads in order, so an answer
        // to a later ping shows that it read the duplicate first. The client has no ping
        // handler, so the answer is a methodNotFound error.
        try await withTimeout(.seconds(5)) {
            await transport.queue(data: pingRequest(id: "p1"))
            while await responses(to: "p1", in: transport).isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(await responses(to: "d1", in: transport).isEmpty)
        #expect(await calls.value == 1)

        // Disconnect cancels the first handler, so the duplicate did not replace its entry.
        try await withTimeout(.seconds(5)) {
            await client.disconnect()
            await handlerCancelled.wait()
        }
    }

    @Test("A handler that throws a cancellation error itself gets an error response")
    func testHandlerCancellationErrorGetsResponse() async throws {
        let transport = MockTransport()
        let client = Client(
            name: "TestClient", version: "1.0", capabilities: .init(elicitation: .init()))
        await client.withElicitationHandler { _ in
            throw CancellationError()
        }
        try await connect(client, to: transport)

        await transport.queue(data: elicitationRequest(id: "x1"))

        let found = try await withTimeout(.seconds(5)) {
            while true {
                let found = await responses(to: "x1", in: transport)
                if !found.isEmpty { return found }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(found.count == 1)
        #expect(found.first?.contains("\"error\"") == true)

        await client.disconnect()
    }

    @Test("A handler that ends after a reconnect does not untrack a new handler with the same ID")
    func testOldHandlerDoesNotUntrackNewHandler() async throws {
        let client = Client(
            name: "TestClient", version: "1.0", capabilities: .init(elicitation: .init()))

        let calls = Counter()
        let firstStarted = Signal()
        let releaseFirst = Signal()
        let firstFinished = Signal()
        let secondStarted = Signal()
        let secondCancelled = Signal()
        await client.withElicitationHandler { _ in
            if await calls.increment() == 1 {
                // The first handler does not react to cancellation.
                await firstStarted.fire()
                await releaseFirst.wait()
                await firstFinished.fire()
            } else {
                await secondStarted.fire()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    await secondCancelled.fire()
                }
            }
            return CreateElicitation.Result(action: .cancel)
        }

        let firstTransport = MockTransport()
        try await connect(client, to: firstTransport)
        await firstTransport.queue(data: elicitationRequest(id: "r1"))
        await firstStarted.wait()
        await client.disconnect()

        let secondTransport = MockTransport()
        try await connect(client, to: secondTransport)
        await secondTransport.queue(data: elicitationRequest(id: "r1"))
        await secondStarted.wait()

        // The first handler ends now. It must not remove the entry of the second handler.
        await releaseFirst.fire()
        await firstFinished.wait()
        // After the handler returns, its task only hops back to the client and removes its entry.
        // No signal follows that step, so wait a short time. If the step is slower, the test
        // passes without proof; it cannot fail falsely.
        try await Task.sleep(for: .milliseconds(50))

        try await withTimeout(.seconds(5)) {
            await client.disconnect()
            await secondCancelled.wait()
        }
        #expect(await responses(to: "r1", in: secondTransport).isEmpty)
    }
}

// MARK: - Helpers

/// Connects the client and answers its initialize request.
private func connect(_ client: Client, to transport: MockTransport) async throws {
    let answer = Task {
        while true {
            for message in await transport.sentMessages {
                if let data = message.data(using: .utf8),
                    let request = try? JSONDecoder().decode(Request<Initialize>.self, from: data)
                {
                    let response = Initialize.response(
                        id: request.id,
                        result: .init(
                            protocolVersion: Version.latest,
                            capabilities: .init(),
                            serverInfo: .init(name: "TestServer", version: "1.0"),
                            instructions: nil
                        )
                    )
                    try await transport.queue(response: response)
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    try await client.connect(transport: transport)
    try await answer.value
}

private func elicitationRequest(id: String) -> Data {
    Data(
        """
        {"jsonrpc":"2.0","id":"\(id)","method":"elicitation/create",\
        "params":{"message":"Confirm?","requestedSchema":{"type":"object","properties":{}}}}
        """.utf8)
}

private func pingRequest(id: String) -> Data {
    Data(#"{"jsonrpc":"2.0","id":"\#(id)","method":"ping"}"#.utf8)
}

private func cancelNotification(id: String) -> Data {
    Data(
        """
        {"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"\(id)"}}
        """.utf8)
}

/// The messages that the client sent as responses to the request with this ID.
private func responses(to id: String, in transport: MockTransport) async -> [String] {
    await transport.sentMessages.filter {
        $0.contains("\"id\":\"\(id)\"") && !$0.contains("\"method\"")
    }
}

private actor Counter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

/// A one-shot signal that tasks can wait for.
private actor Signal {
    private var isFired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        isFired = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if isFired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct TimeoutError: Error {}

/// Runs the operation and throws `TimeoutError` if it does not finish in time.
/// The operation is not awaited after the timeout, so a stuck operation cannot stop the test.
private func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = Outcome<T>()
    let work = Task { await outcome.set(await Result(catching: operation)) }
    let timer = Task {
        try? await Task.sleep(for: duration)
        await outcome.set(.failure(TimeoutError()))
    }
    let result = await outcome.value()
    work.cancel()
    timer.cancel()
    return try result.get()
}

/// The first result that arrives. Later results are ignored.
private actor Outcome<T: Sendable> {
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<Result<T, Error>, Never>?

    func set(_ newResult: Result<T, Error>) {
        guard result == nil else { return }
        result = newResult
        waiter?.resume(returning: newResult)
        waiter = nil
    }

    func value() async -> Result<T, Error> {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}

extension Result where Failure == Error {
    fileprivate init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
