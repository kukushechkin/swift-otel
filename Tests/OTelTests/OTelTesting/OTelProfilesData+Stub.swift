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

extension Opentelemetry_Proto_Profiles_V1development_ResourceProfiles {
    /// A resource profiles stub containing a single, empty profile.
    static func stub() -> Self {
        .with { resourceProfile in
            resourceProfile.scopeProfiles = [
                .with { scopeProfile in
                    scopeProfile.profiles = [.init()]
                },
            ]
        }
    }
}
#endif
