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
    @Test func testExportDoesNotThrow() {
        let exporter = OTelConsoleProfileExporter()
        exporter.export([.stub()], .init())
    }

    @Test func testExportOfEmptyBatchDoesNotThrow() {
        let exporter = OTelConsoleProfileExporter()
        exporter.export([], .init())
    }

    @Test func testForceFlushDoesNotThrow() {
        OTelConsoleProfileExporter().forceFlush()
    }

    @Test func testShutdownCompletes() {
        OTelConsoleProfileExporter().shutdown()
    }
}
#endif
