// BluetoothManager.swift

import Foundation
import CoreBluetooth
import os.log

// MARK: - Notification Names
extension Notification.Name {
    static let bluetoothDisconnected = Notification.Name("com.hrvmetrics.polarh10.BluetoothDisconnected")
    static let bluetoothReconnected = Notification.Name("com.hrvmetrics.polarh10.BluetoothReconnected")
    static let bluetoothReconnectFailed = Notification.Name("com.hrvmetrics.polarh10.BluetoothReconnectFailed")
}

// MARK: - BLE Service & Characteristic UUIDs
struct PolarUUIDs {
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateCharacteristic = CBUUID(string: "2A37")
    static let deviceInfoService = CBUUID(string: "180A")
    static let manufacturerNameCharacteristic = CBUUID(string: "2A29")
    static let modelNumberCharacteristic = CBUUID(string: "2A24")
    static let serialNumberCharacteristic = CBUUID(string: "2A25")
    static let firmwareRevisionCharacteristic = CBUUID(string: "2A26")
    static let hardwareRevisionCharacteristic = CBUUID(string: "2A27")
    static let batteryService = CBUUID(string: "180F")
    static let batteryLevelCharacteristic = CBUUID(string: "2A19")
}

class BluetoothManager: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.hrvmetrics.polarh10", category: "BluetoothManager")
    
    // Central Manager
    private var centralManager: CBCentralManager!
    
    // Connected Device
    private var polarDevice: CBPeripheral?
    
    // Device Information
    @Published var connectionState: ConnectionState = .disconnected
    @Published var errorMessage: String?
    @Published var heartRate: Int = 0
    @Published var deviceInfo = DeviceInfo()
    @Published var batteryLevel: Int = 0
    @Published var isScanning: Bool = false
    @Published var rrIntervals: [Int] = []
    
    // Auto-reconnect properties
    private var autoReconnectEnabled = false
    private var reconnectTimer: Timer?
    private var lastKnownPeripheral: CBPeripheral?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let reconnectDelay: TimeInterval = 3.0
    
    // Connection monitoring
    private var connectionMonitorTimer: Timer?
    private let connectionCheckInterval: TimeInterval = 30.0
    private var lastDataReceivedTime: Date?
    private let dataTimeoutInterval: TimeInterval = 60.0 // If no data for 1 minute, consider connection stale
    
    // Create a set of services to discover
    private let servicesToDiscover: [CBUUID] = [
        PolarUUIDs.heartRateService,
        PolarUUIDs.deviceInfoService,
        PolarUUIDs.batteryService
    ]
    
    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case scanning = "Scanning..."
        case connecting = "Connecting..."
        case connected = "Connected"
        case failed = "Connection Failed"
    }
    
    struct DeviceInfo {
        var manufacturer: String = "Unknown"
        var model: String = "Unknown"
        var serialNumber: String = "Unknown"
        var firmwareRevision: String = "Unknown"
        var hardwareRevision: String = "Unknown"
    }
    
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
        logger.info("BluetoothManager initialized")
        
        // Set current time as last data received time
        lastDataReceivedTime = Date()
        
        // Start connection monitor
        startConnectionMonitor()
    }
    
    deinit {
        stopConnectionMonitor()
        stopReconnectTimer()
    }
    
    // MARK: - Connection Control Methods
    
    // Start scanning for Polar H10 devices
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            logger.error("Cannot start scanning - Bluetooth is not powered on")
            self.errorMessage = "Bluetooth is not powered on. Please enable Bluetooth."
            return
        }
        
        logger.info("Starting scan for Polar H10 devices...")
        isScanning = true
        connectionState = .scanning
        errorMessage = nil
        
        // Scan specifically for heart rate service to find Polar devices with better options
        centralManager.scanForPeripherals(
            withServices: [PolarUUIDs.heartRateService],
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false,
                CBCentralManagerScanOptionSolicitedServiceUUIDsKey: servicesToDiscover
            ]
        )
        
        // Set timeout for scanning
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self, self.isScanning else { return }
            self.stopScanning()
            
            if self.connectionState == .scanning {
                self.connectionState = .failed
                self.errorMessage = "No Polar H10 devices found. Please ensure your device is powered on and nearby."
                self.logger.error("Scan timeout - No devices found")
            }
        }
    }
    
    // Stop scanning
    func stopScanning() {
        guard isScanning else { return }
        centralManager.stopScan()
        isScanning = false
        logger.info("Stopped scanning")
    }
    
    // Connect to the Polar H10 device
    func connectToDevice(peripheral: CBPeripheral) {
        logger.info("Attempting to connect to peripheral: \(peripheral.identifier.uuidString)")
        self.polarDevice = peripheral
        self.lastKnownPeripheral = peripheral  // Store for auto-reconnect
        self.polarDevice?.delegate = self
        self.connectionState = .connecting
        
        // Connect with better connection options for reliability
        let connectionOptions: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnConnectionKey: true
        ]
        
        self.centralManager.connect(peripheral, options: connectionOptions)
    }
    
    // Disconnect from the current device
    func disconnect() {
        guard let peripheral = polarDevice else { return }
        logger.info("Disconnecting from device: \(peripheral.identifier.uuidString)")
        
        // Disable auto-reconnect before intentional disconnect
        disableAutoReconnect()
        
        centralManager.cancelPeripheralConnection(peripheral)
    }
    
    // Called to clean up resources
    func cleanup() {
        logger.info("Cleaning up BluetoothManager")
        stopConnectionMonitor()
        stopReconnectTimer()
        stopScanning()
        // We don't automatically disconnect to allow background recording
    }
    
    // MARK: - Auto-Reconnect Methods
    
    // Enable auto-reconnect functionality
    func enableAutoReconnect() {
        autoReconnectEnabled = true
        logger.info("Auto-reconnect enabled")
    }
    
    // Disable auto-reconnect functionality
    func disableAutoReconnect() {
        autoReconnectEnabled = false
        stopReconnectTimer()
        logger.info("Auto-reconnect disabled")
    }
    
    // Start the reconnect timer
    private func startReconnectTimer() {
        // Cancel any existing timer
        stopReconnectTimer()
        
        guard autoReconnectEnabled else { return }
        
        reconnectAttempts = 0
        reconnectTimer = Timer.scheduledTimer(timeInterval: reconnectDelay,
                                             target: self,
                                             selector: #selector(attemptReconnect),
                                             userInfo: nil,
                                             repeats: true)
        
        if let timer = reconnectTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        logger.info("Started reconnect timer")
    }
    
    // Stop the reconnect timer
    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    // Attempt to reconnect to the device
    @objc private func attemptReconnect() {
        guard autoReconnectEnabled,
              connectionState != .connected,
              let peripheral = lastKnownPeripheral,
              reconnectAttempts < maxReconnectAttempts else {
            
            if reconnectAttempts >= maxReconnectAttempts {
                logger.error("Max reconnect attempts reached")
                stopReconnectTimer()
                
                // Notify about reconnection failure
                NotificationCenter.default.post(name: .bluetoothReconnectFailed, object: nil)
            }
            
            return
        }
        
        reconnectAttempts += 1
        logger.info("Attempting to reconnect (attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts))")
        
        // Try to connect again
        connectionState = .connecting
        
        // Use the same connection options as initial connect
        let connectionOptions: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnConnectionKey: true
        ]
        
        centralManager.connect(peripheral, options: connectionOptions)
    }
    
    // MARK: - Connection Monitoring Methods
    
    // Start monitoring the connection for staleness
    private func startConnectionMonitor() {
        connectionMonitorTimer?.invalidate()
        
        connectionMonitorTimer = Timer.scheduledTimer(timeInterval: connectionCheckInterval,
                                                     target: self,
                                                     selector: #selector(checkConnectionStatus),
                                                     userInfo: nil,
                                                     repeats: true)
        
        if let timer = connectionMonitorTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        logger.info("Started connection monitor")
    }
    
    // Stop connection monitoring
    private func stopConnectionMonitor() {
        connectionMonitorTimer?.invalidate()
        connectionMonitorTimer = nil
    }
    
    // Check if the connection is still active
    @objc private func checkConnectionStatus() {
        guard connectionState == .connected, let peripheral = polarDevice else { return }
        
        // Check if we've received data recently
        if let lastReceived = lastDataReceivedTime,
           Date().timeIntervalSince(lastReceived) > dataTimeoutInterval {
            
            logger.warning("No data received for over \(Int(self.dataTimeoutInterval)) seconds, connection may be stale")
            
            // If auto-reconnect is enabled, try to refresh the connection
            if autoReconnectEnabled {
                logger.info("Attempting to refresh stale connection")
                
                // Reconnect by first disconnecting
                centralManager.cancelPeripheralConnection(peripheral)
                
                // reconnect will happen through the didDisconnectPeripheral delegate method
            }
        }
    }
    
    // Update the last received data timestamp
    private func updateDataReceivedTimestamp() {
        lastDataReceivedTime = Date()
    }
    
    // MARK: - Heart Rate Data Processing
    private func processHeartRateData(_ data: Data) {
        guard data.count > 1 else { return }
        
        // Update data received timestamp since we got valid data
        updateDataReceivedTimestamp()
        
        let firstByte = data[0]
        let isFormat16Bit = ((firstByte & 0x01) == 0x01)
        
        var bpmValue: Int
        var index = 1
        
        // Parse BPM value
        if isFormat16Bit {
            guard data.count >= 3 else { return }
            bpmValue = Int(data[1]) + (Int(data[2]) << 8)
            index = 3
        } else {
            guard data.count >= 2 else { return }
            bpmValue = Int(data[1])
            index = 2
        }
        
        // Update heart rate value
        DispatchQueue.main.async {
            self.heartRate = bpmValue
        }
        logger.info("Updated heart rate: \(bpmValue) BPM")
        
        // Check if RR interval data is present
        let hasRRIntervals = ((firstByte & 0x10) == 0x10)
        
        if hasRRIntervals {
            // Parse RR intervals
            var newRRIntervals: [Int] = []
            
            // Each RR interval is 2 bytes, represented in 1/1024 second units
            while index + 1 < data.count {
                let rrRaw = UInt16(data[index]) + (UInt16(data[index+1]) << 8)
                let rrInMs = Int((Double(rrRaw) / 1024.0) * 1000.0)
                newRRIntervals.append(rrInMs)
                index += 2
            }
            
            if !newRRIntervals.isEmpty {
                DispatchQueue.main.async {
                    // Add new RR intervals
                    self.rrIntervals.append(contentsOf: newRRIntervals)
                }
                logger.info("Updated RR intervals: \(newRRIntervals)")
            }
        }
    }
    
    // MARK: - Helper Methods
    private func parseBatteryLevel(from data: Data) -> Int? {
        guard data.count >= 1 else { return nil }
        
        // Update data received timestamp
        updateDataReceivedTimestamp()
        
        return Int(data[0])
    }
    
    private func parseStringValue(from data: Data) -> String? {
        // Update data received timestamp
        updateDataReceivedTimestamp()
        
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            logger.info("Bluetooth is powered on and ready")
            
            // If we were previously connected and auto-reconnect is enabled, try to reconnect
            if let lastDevice = lastKnownPeripheral, autoReconnectEnabled {
                logger.info("Bluetooth powered on with auto-reconnect enabled, attempting to reconnect")
                connectToDevice(peripheral: lastDevice)
            }
            
        case .poweredOff:
            logger.error("Bluetooth is powered off")
            connectionState = .disconnected
            errorMessage = "Bluetooth is turned off. Please turn on Bluetooth."
            
        case .resetting:
            logger.error("Bluetooth is resetting")
            connectionState = .failed
            errorMessage = "Bluetooth is resetting. Please try again later."
            
        case .unauthorized:
            logger.error("Bluetooth access is unauthorized")
            connectionState = .failed
            errorMessage = "Bluetooth access is not authorized. Please check permissions."
            
        case .unsupported:
            logger.error("Bluetooth is not supported on this device")
            connectionState = .failed
            errorMessage = "Bluetooth is not supported on this device."
            
        case .unknown:
            logger.error("Bluetooth state is unknown")
            connectionState = .failed
            errorMessage = "Bluetooth state is unknown. Please restart the app."
            
        @unknown default:
            logger.error("Unknown Bluetooth state")
            connectionState = .failed
            errorMessage = "Unknown Bluetooth state. Please restart the app."
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let deviceName = peripheral.name ?? "Unnamed Device"
        let peripheralID = peripheral.identifier.uuidString
        
        logger.info("Discovered peripheral: \(deviceName), ID: \(peripheralID), RSSI: \(RSSI.intValue)")
        
        // Look for Polar devices with better filtering
        if deviceName.contains("Polar") || (advertisementData[CBAdvertisementDataLocalNameKey] as? String)?.contains("Polar") == true {
            logger.info("Found Polar device: \(deviceName)")
            
            // Check signal strength - only connect if signal is strong enough
            if RSSI.intValue > -70 { // Adjust this threshold as needed
                stopScanning()
                connectToDevice(peripheral: peripheral)
            } else {
                logger.warning("Signal strength too weak (\(RSSI.intValue) dBm), continuing to scan")
                // Continue scanning to see if the device gets closer or if we find others
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionState = .connected
        logger.info("Connected to peripheral: \(peripheral.identifier.uuidString)")
        
        // Reset reconnect attempts on successful connection
        reconnectAttempts = 0
        stopReconnectTimer()
        
        // Reset the data received timestamp
        lastDataReceivedTime = Date()
        
        // Discover services with timeout handling
        peripheral.discoverServices(servicesToDiscover)
        
        // Set a timeout for service discovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self,
                  self.connectionState == .connected,
                  let services = peripheral.services,
                  services.isEmpty else { return }
            
            // If no services discovered after timeout, try rediscovering
            self.logger.warning("Service discovery timeout, retrying...")
            peripheral.discoverServices(self.servicesToDiscover)
        }
        
        // Notify about reconnection if we were previously disconnected
        NotificationCenter.default.post(name: .bluetoothReconnected, object: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .failed
        if let error = error {
            logger.error("Failed to connect to peripheral: \(error.localizedDescription)")
            errorMessage = "Failed to connect: \(error.localizedDescription)"
        } else {
            logger.error("Failed to connect to peripheral for unknown reason")
            errorMessage = "Failed to connect for unknown reason"
        }
        
        // If auto-reconnect is enabled, start reconnect timer
        if autoReconnectEnabled {
            startReconnectTimer()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionState = .disconnected
        
        if let error = error {
            logger.error("Disconnected from peripheral with error: \(error.localizedDescription)")
            errorMessage = "Disconnected: \(error.localizedDescription)"
            
            // Start reconnect timer if auto-reconnect is enabled
            if autoReconnectEnabled {
                logger.info("Auto-reconnect is enabled, starting reconnect timer")
                startReconnectTimer()
            }
        } else {
            logger.info("Disconnected from peripheral normally")
            errorMessage = nil
            
            // Only attempt to reconnect for unexpected disconnections
            // For manual disconnections, autoReconnectEnabled would be false
        }
        
        // Notify about disconnection
        NotificationCenter.default.post(name: .bluetoothDisconnected, object: nil)
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logger.error("Error discovering services: \(error.localizedDescription)")
            errorMessage = "Error discovering services: \(error.localizedDescription)"
            return
        }
        
        guard let services = peripheral.services else {
            logger.error("No services found")
            return
        }
        
        logger.info("Discovered \(services.count) services")
        
        for service in services {
            logger.info("Discovered service: \(service.uuid.uuidString)")
            
            // Discover characteristics based on service
            switch service.uuid {
            case PolarUUIDs.heartRateService:
                peripheral.discoverCharacteristics([PolarUUIDs.heartRateCharacteristic], for: service)
                
            case PolarUUIDs.deviceInfoService:
                let characteristics: [CBUUID] = [
                    PolarUUIDs.manufacturerNameCharacteristic,
                    PolarUUIDs.modelNumberCharacteristic,
                    PolarUUIDs.serialNumberCharacteristic,
                    PolarUUIDs.firmwareRevisionCharacteristic,
                    PolarUUIDs.hardwareRevisionCharacteristic
                ]
                peripheral.discoverCharacteristics(characteristics, for: service)
                
            case PolarUUIDs.batteryService:
                peripheral.discoverCharacteristics([PolarUUIDs.batteryLevelCharacteristic], for: service)
                
            default:
                logger.info("Not handling service: \(service.uuid.uuidString)")
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            logger.error("Error discovering characteristics: \(error.localizedDescription)")
            errorMessage = "Error discovering characteristics: \(error.localizedDescription)"
            return
        }
        
        guard let characteristics = service.characteristics else {
            logger.error("No characteristics found for service \(service.uuid.uuidString)")
            return
        }
        
        for characteristic in characteristics {
            logger.info("Discovered characteristic: \(characteristic.uuid.uuidString) for service: \(service.uuid.uuidString)")
            
            // Handle each characteristic based on UUID
            switch characteristic.uuid {
            case PolarUUIDs.heartRateCharacteristic:
                logger.info("Setting up heart rate notifications")
                
                // Enable notification with retry mechanism
                peripheral.setNotifyValue(true, for: characteristic)
                
                // Set a retry mechanism if notification fails to start
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    if !characteristic.isNotifying {
                        self?.logger.warning("Heart rate notification failed to start, retrying...")
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
                
            case PolarUUIDs.batteryLevelCharacteristic:
                logger.info("Reading battery level")
                peripheral.readValue(for: characteristic)
                
                // Set up notification for battery level changes
                peripheral.setNotifyValue(true, for: characteristic)
                
            case PolarUUIDs.manufacturerNameCharacteristic,
                 PolarUUIDs.modelNumberCharacteristic,
                 PolarUUIDs.serialNumberCharacteristic,
                 PolarUUIDs.firmwareRevisionCharacteristic,
                 PolarUUIDs.hardwareRevisionCharacteristic:
                logger.info("Reading device info: \(characteristic.uuid.uuidString)")
                peripheral.readValue(for: characteristic)
                
            default:
                logger.info("Not handling characteristic: \(characteristic.uuid.uuidString)")
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Error updating value for characteristic \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else {
            logger.error("No data received for characteristic \(characteristic.uuid.uuidString)")
            return
        }
        
        switch characteristic.uuid {
        case PolarUUIDs.heartRateCharacteristic:
            processHeartRateData(data)
            
        case PolarUUIDs.batteryLevelCharacteristic:
            if let batteryLevel = parseBatteryLevel(from: data) {
                DispatchQueue.main.async {
                    self.batteryLevel = batteryLevel
                }
                logger.info("Updated battery level: \(batteryLevel)%")
            }
            
        case PolarUUIDs.manufacturerNameCharacteristic:
            if let value = parseStringValue(from: data) {
                DispatchQueue.main.async {
                    self.deviceInfo.manufacturer = value
                }
                logger.info("Manufacturer: \(value)")
            }
            
        case PolarUUIDs.modelNumberCharacteristic:
            if let value = parseStringValue(from: data) {
                DispatchQueue.main.async {
                    self.deviceInfo.model = value
                }
                logger.info("Model: \(value)")
            }
            
        case PolarUUIDs.serialNumberCharacteristic:
            if let value = parseStringValue(from: data) {
                DispatchQueue.main.async {
                    self.deviceInfo.serialNumber = value
                }
                logger.info("Serial Number: \(value)")
            }
            
        case PolarUUIDs.firmwareRevisionCharacteristic:
            if let value = parseStringValue(from: data) {
                DispatchQueue.main.async {
                    self.deviceInfo.firmwareRevision = value
                }
                logger.info("Firmware Revision: \(value)")
            }
            
        case PolarUUIDs.hardwareRevisionCharacteristic:
            if let value = parseStringValue(from: data) {
                DispatchQueue.main.async {
                    self.deviceInfo.hardwareRevision = value
                }
                logger.info("Hardware Revision: \(value)")
            }
            
        default:
            logger.info("Received data for unhandled characteristic: \(characteristic.uuid.uuidString)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("Error changing notification state for \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            
            // If enabling notifications failed, try again after a short delay
            if characteristic.uuid == PolarUUIDs.heartRateCharacteristic && !characteristic.isNotifying {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
            return
        }
        
        if characteristic.isNotifying {
            logger.info("Notifications enabled for \(characteristic.uuid.uuidString)")
        } else {
            logger.info("Notifications disabled for \(characteristic.uuid.uuidString)")
            
            // If this is the heart rate characteristic, we want notifications, so try to re-enable
            if characteristic.uuid == PolarUUIDs.heartRateCharacteristic && connectionState == .connected {
                logger.warning("Heart rate notifications disabled unexpectedly, re-enabling")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }
}
