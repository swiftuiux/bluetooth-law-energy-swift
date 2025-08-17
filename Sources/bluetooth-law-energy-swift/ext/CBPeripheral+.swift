//
//  CBPeripheral+.swift
//
//
//  Created by Igor  on 19.07.24.
//

import CoreBluetooth
import Foundation

/// Extension of CBPeripheral to include computed properties related to the connection state and identity of Bluetooth peripherals.
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, *)
extension CBPeripheral {
    
    // MARK: - Computed Properties
    
    /// Checks if the peripheral is connected.
    public var isConnected: Bool {
        self.state == .connected
    }
    
    /// Checks if the peripheral is not connected.
    public var isNotConnected: Bool {
        self.state != .connected
    }
    
    /// Retrieves the identifier of the peripheral.
    public var getId: UUID {
        return self.identifier
    }
    
    /// Retrieves the name of the peripheral. If the name is nil, returns "unknown".
    public var getName: String {
        name ?? "unknown"
    }
}
