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
public final class BluetoothLEManager: NSObject, ObservableObject, IBluetoothLEManager {

    /// Publishes BLE state changes to the main actor.
    @MainActor
    public let bleState: CurrentValueSubject<BLEState, Never> = .init(.init())

    /// Internal state flags.
    private var isAuthorized = false
    private var isPowered = false
    private var isScanning = false

    /// Type aliases for publishers.
    private typealias StatePublisher = AnyPublisher<CBManagerState, Never>
    private typealias PeripheralPublisher = AnyPublisher<[CBPeripheral], Never>

    /// Publishers for state and peripheral updates.
    private var getStatePublisher: StatePublisher { delegateHandler.statePublisher }
    private var getPeripheralPublisher: PeripheralPublisher { delegateHandler.peripheralPublisher }

    /// CoreBluetooth central manager.
    private let centralManager: CBCentralManager
    /// The queue on which the central delivers callbacks; we also dispatch central calls onto this queue.
    private let bleQueue: DispatchQueue

    @MainActor
    private let cachedServices = CacheServices()

    private typealias Delegate = BluetoothDelegate
    private let stream : StreamFactory
    private let delegateHandler: Delegate
    private var cancellables: Set<AnyCancellable> = []
    private let retry = RetryService(strategy: .exponential(retry: 5, multiplier: 2, duration: .seconds(3), timeout: .seconds(15)))
    private let logger: ILogger

    /// Initializes the BluetoothLEManager with a logger.
    /// Always uses the main queue for CoreBluetooth to ensure thread safety and consistent behavior.
    public init(logger: ILogger?) {
        let logger = logger ?? AppleLogger(subsystem: "BluetoothLEManager", category: "Bluetooth")
        self.logger = logger
        stream = StreamFactory(logger: logger)
        delegateHandler = Delegate(logger: logger)

        // Always main queue — CoreBluetooth interactions are guaranteed to run here.
        self.bleQueue = .main
        self.centralManager = CBCentralManager(delegate: delegateHandler, queue: bleQueue)

        super.init()
        setupSubscriptions()
    }

    /// Deinitializes the BluetoothLEManager.
    deinit {
        onBLE { [centralManager] in
            centralManager.stopScan()
            centralManager.delegate = nil
        }
        logger.log("BluetoothManager deinitialized", level: .debug)
    }

    // MARK: - Queue helper

    @inline(__always)
    private func onBLE(_ block: @escaping () -> Void) {
        bleQueue.async(execute: block) // always hop; simpler & safe
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
    /// Note: public API stays on @MainActor; CoreBluetooth calls are dispatched to the central's queue.
    @MainActor
    public func discoverServices(for peripheral: CBPeripheral, from cache: Bool = true, disconnect: Bool = true) async throws -> [CBService] {
        
        try Task.checkCancellation() // ensure early exit if cancelled
        defer {
            if disconnect {
                // Ensure cancellation runs on the central's queue.
                onBLE { [centralManager] in
                    centralManager.cancelPeripheralConnection(peripheral)
                }
            }
        }

        // Check the cache before attempting to fetch services.
        if cache, let services = cachedServices.fetch(for: peripheral) {
            return services
        }

        for delay in retry {
            do {
                return try await attemptFetchServices(for: peripheral, cache: cache)
            } catch { }

            try await Task.sleep(nanoseconds: delay)

            if cache, let services = cachedServices.fetch(for: peripheral) {
                return services
            }
        }

        // Final attempt to fetch services if retries fail
        return try await attemptFetchServices(for: peripheral, cache: cache)
    }

    /// Connects to a specific peripheral.
    /// Contract:
    ///  - Public API is @MainActor for UI-facing consistency.
    ///  - We *register* an async expectation with `delegateHandler` first,
    ///    then invoke CoreBluetooth on the central's queue via `onBLE`.
    ///  - Cancellation is checked early and again right before the central call,
    ///    so the operation can exit cleanly if the task was cancelled.
    @MainActor
    public func connect(to peripheral: CBPeripheral) async throws {
        guard peripheral.isNotConnected else { throw Errors.connected(peripheral) }
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let id = peripheral.getId
                let name = peripheral.getName
                do {
                    try await delegateHandler.connect(to: id, name: name, with: continuation)
                    try Task.checkCancellation() // ensure early exit if cancelled
                    onBLE { [weak self] in
                        guard let self else { return }
                        self.centralManager.connect(peripheral, options: nil)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Disconnects from a specific peripheral.
    /// Contract:
    ///  - Public API is @MainActor for UI-facing consistency.
    ///  - We *register* an async expectation with `delegateHandler` first,
    ///    then invoke CoreBluetooth on the central's queue via `onBLE`.
    ///  - Cancellation is checked early and again right before the central call,
    ///    so the operation can exit cleanly if the task was cancelled.
    @MainActor
    public func disconnect(from peripheral: CBPeripheral) async throws {
        guard peripheral.isConnected else { throw Errors.notConnected(peripheral.getName) }
        try Task.checkCancellation()
        
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let id = peripheral.getId
                let name = peripheral.getName
                do {
                    try await delegateHandler.disconnect(to: id, name: name, with: continuation)
                    try Task.checkCancellation() // ensure early exit if cancelled
                    onBLE { [weak self] in
                        guard let self else { return }
                        self.centralManager.cancelPeripheralConnection(peripheral)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Private Methods

    /// Attempts to connect to the given peripheral and fetch its services.
    @MainActor
    private func attemptFetchServices(for peripheral: CBPeripheral, cache: Bool) async throws -> [CBService] {
        try Task.checkCancellation() // ensure early exit if cancelled
        try await connect(to: peripheral)
        return try await discover(for: peripheral, cache: cache)
    }

    /// Discovers services for a connected peripheral.
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
                let stream = self.stream
                Task {
                    await stream.updatePeripherals(peripherals)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(getStatePublisher, stream.subscriberCountPublisher)
            .receiveOnMainAndEraseToAnyPublisher()
            .sink { [weak self] state, subscriberCount in
                guard let self = self else { return }
                let result = self.checkForScan(state, subscriberCount)
                let bleState = self.bleState
                Task { @MainActor in
                    bleState.send(result)
                }
            }
            .store(in: &cancellables)
    }

    /// Checks if Bluetooth is ready (powered on and authorized).
    private var checkIfBluetoothReady: Bool {
        isAuthorized = State.isBluetoothAuthorized
        isPowered = State.isBluetoothPoweredOn(for: centralManager)
        return isPowered && isAuthorized
    }

    /// Starts or stops scanning based on the state and subscriber count.
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

    /// Starts scanning for peripherals (dispatched to the central's queue).
    private func startScanning() {
        onBLE { [centralManager] in
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    /// Stops scanning for peripherals (dispatched to the central's queue).
    private func stopScanning() {
        onBLE { [centralManager] in
            centralManager.stopScan()
        }
    }
}
