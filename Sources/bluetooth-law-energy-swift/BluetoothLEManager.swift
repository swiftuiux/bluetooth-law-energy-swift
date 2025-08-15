//
//  BluetoothLEManager.swift
//
//
//  Created by Igor on 12.07.24.
//

import Combine
import CoreBluetooth
import retry_policy_service

/// Manages Bluetooth Low Energy (BLE) interactions using Combine and CoreBluetooth.
@available(macOS 12, iOS 15, tvOS 15.0, watchOS 8.0, *)
public final class BluetoothLEManager: NSObject, ObservableObject, @preconcurrency IBluetoothLEManager {

    /// A subject that publishes the BLE state changes to the main actor.
    @MainActor
    public let bleState: CurrentValueSubject<BLEState, Never> = .init(.init())

    /// Internal state variables
    private var isAuthorized = false
    private var isPowered = false
    private var isScanning = false

    /// Type aliases for publishers
    private typealias StatePublisher = AnyPublisher<CBManagerState, Never>
    private typealias PeripheralPublisher = AnyPublisher<[CBPeripheral], Never>

    /// Publishers for state and peripheral updates
    private var getStatePublisher: StatePublisher { delegateHandler.statePublisher }
    private var getPeripheralPublisher: PeripheralPublisher { delegateHandler.peripheralPublisher }

    /// Internal types and instances
    private let centralManager: CBCentralManager
    @MainActor
    private let cachedServices = CacheServices()

    private typealias Delegate = BluetoothDelegate
    private let state = BluetoothLEManager.State()
    private let stream : StreamFactory
    private let delegateHandler: Delegate
    private var cancellables: Set<AnyCancellable> = []
    private let retry = RetryService(strategy: .exponential(retry: 5, multiplier: 2, duration: .seconds(3), timeout: .seconds(15)))
    private let logger: ILogger

    /// Initializes the BluetoothLEManager with a logger.
    public init(logger: ILogger?, queue : DispatchQueue? = nil) {

        let logger = logger ?? AppleLogger(subsystem: "BluetoothLEManager", category: "Bluetooth")
        self.logger = logger
        stream = StreamFactory(logger: logger)
        delegateHandler = Delegate(logger: logger)
        centralManager = CBCentralManager(delegate: delegateHandler, queue: queue)

        super.init()

        setupSubscriptions()

        logger.log("BluetoothManager initialized on \(Date())", level: .debug)
    }

    /// Deinitializes the BluetoothLEManager.
    deinit {
        logger.log("BluetoothManager deinitialized", level: .debug)
    }


    // MARK: - API

    /// Provides a stream of discovered peripherals.
    @MainActor
    public var peripheralsStream: AsyncStream<[CBPeripheral]> {
        get async{
            await stream.peripheralsStream()
        }
    }

    /// Discovers services for a given peripheral, with optional caching and optional disconnection.
    ///
    /// Apple’s documentation specifies that all Core Bluetooth interactions should be performed on the main thread to maintain thread safety and proper synchronization of Bluetooth events. This includes interactions with `CBCentralManager`, such as connecting and disconnecting peripherals.
    ///
    /// - Parameters:
    ///   - peripheral: The `CBPeripheral` instance to fetch services for.
    ///   - cache: A Boolean value indicating whether to use cached data. Defaults to `true`.
    ///   - disconnect: A Boolean value indicating whether to disconnect from the peripheral after fetching services. Defaults to `true`.
    /// - Returns: An array of `CBService` instances.
    /// - Throws: An error if the services could not be fetched.
    @MainActor
    public func discoverServices(for peripheral: CBPeripheral, from cache: Bool = true, disconnect: Bool = true) async throws -> [CBService] {
        defer {
            if disconnect {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }

         ///Check the cache before attempting to fetch services
        if cache, let services = cachedServices.fetch(for: peripheral) {
            return services
        }

        for delay in retry {
            do {
                return try await attemptFetchServices(for: peripheral, cache: cache)
            } catch { }

            try? await Task.sleep(nanoseconds: delay)

            if cache, let services = cachedServices.fetch(for: peripheral) {
                return services
            }
        }

        /// Final attempt to fetch services if retries fail
        return try await attemptFetchServices(for: peripheral, cache: cache)
    }

    /// Connects to a specific peripheral.
    /// Always use the same CBCentralManager instance to manage connections and disconnections for a peripheral to avoid errors and ensure correct behavior
    /// - Parameter peripheral: The `CBPeripheral` instance to connect to.
    /// - Throws: `BluetoothLEManager.Errors` if the connection fails.
    @MainActor
    public func connect(to peripheral: CBPeripheral) async throws {
        guard peripheral.isNotConnected else {
            throw Errors.connected(peripheral)
        }

        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let id = peripheral.getId
                let name = peripheral.getName
                try await delegateHandler.connect(to: id, name: name, with: continuation)
                centralManager.connect(peripheral, options: nil)
            }
        }
    }

    /// Disconnects from a specific peripheral.
    /// Always use the same CBCentralManager instance to manage connections and disconnections for a peripheral to avoid errors and ensure correct behavior
    /// - Parameter peripheral: The `CBPeripheral` instance to connect to.
    /// - Throws: `BluetoothLEManager.Errors` if the connection fails.
    @MainActor
    public func disconnect(from peripheral: CBPeripheral) async throws {
        guard peripheral.isConnected else {
            throw Errors.notConnected(peripheral.getName)
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let id = peripheral.getId
                let name = peripheral.getName
                try await delegateHandler.disconnect(to: id, name: name, with: continuation)
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }
    
    // MARK: - Private Methods

    /// Attempts to connect to the given peripheral and fetch its services.
    ///
    /// - Parameters:
    ///   - peripheral: The `CBPeripheral` to connect to.
    ///   - cache: A Boolean value indicating whether to use cached services if available.
    ///
    /// - Returns: An array of `CBService` objects representing the services of the peripheral.
    ///
    /// - Throws: An error if the connection or service discovery fails.
    @MainActor
    private func attemptFetchServices(for peripheral: CBPeripheral, cache: Bool) async throws -> [CBService] {
        try await connect(to: peripheral)
        return try await discover(for: peripheral, cache: cache)
    }

    /// Discovers services for a connected peripheral.
    ///
    /// - Parameters:
    ///   - peripheral: The `CBPeripheral` instance to discover services for.
    ///   - cache: A Boolean value indicating whether to cache the services.
    /// - Returns: An array of `CBService` instances.
    /// - Throws: An error if the services could not be discovered.
    @MainActor
    private func discover(for peripheral: CBPeripheral, cache: Bool) async throws -> [CBService] {
        defer { peripheral.delegate = nil }

        try Task.checkCancellation()

        let delegate = PeripheralDelegate(logger: logger)
        peripheral.delegate = delegate
        try await delegate.discoverServices(for: peripheral)

        let services = peripheral.services ?? []

        if cache {
            cachedServices.add(key: peripheral.getId, services: services)
        }

        return services
    }

    /// Sets up Combine subscriptions for state and peripheral changes.
    private func setupSubscriptions() {
        getPeripheralPublisher
            .sink { [weak self] peripherals in
                guard let self = self else { return }
                Task {
                    await self.handlePeripheralChange(peripherals)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(getStatePublisher, stream.subscriberCountPublisher)
            .receiveOnMainAndEraseToAnyPublisher()
            .sink { [weak self] state, subscriberCount in
                guard let self = self else { return }
                    let state = self.checkForScan(state, subscriberCount)
                    self.bleState.send(state)
            }
            .store(in: &cancellables)
    }

    /// Handles changes in discovered peripherals.
    ///
    /// - Parameter peripherals: An array of discovered `CBPeripheral` instances.
    private func handlePeripheralChange(_ peripherals: [CBPeripheral]) async {
       await stream.updatePeripherals(peripherals)
    }

    /// Checks if Bluetooth is ready (powered on and authorized).
    private var checkIfBluetoothReady: Bool {
        isAuthorized = State.isBluetoothAuthorized
        isPowered = State.isBluetoothPoweredOn(for: centralManager)
        return isPowered && isAuthorized
    }

    /// Checks if scanning should start or stop based on the state and subscriber count.
    ///
    /// - Parameters:
    ///   - state: The current `CBManagerState`.
    ///   - subscriberCount: The number of subscribers.
    /// - Returns: The updated `BLEState`.
    private func checkForScan(_ state: CBManagerState, _ subscriberCount: Int) -> BLEState {
        if !checkIfBluetoothReady {
            stopScanning()
        } else {
            if subscriberCount == 0 {
                stopScanning()
            } else {
                startScanning()
            }
            isScanning = subscriberCount != 0
        }

        return .init(
            isAuthorized: self.isAuthorized,
            isPowered: self.isPowered,
            isScanning: self.isScanning
        )
    }

    /// Starts scanning for peripherals.
    private func startScanning() {
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }

    /// Stops scanning for peripherals.
    private func stopScanning() {
        centralManager.stopScan()
    }
}
