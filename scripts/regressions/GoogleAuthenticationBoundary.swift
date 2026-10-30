import Foundation

func authenticationRegression() async throws {
    let client = AuthenticationHarness()
    let first = Task { try await client.authenticate() }
    for _ in 0..<10_000 {
        if await client.refreshes == 1 { break }
        await Task.yield()
    }
    check(await client.refreshes == 1, "refresh did not start")
    first.cancel()
    let second = Task { try await client.authenticate() }
    for _ in 0..<10_000 {
        if await client.entrances == 2 { break }
        await Task.yield()
    }
    check(await client.entrances == 2, "second waiter did not enter")
    check(await client.refreshes == 1, "concurrent callers started duplicate refreshes")
    await client.complete()
    do { try await first.value; preconditionFailure("cancelled waiter succeeded") }
    catch is CancellationError {}
    try await second.value
    let baseline = await client.refreshes
    let third = Task { try await client.authenticate() }
    for _ in 0..<10_000 {
        if await client.refreshes > baseline { break }
        await Task.yield()
    }
    await client.complete(true)
    do { try await third.value; preconditionFailure("refresh failure swallowed") }
    catch is URLError {}
    print("PASS shared refresh cancellation and failure propagation")
}

@MainActor
func backgroundCompletionRegression() {
    var calls = 0
    BackgroundSessionCompletion.store("host-boundary") { calls += 1 }
    BackgroundSessionCompletion.store("host-boundary") { calls += 1 }
    BackgroundSessionCompletion.finish("host-boundary")
    BackgroundSessionCompletion.finish("host-boundary")
    check(calls == 2, "reentrant background handlers were lost or repeated")
}
