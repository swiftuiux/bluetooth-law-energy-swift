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
    final class StreamFactory {
        
        /// Publisher to expose the number of subscribers to stream events.
        /// Он проксирует события из актёра.
        public var subscriberCountPublisher: AnyPublisher<Int, Never> {
            subscriberCountSubject.eraseToAnyPublisher()
        }
        
        /// Internal relay subject (thread-safe via single writer in this class).
        private let subscriberCountSubject = PassthroughSubject<Int, Never>()
        
        /// Internal service (actor) that handles registration/notification.
        private let service: StreamRegistration
        
        /// Cancellables for Combine subscriptions.
        private var cancellables = Set<AnyCancellable>()
        
        /// Logger
        private let logger: ILogger
        
        // MARK: - Initializer
        
        init(logger: ILogger) {
            self.logger = logger
            self.service = StreamRegistration(logger: logger)
            Task { await setupSubscriptions() }
        }
        
        deinit {
            logger.log("Stream factory deinitialized", level: .debug)
        }        
        
        // MARK: - API
        
        /// Provides an asynchronous stream of discovered peripherals.
        public func peripheralsStream() async -> AsyncStream<[CBPeripheral]> {
            await service.stream
        }
        
        /// Push updated peripherals to all subscribers.
        @MainActor
        public func updatePeripherals(_ peripherals: [CBPeripheral]) async {
            await service.notifySubscribers(peripherals)
        }
        
        // MARK: - Private
   
        /// Mirror actor's subscriber count to a local subject.
        private func setupSubscriptions() async {
            let publisher = await service.subscriberCountPublisher
            publisher
                .sink { [weak self] count in
                    guard let self else { return }
                    self.subscriberCountSubject.send(count)
                }
                .store(in: &cancellables)
        }
    }
}
