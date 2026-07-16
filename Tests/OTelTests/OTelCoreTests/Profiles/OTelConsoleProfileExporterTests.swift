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
@testable import OTel
import Testing

@Suite struct OTelConsoleProfileExporterTests {
    @Test func testExportDoesNotThrow() async throws {
        let exporter = OTelConsoleProfileExporter()
        try await exporter.export([.stub()], .init())
    }

    @Test func testExportOfEmptyBatchDoesNotThrow() async throws {
        let exporter = OTelConsoleProfileExporter()
        try await exporter.export([], .init())
    }

    @Test func testForceFlushDoesNotThrow() async throws {
        try await OTelConsoleProfileExporter().forceFlush()
    }

    @Test func testShutdownCompletes() async {
        await OTelConsoleProfileExporter().shutdown()
    }
}
#endif
