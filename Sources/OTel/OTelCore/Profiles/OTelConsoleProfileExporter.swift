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

#if !Profiling
// Empty when above trait(s) are disabled.
#else
import ServiceLifecycle

struct OTelConsoleProfileExporter: OTelProfileExporter {
    func run() async throws {
        // No background work needed, but we'll keep the run method running until its cancelled.
        try await gracefulShutdown()
    }

    func export(_ batch: some Collection<Opentelemetry_Proto_Profiles_V1development_ResourceProfiles> & Sendable, _ dictionary: Opentelemetry_Proto_Profiles_V1development_ProfilesDictionary) {
        for profile in batch {
            try? print(profile.jsonString())
        }
    }

    func forceFlush() {}
    func shutdown() {}
}
#endif
