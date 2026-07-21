//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OTel open source project
//
// Copyright (c) 2025 the Swift OTel project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Hummingbird
import OTel

@main
enum HelloWorldHummingbirdServer {
    static func main() async throws {
        // Bootstrap observability backends (with short export intervals for demo purposes).
        var config = OTel.Configuration.default
        config.serviceName = "hello_world"
        config.diagnosticLogLevel = .error
        config.logs.batchLogRecordProcessor.scheduleDelay = .seconds(3)
        config.metrics.exportInterval = .seconds(3)
        config.traces.batchSpanProcessor.scheduleDelay = .seconds(3)
        config.profiles.enabled = true
        config.profiles.exportInterval = .seconds(3)
        let observability = try OTel.bootstrap(configuration: config)

        // Create an HTTP server with instrumentation middlewares added.
        let router = Router()
        router.middlewares.add(TracingMiddleware())
        router.middlewares.add(MetricsMiddleware())
        router.middlewares.add(LogRequestsMiddleware(.info))
        router.get("hello") { _, _ in "hello" }
        router.get("burn") { _, _ in
            // A deliberately expensive, clearly-named call path so it's easy to spot in a profiler flame graph.
            simulateExpensiveWork()
            return "burned"
        }
        var app = Application(router: router)

        // Add the observability service to the Hummingbird service group and run the server.
        app.addServices(observability)
        try await app.runService()
    }

    static func simulateExpensiveWork() {
        crunchFibonacciNumbers()
    }

    static func crunchFibonacciNumbers() {
        // Run for longer than the profiling export interval, so a periodic sample is very likely to land while
        // this is still on the stack, regardless of how fast `naiveFibonacci` runs on a given machine.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var total = 0
        var n = 20
        while ContinuousClock.now < deadline {
            total += naiveFibonacci(n)
            n = n == 20 ? 30 : 20
        }
        // Prevent the optimizer from eliminating the "unused" result.
        precondition(total >= 0)
    }

    static func naiveFibonacci(_ n: Int) -> Int {
        n < 2 ? n : naiveFibonacci(n - 1) + naiveFibonacci(n - 2)
    }
}
