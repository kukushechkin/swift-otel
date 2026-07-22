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

@Suite struct WrappedProfileExporterTests {
    #if OTLPHTTP
    @Test func testSelectionForOTLPHTTPExporter() throws {
        var config = OTel.Configuration.default
        config.profiles.exporter = .otlp
        config.profiles.otlpExporter.protocol = .httpProtobuf
        let exporter = try WrappedProfileExporter(configuration: config, logger: ._otelDisabled)
        guard case .http = exporter else {
            Issue.record("OTLP/HTTP protocol should select the .http case, but selected: \(exporter)")
            return
        }
    }
    #endif

    @Test func testSelectionForConsoleExporter() throws {
        var config = OTel.Configuration.default
        config.profiles.exporter = .console
        let exporter = try WrappedProfileExporter(configuration: config, logger: ._otelDisabled)
        guard case .console = exporter else {
            Issue.record("Console exporter should select the .console case, but selected: \(exporter)")
            return
        }
    }

    @Test func testSelectionForNoneExporter() throws {
        var config = OTel.Configuration.default
        config.profiles.exporter = .none
        let exporter = try WrappedProfileExporter(configuration: config, logger: ._otelDisabled)
        guard case .none = exporter else {
            Issue.record("None exporter should select the .none case, but selected: \(exporter)")
            return
        }
    }

    #if OTLPGRPC
    @available(gRPCSwift, *)
    @Test func testSelectionForOTLPGRPCExporterThrowsRatherThanCrashing() throws {
        // gRPC export isn't implemented for profiles yet -- this must be a catchable error, not a fatalError, since
        // it's reachable from ordinary user configuration.
        var config = OTel.Configuration.default
        config.profiles.exporter = .otlp
        config.profiles.otlpExporter.protocol = .grpc
        #expect(throws: NotImplementedError.self) {
            _ = try WrappedProfileExporter(configuration: config, logger: ._otelDisabled)
        }
    }
    #endif
}
#endif
