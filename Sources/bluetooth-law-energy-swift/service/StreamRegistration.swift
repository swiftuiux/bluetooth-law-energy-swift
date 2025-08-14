//
//  RegistrationStream.swift
//
//  Manages Bluetooth Low Energy (BLE) peripheral discovery stream.
//
//  Created by Igor on 22.07.24.
//

import Combine
import CoreBluetooth

extension BluetoothLEManager {
    
    /// An actor responsible for the registration and streaming of discovered Bluetooth peripherals.
    actor StreamRegistration {
        
        /// A dictionary to keep track of subscribers using their UUIDs.
        private var subscribers: [UUID: PeripheralsContinuation] = [:]
        
        /// A subject to broadcast changes in the subscriber count.
        private let subscriberCountSubject = PassthroughSubject<Int, Never>()
        
        /// A list to store the discovered peripherals (actor-isolated).
        private var discoveredPeripherals: [CBPeripheral] = []
        
        /// A type alias for an asynchronous stream continuation specific to an array of CBPeripheral.
        public typealias PeripheralsContinuation = AsyncStream<[CBPeripheral]>.Continuation
        
        /// A publisher to provide external updates on the subscriber count changes.
        public var subscriberCountPublisher: AnyPublisher<Int, Never> {
            subscriberCountSubject.eraseToAnyPublisher()
        }
        
        /// Current number of subscribers.
        public var count: Int { subscribers.count }
        
        /// Provides an asynchronous stream of arrays of discovered peripherals.
        public var stream: AsyncStream<[CBPeripheral]> {
            get async {
                createPeripheralStream()
            }
        }
        
        private let logger: ILogger
        
        /// Initializes the StreamRegistration with a logger.
        init(logger: ILogger) {
            self.logger = logger
        }
        
        deinit {
            subscribers.forEach { (_, continuation) in
                continuation.finish()
            }
            discoveredPeripherals = []
            
            #if DEBUG
            print("Peripherals released")
            #endif
        }
        
        /// Registers a new subscriber and immediately provides the current list of peripherals.
        /// - Parameter continuation: The `PeripheralsContinuation` to handle the discovered peripherals.
        public func register(_ continuation: PeripheralsContinuation) -> UUID {
            let id = UUID()
            subscribers[id] = continuation
            let current = discoveredPeripherals
            continuation.yield(current)
            subscriberCountSubject.send(count)
            return id
        }
        
        /// Unregisters a subscriber and updates the subscriber count.
        /// - Parameter id: The UUID of the subscriber to unregister.
        public func unregister(with id: UUID) {
            subscribers.removeValue(forKey: id)
            subscriberCountSubject.send(count)
        }
        
        /// Notifies all subscribers with the updated list of discovered peripherals.
        /// - Parameter peripherals: The updated list of discovered `CBPeripheral` instances.
        public func notifySubscribers(_ peripherals: [CBPeripheral]) {
            discoveredPeripherals = peripherals
            for continuation in subscribers.values {
                continuation.yield(peripherals)
            }
        }
        
        /// Creates and returns an `AsyncStream` of peripherals, managing the lifecycle events.
        /// - Returns: An `AsyncStream` of `[CBPeripheral]` to provide peripheral data.
        private func createPeripheralStream() -> AsyncStream<[CBPeripheral]>  {
            let (newStream, newContinuation) = AsyncStream<[CBPeripheral]>.makeStream(of: [CBPeripheral].self)
            
            let id = register(newContinuation)

            newContinuation.onTermination = { [weak self] _ in
                Task {
                    guard let self = self else { return }
                    await self.unregister(with: id)
                }
            }
            
            return newStream
        }
    }
}
