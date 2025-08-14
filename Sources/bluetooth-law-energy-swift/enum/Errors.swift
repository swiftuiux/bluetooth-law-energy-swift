//
//  Errors.swift
//
//
//  Created by Igor on 15.07.24.
//

import CoreBluetooth

public extension BluetoothLEManager {
    
    /// Errors enum represents possible errors within Bluetooth operations, conforming to Error and LocalizedError protocols.
    enum Errors: Error, LocalizedError {
        
        /// Error encountered while discovering services.
        case discoveringServices(String, Error?)
        
        /// Error encountered while discovering characteristics.
        case discoveringCharacteristics(String, Error?)
        
        /// Error encountered while connecting.
        case connection(CBPeripheral, Error?)
        
        /// Error when peripheral is already connected.
        case connected(CBPeripheral)
        
        /// Error when peripheral is not connected.
        case notConnected(String)
        
        /// Error when peripheral is currently connecting.
        case connecting(String)
        
        /// Error when an operation times out.
        case timeout
        
        /// Error when an operation times out.
        case timeoutServices
        
        case noServices(String)

        /// Error encountered while disconnecting.
        case disconnection(CBPeripheral, Error?)
        
        /// Text description
        public var errorDescription: String? {
            switch self {
            case .noServices(let name):
                return NSLocalizedString("No services found for \(name).", comment: "No Services Error")
            case .discoveringServices(let message, let error):
                if let error = error {
                    return NSLocalizedString("Error discovering services for \(message): \(error.localizedDescription)", comment: "Discovering Services Error")
                } else {
                    return NSLocalizedString("Error discovering services for \(message)", comment: "Discovering Services Error")
                }
            case .discoveringCharacteristics(let message, let error):
                if let error = error {
                    return NSLocalizedString("Error discovering characteristics for \(message): \(error.localizedDescription)", comment: "Discovering Characteristics Error")
                } else {
                    return NSLocalizedString("Error discovering characteristics for \(message)", comment: "Discovering Characteristics Error")
                }
            case .connection(let peripheral, let error):
                return NSLocalizedString("Error connecting to \(peripheral.name ?? "unknown peripheral"): \(error?.localizedDescription ?? "unknown error")", comment: "Connection Error")
            case .connected(let peripheral):
                return NSLocalizedString("The peripheral \(peripheral.name ?? "unknown peripheral") is already connected. Please disconnect and try again.", comment: "Already Connected Error")
            case .notConnected(let name):
                return NSLocalizedString("The peripheral \(name) is not connected. Please connect first.", comment: "Not Connected Error")
            case .connecting(let name):
                return NSLocalizedString("The peripheral \(name) is currently connecting. Please wait until the connection is complete.", comment: "Connecting Error")
            case .timeout:
                return NSLocalizedString("Connecting operation timed out for peripheral.", comment: "Timeout Error")
            case .timeoutServices:
                return NSLocalizedString("Discovering operation timed out for peripheral.", comment: "Timeout Error")
            case .disconnection(let peripheral, let error):
                return NSLocalizedString("Error disconnecting from \(peripheral.name ?? "unknown peripheral"): \(error?.localizedDescription ?? "unknown error")", comment: "Disconnection Error")
            }
        }
    }
}
