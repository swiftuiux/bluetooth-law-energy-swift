//
//  Task+.swift
//
//
//  Created by Igor  on 18.07.24.
//

import Foundation


/// Extends Task to provide a sleep function when used in an async context.
@available(iOS 15, *)
@available(macOS 12, *)
@available(watchOS 8, *)
@available(tvOS 15, *)
extension Task where Success == Never, Failure == Never {

    @available(iOS, deprecated: 16.0, message: "Use Task.sleep(for: .seconds(_)) on iOS 16+")
    @available(macOS, deprecated: 13.0, message: "Use Task.sleep(for: .seconds(_)) on macOS 13+")
    @available(watchOS, deprecated: 9.0, message: "Use Task.sleep(for: .seconds(_)) on watchOS 9+")
    @available(tvOS, deprecated: 16.0, message: "Use Task.sleep(for: .seconds(_)) on tvOS 16+")
    static func sleep(for seconds: Double) async throws {
        // Не зовём новый API, чтобы не пересекаться по имени.
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
