//
//  CachedServices.swift
//
//
//  Created by Igor  on 19.07.24.
//

import CoreBluetooth

extension BluetoothLEManager {
    
    /// CacheServices is an actor designed to safely manage concurrent access to a cache of Bluetooth services.
    /// It stores services associated with peripherals identified by UUIDs.
    @MainActor
    final class CacheServices {
        
        /// Private dictionary to hold the cached services with peripheral UUID as the key.

        private var data: [UUID: [CBService]] = [:]
        
        deinit{
            data = [:]
        }
        
        // MARK: - API
        
        /// Adds or updates a list of `CBService` objects for a given UUID.
        /// - Parameters:
        ///   - key: The UUID of the peripheral whose services are being cached.
        ///   - services: An array of `CBService` objects to cache.
        public func add(key: UUID, services: [CBService]) {
            data[key] = services
        }
        
        /// Removes cached services for a specific UUID.
        /// - Parameter key: The UUID of the peripheral whose services are to be removed from the cache.
        public func remove(key: UUID) {
            data.removeValue(forKey: key)
        }
        
        /// Clears all cached services from the dictionary.
        public func removeAll() {
            data = [:]
        }
        
        /// Fetches the cached services for a specific peripheral.
        /// - Parameter peripheral: The `CBPeripheral` whose services are to be fetched.
        /// - Returns: An optional array of `CBService`, if services are found for the UUID; otherwise, nil.
        public func fetch(for peripheral: CBPeripheral) -> [CBService]? {
            let key = peripheral.getId
            return data[key]
        }
    }
}
