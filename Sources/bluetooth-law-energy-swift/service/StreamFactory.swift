//
//  StreamFactory.swift
//
//  Manages the creation and handling of streams for Bluetooth peripheral data.
//
//  Created by Igor on 12.07.24.
//

import Combine
import CoreBluetooth

extension BluetoothLEManager {
    
    /// `StreamFactory` is responsible for creating and managing streams related to Bluetooth peripherals.
    /// It facilitates the connection and communication with Bluetooth devices using CoreBluetooth.
    final class StreamFactory {
        
        /// Publisher to expose the number of subscribers to stream events.
        /// It uses a Combine publisher to provide reactive updates whenever the subscriber count changes.
        public var subscriberCountPublisher: AnyPublisher<Int, Never> {
            subscriberCountSubject
                .eraseToAnyPublisher()
        }
        
        /// Subject to manage and broadcast changes in the subscriber count internally.
        /// This allows for dynamic updates across components that observe these counts.
        private let subscriberCountSubject = PassthroughSubject<Int, Never>()
        
        /// Internal service that handles the registration and notification of Bluetooth peripherals.
        /// This service centralizes the logic for managing connected peripherals.
        private let service: StreamRegistration
        
        /// Set to hold any Combine cancellables to manage memory and avoid leaks.
        /// Ensures that subscriptions are cancelled when they are no longer needed.
        private var cancellables = Set<AnyCancellable>()
        
        /// A logger instance for recording debugging information, warnings, and errors.
        private let logger: ILogger
        
        // MARK: - Initializer
        
        /// Initializes the `StreamFactory` and sets up a subscription to the service's subscriber count.
        /// This ensures that the factory is aware of the number of active observers and can manage resources accordingly.
        init(logger: ILogger) {
            self.logger = logger
            service = StreamRegistration(logger: logger)
            Task { await setupSubscriptions() }
        }
        
        /// Deinitializer that logs the deinitialization process for debugging purposes.
        deinit {
            logger.log("Stream factory deinitialized", level: .debug)
        }
        
        @MainActor
        func beforeDeinit(){
            service.beforeDeinit()
        }
        
        // MARK: - API
        
        /// Provides an asynchronous stream of discovered peripherals using the service layer.
        /// This method returns a stream that emits arrays of `CBPeripheral` objects as they are discovered.
        /// - Returns: An `AsyncStream` emitting arrays of `CBPeripheral` objects.
        public func peripheralsStream() async -> AsyncStream<[CBPeripheral]> {
            await service.stream
        }
        
        /// Updates the list of discovered peripherals and notifies all registered subscribers.
        /// This method is asynchronous and ensures that notifications are sent in response to changes in the peripheral list.
        /// - Parameter peripherals: An array of `CBPeripheral` objects representing the discovered peripherals.
        @MainActor
        public func updatePeripherals(_ peripherals: [CBPeripheral]) async {
            await service.notifySubscribers(peripherals)
        }
        
        // MARK: - Private
   
        /// Sets up the subscription to the service's `subscriberCountPublisher`
        private func setupSubscriptions() async{
            // TODO: Refactor this code
            await service.subscriberCountPublisher
                .sink { [weak self] count in
                    guard let self = self else { return }
                    self.subscriberCountSubject.send(count)
                }
                .store(in: &self.cancellables)
        }
    }
}
