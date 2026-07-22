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
#if canImport(FoundationEssentials)
import struct FoundationEssentials.Data
#else
import struct Foundation.Data
#endif
import _ProfileRecorderSampleConversion
import Logging
import NIOCore
import NIOPosix
@testable import OTel
import ProfileRecorder
import Testing

@Suite struct OTLPProfileSampleRendererTests {
    static func makeSymbolizer(functionNames: [UInt: String]) -> CachedSymbolizer {
        struct StubSymbolizer: Symbolizer {
            var functionNames: [UInt: String]
            var description: String { "StubSymbolizer" }
            func start() throws {}
            func shutdown() throws {}
            func symbolise(fileVirtualAddressIP: UInt, library: DynamicLibMapping, logger: Logging.Logger) throws -> SymbolisedStackFrame {
                .init(allFrames: [.init(
                    address: fileVirtualAddressIP,
                    functionName: functionNames[fileVirtualAddressIP] ?? "unknown",
                    functionOffset: 0,
                    library: library.path,
                    vmap: library
                )])
            }
        }
        return CachedSymbolizer(
            configuration: .default,
            symbolizer: StubSymbolizer(functionNames: functionNames),
            dynamicLibraryMappings: [
                DynamicLibMapping(
                    path: "/fake/binary",
                    architecture: "arm64",
                    segmentSlide: 0,
                    segmentStartAddress: 0,
                    segmentEndAddress: .max
                ),
            ],
            group: MultiThreadedEventLoopGroup.singleton,
            logger: ._otelDisabled
        )
    }

    static func stubSample(instructionPointers: [UInt]) -> Sample {
        Sample(
            sampleHeader: SampleHeader(pid: 1, tid: 1, name: "test-thread", timeSec: 0, timeNSec: 0),
            stack: instructionPointers.map { StackFrame(instructionPointer: $0, stackPointer: $0) }
        )
    }

    @Test func testFinaliseSetsARequiredNonZeroProfileID() throws {
        let renderer = OTLPProfileSampleRenderer()
        let symbolizer = Self.makeSymbolizer(functionNames: [1: "doWork"])
        _ = try renderer.consumeSingleSample(Self.stubSample(instructionPointers: [1]), configuration: .default, symbolizer: symbolizer)
        let bytes = try renderer.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 0, sampleCount: 1),
            configuration: .default,
            symbolizer: symbolizer
        )
        let profilesData = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes))
        let profile = try #require(profilesData.resourceProfiles.first?.scopeProfiles.first?.profiles.first)
        #expect(profile.profileID.count == 16)
        #expect(profile.profileID != Data(repeating: 0, count: 16))
    }

    @Test func testFinaliseGeneratesADifferentProfileIDEachTime() throws {
        let symbolizer = Self.makeSymbolizer(functionNames: [1: "doWork"])

        let renderer1 = OTLPProfileSampleRenderer()
        _ = try renderer1.consumeSingleSample(Self.stubSample(instructionPointers: [1]), configuration: .default, symbolizer: symbolizer)
        let bytes1 = try renderer1.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 0, sampleCount: 1),
            configuration: .default,
            symbolizer: symbolizer
        )

        let renderer2 = OTLPProfileSampleRenderer()
        _ = try renderer2.consumeSingleSample(Self.stubSample(instructionPointers: [1]), configuration: .default, symbolizer: symbolizer)
        let bytes2 = try renderer2.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 0, sampleCount: 1),
            configuration: .default,
            symbolizer: symbolizer
        )

        let profile1 = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes1)).resourceProfiles[0].scopeProfiles[0].profiles[0]
        let profile2 = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes2)).resourceProfiles[0].scopeProfiles[0].profiles[0]
        #expect(profile1.profileID != profile2.profileID)
    }

    @Test func testFinaliseAlwaysPopulatesAtLeastOneMappingTableEntry() throws {
        // Per spec, "the element at index 0 MUST be the zero value for the dictionary's element type" for every
        // dictionary table, not just `string_table`.
        let renderer = OTLPProfileSampleRenderer()
        let symbolizer = Self.makeSymbolizer(functionNames: [1: "doWork"])
        _ = try renderer.consumeSingleSample(Self.stubSample(instructionPointers: [1]), configuration: .default, symbolizer: symbolizer)
        let bytes = try renderer.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 0, sampleCount: 1),
            configuration: .default,
            symbolizer: symbolizer
        )
        let profilesData = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes))
        #expect(!profilesData.dictionary.mappingTable.isEmpty)
    }

    @Test func testFinaliseAlwaysPopulatesStringTableZeroWithAnEmptyString() throws {
        // Per spec: "string_table[0] MUST be \"\" and present." Regression test: this used to be whatever
        // function name happened to be interned first, since nothing claimed index 0 up front.
        let renderer = OTLPProfileSampleRenderer()
        let symbolizer = Self.makeSymbolizer(functionNames: [1: "doWork"])
        _ = try renderer.consumeSingleSample(Self.stubSample(instructionPointers: [1]), configuration: .default, symbolizer: symbolizer)
        let bytes = try renderer.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 0, sampleCount: 1),
            configuration: .default,
            symbolizer: symbolizer
        )
        let profilesData = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes))
        #expect(profilesData.dictionary.stringTable.first == "")
    }

    @Test func testFinaliseComputesDurationFromSampleCountAndInterval() throws {
        let renderer = OTLPProfileSampleRenderer()
        let symbolizer = Self.makeSymbolizer(functionNames: [1: "doWork"])
        _ = try renderer.consumeSingleSample(Self.stubSample(instructionPointers: [1]), configuration: .default, symbolizer: symbolizer)
        let bytes = try renderer.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 100, currentTimeNanoseconds: 5, microSecondsBetweenSamples: 100_000, sampleCount: 10),
            configuration: .default,
            symbolizer: symbolizer
        )
        let profilesData = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes))
        let profile = try #require(profilesData.resourceProfiles.first?.scopeProfiles.first?.profiles.first)
        #expect(profile.timeUnixNano == 100_000_000_005)
        // 10 samples * 100_000 microseconds/sample * 1000 nanoseconds/microsecond.
        #expect(profile.durationNano == 1_000_000_000)
    }

    @Test func testFinaliseSetsANonZeroPeriodMatchingThePeriodTypeUnit() throws {
        // Consumers such as Pyroscope only look at `periodType` when deriving a profile-type name if
        // `period != 0`; leaving it at the default zero silently drops the period type from that derivation.
        let renderer = OTLPProfileSampleRenderer()
        let symbolizer = Self.makeSymbolizer(functionNames: [1: "doWork"])
        _ = try renderer.consumeSingleSample(Self.stubSample(instructionPointers: [1]), configuration: .default, symbolizer: symbolizer)
        let bytes = try renderer.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 100_000, sampleCount: 1),
            configuration: .default,
            symbolizer: symbolizer
        )
        let profilesData = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes))
        let profile = try #require(profilesData.resourceProfiles.first?.scopeProfiles.first?.profiles.first)
        // periodType's unit is "nanoseconds", so period must be expressed in nanoseconds too.
        #expect(profile.period == 100_000_000)
    }

    @Test func testConsumeSingleSampleInternsRepeatedFunctionNamesToTheSameIndex() throws {
        let renderer = OTLPProfileSampleRenderer()
        let symbolizer = Self.makeSymbolizer(functionNames: [1: "doWork", 2: "doOtherWork"])
        _ = try renderer.consumeSingleSample(Self.stubSample(instructionPointers: [1, 2]), configuration: .default, symbolizer: symbolizer)
        _ = try renderer.consumeSingleSample(Self.stubSample(instructionPointers: [1, 2]), configuration: .default, symbolizer: symbolizer)
        let bytes = try renderer.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 0, sampleCount: 2),
            configuration: .default,
            symbolizer: symbolizer
        )
        let profilesData = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes))
        let profile = try #require(profilesData.resourceProfiles.first?.scopeProfiles.first?.profiles.first)
        #expect(profile.samples.count == 2)
        // Two identical stacks should intern to the same stack table entry, not duplicate it.
        #expect(profile.samples[0].stackIndex == profile.samples[1].stackIndex)
        #expect(profilesData.dictionary.stackTable.count == 1)
        #expect(profilesData.dictionary.functionTable.count == 2)
    }

    @Test func testFinaliseResetsStateForTheNextTick() throws {
        let renderer = OTLPProfileSampleRenderer()
        let symbolizer = Self.makeSymbolizer(functionNames: [1: "doWork"])
        _ = try renderer.consumeSingleSample(Self.stubSample(instructionPointers: [1]), configuration: .default, symbolizer: symbolizer)
        _ = try renderer.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 0, sampleCount: 1),
            configuration: .default,
            symbolizer: symbolizer
        )

        // A tick with zero samples should produce an empty (but still valid) profile, not carry over state.
        let bytes = try renderer.finalise(
            sampleConfiguration: .init(currentTimeSeconds: 0, currentTimeNanoseconds: 0, microSecondsBetweenSamples: 0, sampleCount: 0),
            configuration: .default,
            symbolizer: symbolizer
        )
        let profilesData = try Opentelemetry_Proto_Profiles_V1development_ProfilesData(serializedBytes: ByteBufferWrapper(backing: bytes))
        let profile = try #require(profilesData.resourceProfiles.first?.scopeProfiles.first?.profiles.first)
        #expect(profile.samples.isEmpty)
    }
}
#endif
