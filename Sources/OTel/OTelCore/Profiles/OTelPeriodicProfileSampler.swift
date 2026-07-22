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
import _ProfileRecorderSampleConversion
import AsyncAlgorithms
import Foundation
import Logging
import NIOCore
import NIOFileSystem
import ProfileRecorder
import ServiceLifecycle

struct MissingResourceProfilesError: Error, CustomStringConvertible {
    var description: String { "Profile sampler produced no resource profiles." }
}

struct OTelPeriodicProfileSampler<Clock: _Concurrency.Clock> where Clock.Duration == Duration {
    private let logger: Logger

    var resource: OTelResource
    var exporter: OTelProfileExporter
    var configuration: OTel.Configuration.ProfilesConfiguration
    var clock: Clock
    var symbolizer: any Symbolizer

    init(
        resource: OTelResource,
        exporter: OTelProfileExporter,
        configuration: OTel.Configuration.ProfilesConfiguration,
        logger: Logger,
        clock: Clock
    ) {
        self.resource = resource
        self.exporter = exporter
        self.configuration = configuration
        self.logger = logger.withMetadata(component: "OTelPeriodicExportingProfileSampler")
        self.clock = clock
        symbolizer = ProfileRecorderSampler._makeDefaultSymbolizer()
    }

    func tick() async {
        do {
            try await withTimeout(configuration.exportTimeout, clock: clock) {
                try await sampleAndExport()
            }
        } catch {
            logger.warning("Failed to sample and export profile.", error: error)
        }
    }

    private func sampleAndExport() async throws {
        let result = try await FileSystem.shared.withTemporaryDirectory {
            _,
                tmpDirPath in
            let symbolisedSamplesPath = tmpDirPath.appending("samples.otlp.pb")

            return try await ProfileRecorderSampler.sharedInstance._withSamples(
                sampleCount: 10,
                timeBetweenSamples: .milliseconds(100),
                format: .raw,
                symbolizer: symbolizer,
                logger: logger
            ) { rawSamplesPath in
                let renderer = OTLPProfileSampleRenderer()
                let converter = ProfileRecorderSampleConverter(
                    config: .default,
                    renderer: renderer,
                    symbolizer: symbolizer
                )
                try await converter.convert(
                    inputRawProfileRecorderFormatPath: rawSamplesPath,
                    outputPath: symbolisedSamplesPath.string,
                    format: .perfSymbolized,
                    logger: logger
                )
                return renderer.resultForSwiftOTel
            }
        }

        guard let scopeProfiles = result.resourceProfiles.first?.scopeProfiles.first else {
            // Always populated by `OTLPProfileSampleRenderer.finalise()` today, but this is a different type in a
            // different file, so don't let a future change to that invariant crash the whole periodic loop.
            throw MissingResourceProfilesError()
        }

        let batch = [
            Opentelemetry_Proto_Profiles_V1development_ResourceProfiles.with {
                $0.resource = .init(resource)
                $0.scopeProfiles = [.with {
                    $0.scope = .with {
                        $0.name = "swift-otel"
                        $0.version = OTelLibrary.version
                        $0.attributes = []
                        $0.droppedAttributesCount = 0
                    }
                    $0.profiles = scopeProfiles.profiles
                }]
            },
        ]
        try await exporter.export(batch, result.dictionary)
    }
}

extension OTelPeriodicProfileSampler: Service {
    func run() async throws {
        let interval = configuration.exportInterval
        logger.debug("Started periodic loop.", metadata: ["interval": "\(interval)"])
        for try await _ in AsyncTimerSequence.repeating(every: interval, clock: clock).cancelOnGracefulShutdown() {
            logger.trace("Timer fired.", metadata: ["interval": "\(interval)"])
            await tick()
        }
        logger.debug("Shutting down.")
        // Unlike traces, force-flush is just a regular tick for metrics; no need for a different function.
        await tick()
        try await exporter.forceFlush()
        await exporter.shutdown()
        logger.debug("Shut down.")
    }
}

extension OTelPeriodicProfileSampler where Clock == ContinuousClock {
    init(
        resource: OTelResource,
        exporter: OTelProfileExporter,
        configuration: OTel.Configuration.ProfilesConfiguration,
        logger: Logger
    ) {
        self.init(
            resource: resource,
            exporter: exporter,
            configuration: configuration,
            logger: logger.withMetadata(component: "OTelPeriodicProfileSampler"),
            clock: .continuous
        )
    }
}
#endif
