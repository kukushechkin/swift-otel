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
import ProfileRecorder
import W3CTraceContext
internal import struct NIOCore.ByteBuffer

extension RangeReplaceableCollection {
    mutating func appendAndReturnIndex(_ element: Element) -> Index {
        let index = self.endIndex
        self.append(element)
        return index
    }

    mutating func append(_ newElement: Element, capturingIndexInto idIndex: inout [AnyHashable: Index], usingKey key: any Hashable) {
        idIndex[AnyHashable(key)] = self.appendAndReturnIndex(newElement)
    }

    // TODO: making last parameter an autoclosure causes a crash
    mutating func appendIfNotPresent<Key>(indexTable: inout [Key: Index], key: Key, _ newElement: Element) -> Index {
        if let existingIndex = indexTable[key] { return existingIndex }
        let newIndex = self.endIndex
        indexTable[key] = newIndex
        self.append(newElement)
        return newIndex
    }
}

final class OTLPProfileSampleRenderer: ProfileRecorderSampleConversionOutputRenderer, @unchecked Sendable {
    var functionTable: [String: Int] = [:]
    var stringTable: [String: Int] = [:]
    var locationTable: [UInt: Int] = [:]
    var stackTable: [[UInt]: Int] = [:]

    var dictionary: Opentelemetry_Proto_Profiles_V1development_ProfilesDictionary = .init()
    var samples: [Opentelemetry_Proto_Profiles_V1development_Sample] = []

    var resultForSwiftOTel: Opentelemetry_Proto_Profiles_V1development_ProfilesData = .init()

    init() {
        seedStringTableZero()
    }

    // Required by spec: "string_table[0] MUST be \"\" and present." Must claim index 0 before any other
    // string is interned, so this runs at construction and after every `reset()`.
    private func seedStringTableZero() {
        _ = dictionary.stringTable.appendIfNotPresent(indexTable: &stringTable, key: "", "")
    }

    fileprivate func reset() {
        self.functionTable.removeAll(keepingCapacity: true)
        self.stringTable.removeAll(keepingCapacity: true)
        self.locationTable.removeAll(keepingCapacity: true)
        self.stackTable.removeAll(keepingCapacity: true)
        self.dictionary = .init()
        self.samples = .init()
        seedStringTableZero()
    }

    func consumeSingleSample(
        _ sample: Sample,
        configuration: ProfileRecorderSampleConversionConfiguration,
        symbolizer: CachedSymbolizer
    ) throws -> ByteBuffer {
        let stackSignature = sample.stack.map(\.stackPointer)
        let symbolisedStack = try sample.stack.map { frame in
            try symbolizer.symbolise(frame)
        }
        samples.append(.with { sample in
            sample.values = [1]
            sample.stackIndex = Int32(dictionary.stackTable.appendIfNotPresent(indexTable: &stackTable, key: stackSignature, .with { stack in
                for symbolizedFrame in symbolisedStack {
                    guard !symbolizedFrame.allFrames.isEmpty else { continue }
                    for frame in symbolizedFrame.allFrames {
                        // TODO: last parameter closure to avoid computing if already present
                        stack.locationIndices.append(Int32(dictionary.locationTable.appendIfNotPresent(indexTable: &locationTable, key: frame.address, .with { location in
                            location.address = UInt64(frame.address)
                            location.lines.append(.with { line in
                                line.functionIndex = Int32(dictionary.functionTable.appendIfNotPresent(indexTable: &functionTable, key: frame.functionName, .with { function in
                                    function.nameStrindex = Int32(dictionary.stringTable.appendIfNotPresent(
                                        indexTable: &stringTable,
                                        key: frame.functionName,
                                        frame.functionName
                                    ))
                                    // TODO: mangled name can go in system_name_index
                                    if let file = frame.file {
                                        function.filenameStrindex = Int32(dictionary.stringTable.appendIfNotPresent(
                                            indexTable: &stringTable,
                                            key: file,
                                            file
                                        ))
                                    }
                                    if let line = frame.line {
                                        function.startLine = Int64(line)
                                    }
                                }))
                            })
                        })))
                    }
                }
            }))
        })

        return ByteBuffer()
    }

    func finalise(
        sampleConfiguration: SampleConfig,
        configuration: ProfileRecorderSampleConversionConfiguration,
        symbolizer: CachedSymbolizer
    ) throws -> ByteBuffer {
        let samplesID = dictionary.stringTable.appendIfNotPresent(indexTable: &stringTable, key: "samples", "samples")
        let countID = dictionary.stringTable.appendIfNotPresent(indexTable: &stringTable, key: "count", "count")
        // Per spec doc comment on `period_type`: "the kind of events between sampled occurrences, e.g ['cpu','cycles']
        // or ['heap','bytes']." Pyroscope derives its profile-type `__name__` label from this string, so it must
        // match a recognized convention -- "cpuID" did not.
        let cpuID = dictionary.stringTable.appendIfNotPresent(indexTable: &stringTable, key: "cpu", "cpu")
        let nanosecondsID = dictionary.stringTable.appendIfNotPresent(indexTable: &stringTable, key: "nanoseconds", "nanoseconds")

        // The vendored proto (v1.7.0) only required a zero-value placeholder at `string_table[0]`, so this used to
        // be a Pyroscope-specific workaround for an unset `mapping_index` being dereferenced as index 0. As of
        // v1.11.0 the spec has since caught up and formalized this for every dictionary table: "The element at
        // index 0 MUST be the zero value for the dictionary's element type... This allows for _index fields
        // pointing into the dictionary to use a 0 pointer value to indicate 'null' / 'not set'." So this is no
        // longer a workaround -- it's a real spec requirement we were previously missing.
        dictionary.mappingTable.append(.init())

        let profile = Opentelemetry_Proto_Profiles_V1development_Profile.with { profile in
            profile.samples = samples

            profile.sampleType = .with {
                $0.typeStrindex = Int32(samplesID)
                $0.unitStrindex = Int32(countID)
            }
            profile.periodType = .with {
                $0.typeStrindex = Int32(cpuID)
                $0.unitStrindex = Int32(nanosecondsID)
            }
            // Must be non-zero: consumers such as Pyroscope only look at `periodType` when `period != 0`,
            // and otherwise fail to derive a profile-type name from the sample/period type strings at all.
            profile.period = Int64(sampleConfiguration.microSecondsBetweenSamples) * 1000

            profile.timeUnixNano =
                (UInt64(sampleConfiguration.currentTimeSeconds) * 1_000_000_000)
                    + UInt64(sampleConfiguration.currentTimeNanoseconds)
            profile.durationNano =
                UInt64(sampleConfiguration.sampleCount) * UInt64(sampleConfiguration.microSecondsBetweenSamples) * 1000
            // Required by spec: "all zeroes is considered invalid." TraceID is also a random 16-byte value, so
            // reuse it rather than hand-rolling another random-bytes generator.
            profile.profileID = TraceID.random().data
        }

        self.resultForSwiftOTel = .with { profilesData in
            profilesData.dictionary = dictionary
            profilesData.resourceProfiles = [
                .with { resourceProfile in
                    resourceProfile.scopeProfiles = [
                        .with { scopeProfile in
                            scopeProfile.profiles = [profile]
                        },
                    ]
                },
            ]
        }
        let output: ByteBufferWrapper = try self.resultForSwiftOTel.serializedBytes()
        self.reset()
        return output.backing
    }
}
#endif
