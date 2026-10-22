//
//  readers.swift
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 17/06/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

/// Indexes into one specific sensors list; only valid for a list with the same structure (count).
private struct SensorIndexes {
    static let computedKeys: [String] = [
        "Average CPU", "Hottest CPU", "Average GPU", "Hottest GPU", "Average SOC", "Hottest SOC",
        "Fastest fan", "CPU Power", "GPU Power", "ANE Power", "RAM Power", "PCI Power",
        "Total System Consumption", "Average System Total", "PSTR", "VD0R", "ID0R"
    ]
    
    var count: Int = 0
    var cpuAverage: [Int] = []
    var gpuAverage: [Int] = []
    var fan: [Int] = []
    var hidCpu: [Int] = []
    var hidGpu: [Int] = []
    var hidSoc: [Int] = []
    var hid: [String: Int] = [:]
    var computed: [String: Int] = [:]
    
    init() {}
    
    init(_ sensors: [Sensor_p]) {
        self.count = sensors.count
        let computedKeys = Set(SensorIndexes.computedKeys)
        
        for (i, s) in sensors.enumerated() {
            if s.group == .CPU && s.type == .temperature && s.average {
                self.cpuAverage.append(i)
            }
            if s.group == .GPU && s.type == .temperature && s.average {
                self.gpuAverage.append(i)
            }
            if s.type == .fan && !s.isComputed {
                self.fan.append(i)
            }
            if s.key.hasPrefix("pACC MTR Temp") || s.key.hasPrefix("eACC MTR Temp") {
                self.hidCpu.append(i)
            }
            if s.key.hasPrefix("GPU MTR Temp") {
                self.hidGpu.append(i)
            }
            if s.key.hasPrefix("SOC MTR Temp") {
                self.hidSoc.append(i)
            }
            if s.group == .hid && self.hid[s.key] == nil {
                self.hid[s.key] = i
            }
            if computedKeys.contains(s.key) && self.computed[s.key] == nil {
                self.computed[s.key] = i
            }
        }
    }
}

internal class SensorsReader: Reader<Sensors_List> {
    static let HIDtypes: [SensorType] = [.temperature, .voltage]
    
    internal var list: Sensors_List = Sensors_List()
    
    private var lastRead: TimeInterval = ProcessInfo.processInfo.systemUptime
    private let firstRead: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastIOSensorsRead: Date? = nil
    
    private var HIDState: Bool {
        Store.shared.bool(key: "Sensors_hid", defaultValue: false)
    }
    private var unknownSensorsState: Bool
    
    private var channels: CFMutableDictionary? = nil
    private var subscription: IOReportSubscriptionRef? = nil
    private var powers: (CPU: Double, GPU: Double, ANE: Double, RAM: Double, PCI: Double) = (0.0, 0.0, 0.0, 0.0, 0.0)
    
    // precomputed indexes into the sensors list, rebuilt whenever the list structure changes.
    // they let read() skip the repeated filter/firstIndex scans over the whole list every tick.
    // rebuilt from a background queue (HID toggle), so access goes through the lock
    private let indexesLock = NSLock()
    private var _indexes = SensorIndexes()
    private var indexes: SensorIndexes {
        get {
            self.indexesLock.lock()
            defer { self.indexesLock.unlock() }
            return self._indexes
        }
        set {
            self.indexesLock.lock()
            defer { self.indexesLock.unlock() }
            self._indexes = newValue
        }
    }
    
    init(callback: @escaping (T?) -> Void = {_ in }) {
        self.unknownSensorsState = Store.shared.bool(key: "Sensors_unknown", defaultValue: false)
        super.init(.sensors, callback: callback)
        
        self.channels = self.getChannels()
        var dict: Unmanaged<CFMutableDictionary>?
        self.subscription = IOReportCreateSubscription(nil, self.channels, &dict, 0, nil)
        dict?.release()
        
        self.list.sensors = self.sensors()
        self.rebuildIndexes()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.resetHIDSensors), name: NSWorkspace.didWakeNotification, object: nil)
    }
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        AppleSiliconSensorsReset()
    }
    
    public override func stop() {
        super.stop()
        self.resetHIDSensors()
    }
    
    public override func terminate() {
        self.resetHIDSensors()
    }
    
    @objc private func resetHIDSensors() {
        AppleSiliconSensorsReset()
    }
    
    private func sensors() -> [Sensor_p] {
        var available: [String] = SMC.shared.getAllKeys()
        var list: [Sensor_p] = []
        var sensorsList = SensorsList
        
        if let platform = SystemKit.shared.device.platform {
            sensorsList = sensorsList.filter({ $0.platforms.contains(platform) })
        }
        
        if let count = SMC.shared.getValue("FNum") {
            list += self.loadFans(Int(count))
        }
        
        available = available.filter({ (key: String) -> Bool in
            switch key.prefix(1) {
            case "T", "V", "P", "I": return true
            default: return false
            }
        })
        
        sensorsList.forEach { (s: Sensor) in
            if let idx = available.firstIndex(where: { $0 == s.key }) {
                list.append(s)
                available.remove(at: idx)
            }
        }
        sensorsList.filter{ $0.key.contains("%") }.forEach { (s: Sensor) in
            var index = 1
            for i in 0..<10 {
                let key = s.key.replacingOccurrences(of: "%", with: "\(i)")
                if let idx = available.firstIndex(where: { $0 == key }) {
                    var sensor = s.copy()
                    sensor.key = key
                    sensor.name = s.name.replacingOccurrences(of: "%", with: "\(index)")
                    
                    list.append(sensor)
                    available.remove(at: idx)
                    index += 1
                }
            }
        }
        available.forEach { (key: String) in
            var type: SensorType? = nil
            switch key.prefix(1) {
            case "T": type = .temperature
            case "V": type = .voltage
            case "P": type = .power
            case "I": type = .current
            default: type = nil
            }
            if let t = type {
                list.append(Sensor(key: key, name: key, group: .unknown, type: t, platforms: []))
            }
        }
        
        for sensor in list {
            if let newValue = SMC.shared.getValue(sensor.key) {
                if let idx = list.firstIndex(where: { $0.key == sensor.key }) {
                    list[idx].value = newValue
                }
            }
        }
        
        var results: [Sensor_p] = []
        results += list.filter({ (s: Sensor_p) -> Bool in
            if s.type == .temperature && (s.value == 0 || s.value > 110) {
                return false
            } else if s.type == .current && s.value > 100 {
                return false
            }
            return true
        })
        
        #if arch(arm64)
        if self.HIDState {
            results += self.initHIDSensors()
        }
        results += self.initIOSensors()
        #endif
        results += self.initCalculatedSensors(results)
        
        return results
    }
    
    /// Rebuilds the index caches from the current sensor list. Must be called whenever
    /// the list structure changes (init, HID sensors toggle).
    private func rebuildIndexes() {
        self.indexes = SensorIndexes(self.list.sensors)
    }
    
    private static func average(_ sensors: [Sensor_p], _ indexes: [Int]) -> (avg: Double, max: Double)? {
        guard !indexes.isEmpty else { return nil }
        var total: Double = 0
        var max: Double = -Double.infinity
        for i in indexes {
            let value = sensors[i].value
            total += value
            if value > max {
                max = value
            }
        }
        return (total / Double(indexes.count), max)
    }
    
    public override func read() {
        var sensors = self.list.sensors
        var indexes = self.indexes
        if indexes.count != sensors.count {
            // the list structure changed after the indexes were built (e.g. HID sensors toggle
            // in progress), build them from this snapshot so they always match it
            indexes = SensorIndexes(sensors)
        }
        
        for i in sensors.indices {
            guard sensors[i].group != .hid && !sensors[i].isComputed else { continue }
            if !self.unknownSensorsState && sensors[i].group == .unknown { continue }
            
            var newValue = SMC.shared.getValue(sensors[i].key) ?? 0
            if sensors[i].type == .temperature && sensors[i].group == .CPU &&
                (newValue < 10 || newValue > 120) { // fix for m2 broken sensors
                newValue = sensors[i].value
            }
            sensors[i].value = newValue
        }
        
        var cpuIdx = indexes.cpuAverage
        var gpuIdx = indexes.gpuAverage
        
        #if arch(arm64)
        if self.HIDState {
            for typ in SensorsReader.HIDtypes {
                let (page, usage, type) = self.m1Preset(type: typ)
                AppleSiliconSensors(page, usage, type).forEach { (key, value) in
                    guard let key = key as? String, let value = value as? Double, value < 300 && value >= 0 else {
                        return
                    }
                    
                    if let idx = indexes.hid[key] {
                        sensors[idx].value = value
                    }
                }
            }
            
            cpuIdx += indexes.hidCpu
            gpuIdx += indexes.hidGpu
            
            if let value = SensorsReader.average(sensors, indexes.hidSoc) {
                if let idx = indexes.computed["Average SOC"] {
                    sensors[idx].value = value.avg
                }
                if let idx = indexes.computed["Hottest SOC"] {
                    sensors[idx].value = value.max
                }
            }
        }
        
        if let (cpu, gpu, ane, ram, pci) = self.IOSensors() {
            if let idx = indexes.computed["CPU Power"] {
                sensors[idx].value = cpu
            }
            if let idx = indexes.computed["GPU Power"] {
                sensors[idx].value = gpu
            }
            if let idx = indexes.computed["ANE Power"] {
                sensors[idx].value = ane
            }
            if let idx = indexes.computed["RAM Power"] {
                sensors[idx].value = ram
            }
            if let idx = indexes.computed["PCI Power"] {
                sensors[idx].value = pci
            }
        }
        #endif
        
        if let (avg, max) = SensorsReader.average(sensors, cpuIdx) {
            if let idx = indexes.computed["Average CPU"] {
                sensors[idx].value = avg
            }
            if let idx = indexes.computed["Hottest CPU"] {
                sensors[idx].value = max
            }
        }
        if let (avg, max) = SensorsReader.average(sensors, gpuIdx) {
            if let idx = indexes.computed["Average GPU"] {
                sensors[idx].value = avg
            }
            if let idx = indexes.computed["Hottest GPU"] {
                sensors[idx].value = max
            }
        }
        if indexes.fan.count > 1 {
            var fastest: Fan? = nil
            for i in indexes.fan {
                guard let fan = sensors[i] as? Fan else { continue }
                if let current = fastest, fan.value <= current.value { continue }
                fastest = fan
            }
            if let f = fastest {
                if let idx = indexes.computed["Fastest fan"] {
                    if var fan = sensors[idx] as? Fan {
                        fan.value = f.value
                        fan.minSpeed = f.minSpeed
                        fan.maxSpeed = f.maxSpeed
                        sensors[idx] = fan
                    }
                }
            }
        }
        
        if let pstrIdx = indexes.computed["PSTR"], sensors[pstrIdx].value > 0 {
            let now = ProcessInfo.processInfo.systemUptime
            let sinceLastRead = now - self.lastRead
            let sinceFirstRead = now - self.firstRead
            
            if let totalIdx = indexes.computed["Total System Consumption"], sinceLastRead > 0 {
                sensors[totalIdx].value += sensors[pstrIdx].value * sinceLastRead / 3600
                if let avgIdx = indexes.computed["Average System Total"], sinceFirstRead > 0 {
                    sensors[avgIdx].value = sensors[totalIdx].value * 3600 / sinceFirstRead
                }
            }
            
            self.lastRead = now
        }
        
        // cut off low dc in voltage
        if let idx = indexes.computed["VD0R"], sensors[idx].value < 0.4 {
            sensors[idx].value = 0
        }
        // cut off low dc in current
        if let idx = indexes.computed["ID0R"], sensors[idx].value < 0.05 {
            sensors[idx].value = 0
        }
        
        self.list.update { current in
            var list = current
            if list.count == sensors.count {
                // the common case: same list structure, update every value in place
                for i in list.indices {
                    list[i] = sensors[i]
                }
            } else {
                // the list changed during this read (e.g. HID sensors toggle): merge by key
                for sensor in sensors {
                    if let idx = list.firstIndex(where: { $0.key == sensor.key }) {
                        list[idx] = sensor
                    }
                }
            }
            return list
        }
        
        self.callback(self.list)
    }
    
    private func initCalculatedSensors(_ sensors: [Sensor_p]) -> [Sensor_p] {
        var list: [Sensor_p] = []
        
        var cpuSensors = sensors.filter({ $0.group == .CPU && $0.type == .temperature && $0.average }).map{ $0.value }
        var gpuSensors = sensors.filter({ $0.group == .GPU && $0.type == .temperature && $0.average }).map{ $0.value }
        
        #if arch(arm64)
        if self.HIDState {
            cpuSensors += sensors.filter({ $0.key.hasPrefix("pACC MTR Temp") || $0.key.hasPrefix("eACC MTR Temp") }).map{ $0.value }
            gpuSensors += sensors.filter({ $0.key.hasPrefix("GPU MTR Temp") }).map{ $0.value }
        }
        #endif
        
        let fanSensors = sensors.filter({ $0.type == .fan && !$0.isComputed })
        
        if !cpuSensors.isEmpty {
            let value = cpuSensors.reduce(0, +) / Double(cpuSensors.count)
            list.append(Sensor(key: "Average CPU", name: "Average CPU", value: value, group: .CPU, type: .temperature, platforms: Platform.all, isComputed: true))
            if let max = cpuSensors.max() {
                list.append(Sensor(key: "Hottest CPU", name: "Hottest CPU", value: max, group: .CPU, type: .temperature, platforms: Platform.all, isComputed: true))
            }
        }
        if !gpuSensors.isEmpty {
            let value = gpuSensors.reduce(0, +) / Double(gpuSensors.count)
            list.append(Sensor(key: "Average GPU", name: "Average GPU", value: value, group: .GPU, type: .temperature, platforms: Platform.all, isComputed: true))
            if let max = gpuSensors.max() {
                list.append(Sensor(key: "Hottest GPU", name: "Hottest GPU", value: max, group: .GPU, type: .temperature, platforms: Platform.all, isComputed: true))
            }
        }
        if !fanSensors.isEmpty && fanSensors.count > 1 {
            if let f = fanSensors.max(by: { $0.value < $1.value }) as? Fan {
                list.append(Fan(id: -1, key: "Fastest fan", name: "Fastest fan", minSpeed: f.minSpeed, maxSpeed: f.maxSpeed, value: f.value, mode: .automatic, isComputed: true))
            }
        }
        
        // Init total power since launched, only if Total Power sensor is available
        if sensors.contains(where: { $0.key == "PSTR"}) {
            list.append(Sensor(key: "Total System Consumption", name: "Total System Consumption", value: 0, group: .sensor, type: .energy, platforms: Platform.all, isComputed: true))
            list.append(Sensor(key: "Average System Total", name: "Average System Total", value: 0, group: .sensor, type: .power, platforms: Platform.all, isComputed: true))
        }
        
        return list.filter({ (s: Sensor_p) -> Bool in
            switch s.type {
            case .temperature:
                return s.value < 110 && s.value >= 0
            case .voltage:
                return s.value < 300 && s.value >= 0
            case .current:
                return s.value < 100 && s.value >= 0
            default: return true
            }
        }).sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
    
    public func unknownCallback() {
        self.unknownSensorsState = Store.shared.bool(key: "Sensors_unknown", defaultValue: false)
    }
}

// MARK: - Fans

extension SensorsReader {
    private func loadFans(_ count: Int) -> [Sensor_p] {
        debug("Found \(Int(count)) fans", log: self.log)
        
        var list: [Fan] = []
        for i in 0..<Int(count) {
            var name = SMC.shared.getStringValue("F\(i)ID")
            var mode: FanMode
            
            if name == nil && count == 2 {
                switch i {
                case 0:
                    name = localizedString("Left fan")
                case 1:
                    name = localizedString("Right fan")
                default: break
                }
            }
            
            if let md = SMC.shared.getValue(SMC.shared.fanModeKey(i)), let parsed = FanMode(rawValue: Int(md)) {
                mode = parsed.isAutomatic ? .automatic : parsed
            } else {
                mode = self.getFanMode(i)
            }
            
            list.append(Fan(
                id: i,
                key: "F\(i)Ac",
                name: name ?? "\(localizedString("Fan")) #\(i)",
                minSpeed: SMC.shared.getValue("F\(i)Mn") ?? 1,
                maxSpeed: SMC.shared.getValue("F\(i)Mx") ?? 1,
                value: SMC.shared.getValue("F\(i)Ac") ?? 0,
                mode: mode
            ))
        }
        
        return list
    }
    
    private func getFanMode(_ id: Int) -> FanMode {
        #if arch(arm64)
        // Apple Silicon: Read F%dMd directly
        // Mode values: 0 = auto, 1 = manual, 3 = system (treated as auto for UI)
        let modeValue = Int(SMC.shared.getValue(SMC.shared.fanModeKey(id)) ?? 0)
        return modeValue == 1 ? .forced : .automatic
        #else
        // Legacy Intel: Use FS! bitmask
        // Bitmask: 0 = all auto, 1 = fan 0 forced, 2 = fan 1 forced, 3 = both forced
        let fansMode: Int = Int(SMC.shared.getValue("FS! ") ?? 0)
        var mode: FanMode = .automatic
        
        if fansMode == 0 {
            mode = .automatic
        } else if fansMode == 3 {
            mode = .forced
        } else if fansMode == 1 && id == 0 {
            mode = .forced
        } else if fansMode == 2 && id == 1 {
            mode = .forced
        }
        
        return mode
        #endif
    }
}

// MARK: - HID sensors

extension SensorsReader {
    private func m1Preset(type: SensorType) -> (Int32, Int32, Int32) {
        var page: Int32 = 0
        var usage: Int32 = 0
        var eventType: Int32 = kIOHIDEventTypeTemperature
        
        //  usagePage:
        //    kHIDPage_AppleVendor                        = 0xff00,
        //    kHIDPage_AppleVendorTemperatureSensor       = 0xff05,
        //    kHIDPage_AppleVendorPowerSensor             = 0xff08,
        //    kHIDPage_GenericDesktop
        //
        //  usage:
        //    kHIDUsage_AppleVendor_TemperatureSensor     = 0x0005,
        //    kHIDUsage_AppleVendorPowerSensor_Current    = 0x0002,
        //    kHIDUsage_AppleVendorPowerSensor_Voltage    = 0x0003,
        //    kHIDUsage_GD_Keyboard
        //
        
        switch type {
        case .temperature:
            page = 0xff00
            usage = 0x0005
            eventType = kIOHIDEventTypeTemperature
        case .current:
            page = 0xff08
            usage = 0x0002
            eventType = kIOHIDEventTypePower
        case .voltage:
            page = 0xff08
            usage = 0x0003
            eventType = kIOHIDEventTypePower
        case .power, .energy, .fan: break
        }
        
        return (page, usage, eventType)
    }
    
    private func initHIDSensors() -> [Sensor] {
        var list: [Sensor] = []
        
        for typ in SensorsReader.HIDtypes {
            let (page, usage, type) = self.m1Preset(type: typ)
            if let sensors = AppleSiliconSensors(page, usage, type) {
                sensors.forEach { (key, value) in
                    guard let key = key as? String, let value = value as? Double else {
                        return
                    }
                    var name: String = key
                    
                    HIDSensorsList.forEach { (s: Sensor) in
                        if s.key.contains("%") {
                            var index = 1
                            for i in 0..<64 {
                                if s.key.replacingOccurrences(of: "%", with: "\(i)") == key {
                                    name = s.name.replacingOccurrences(of: "%", with: "\(index)")
                                }
                                index += 1
                            }
                        } else if s.key == key {
                            name = s.name
                        }
                    }
                    
                    list.append(Sensor(
                        key: key,
                        name: name,
                        value: value,
                        group: .hid,
                        type: typ,
                        platforms: Platform.all
                    ))
                }
            }
        }
        
        let socSensors = list.filter({ $0.key.hasPrefix("SOC MTR Temp") }).map{ $0.value }
        if !socSensors.isEmpty {
            let value = socSensors.reduce(0, +) / Double(socSensors.count)
            list.append(Sensor(key: "Average SOC", name: "Average SOC", value: value, group: .hid, type: .temperature, platforms: Platform.all))
            if let max = socSensors.max() {
                list.append(Sensor(key: "Hottest SOC", name: "Hottest SOC", value: max, group: .hid, type: .temperature, platforms: Platform.all))
            }
        }
        
        return list.filter({ (s: Sensor_p) -> Bool in
            switch s.type {
            case .temperature:
                return s.value < 110 && s.value >= 0
            case .voltage:
                return s.value < 300 && s.value >= 0
            case .current:
                return s.value < 100 && s.value >= 0
            default: return true
            }
        }).sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
    
    public func HIDCallback() {
        if self.HIDState {
            let hidSensors = self.initHIDSensors()
            self.list.update { current in
                current + hidSensors.filter({ (s: Sensor_p) in !current.contains(where: { $0.key == s.key }) })
            }
        } else {
            self.resetHIDSensors()
            self.list.update { current in
                current.filter({ $0.group != .hid })
            }
        }
        self.rebuildIndexes()
    }
}

// MARK: - Apple Silicon power sensors

extension SensorsReader {
    private func getChannels() -> CFMutableDictionary? {
        let channelNames: [(String, String?)] = [("Energy Model", nil)]
        
        var channels: [CFDictionary] = []
        for (gname, sname) in channelNames {
            let channel = IOReportCopyChannelsInGroup(gname as CFString?, sname as CFString?, 0, 0, 0)
            guard let channel = channel?.takeRetainedValue() else { continue }
            channels.append(channel)
        }
        
        guard let chan = channels.first else { return nil }
        for i in 1..<channels.count {
            IOReportMergeChannels(chan, channels[i], nil)
        }
        
        let size = CFDictionaryGetCount(chan)
        guard let channel = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, chan),
              let list = (channel as NSDictionary)["IOReportChannels"] as? [CFDictionary] else {
            return nil
        }
        
        // subscribe only to the channels read in IOSensors(): the group has hundreds of channels
        // (331 on M-series) and every one of them would be sampled and bridged on each read
        let used = list.filter { item in
            guard let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? else { return false }
            return SensorsReader.powerChannel(name) != nil
        }
        if !used.isEmpty {
            (channel as NSMutableDictionary)["IOReportChannels"] = used as NSArray
        }
        
        return channel
    }
    
    private enum PowerChannel {
        case CPU, GPU, ANE, RAM, PCI
    }
    
    private static func powerChannel(_ name: String) -> PowerChannel? {
        if name.hasSuffix("CPU Energy") {
            return .CPU
        } else if name.hasSuffix("GPU Energy") {
            return .GPU
        } else if name.starts(with: "ANE") {
            return .ANE
        } else if name.starts(with: "DRAM") {
            return .RAM
        } else if name.starts(with: "PCI") && name.hasSuffix("Energy") {
            return .PCI
        }
        return nil
    }
    
    private func initIOSensors() -> [Sensor] {
        guard let (cpu, gpu, ane, ram, pci) = self.IOSensors() else { return [] }
        return [
            Sensor(key: "CPU Power", name: "CPU Power", value: cpu, group: .CPU, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "GPU Power", name: "GPU Power", value: gpu, group: .GPU, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "ANE Power", name: "ANE Power", value: ane, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "RAM Power", name: "RAM Power", value: ram, group: .system, type: .power, platforms: Platform.apple, isComputed: true),
            Sensor(key: "PCI Power", name: "PCI Power", value: pci, group: .system, type: .power, platforms: Platform.apple, isComputed: true)
        ]
    }
    
    private static func appleSiliconPower(currentEnergy: Double, previousEnergy: Double, elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        return (currentEnergy - previousEnergy) / elapsed
    }

    private func IOSensors() -> (Double, Double, Double, Double, Double)? {
        guard let reportSample = IOReportCreateSamples(self.subscription, self.channels, nil)?.takeRetainedValue(),
              let dict = reportSample as? [String: Any],
              let channelsList = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        let items = channelsList as CFArray
        let now = Date()
        
        let prevCPU = self.powers.CPU
        let prevGPU = self.powers.GPU
        let prevANE = self.powers.ANE
        let prevRAM = self.powers.RAM
        let prevPCI = self.powers.PCI
        
        for i in 0..<CFArrayGetCount(items) {
            let dict = CFArrayGetValueAtIndex(items, i)
            let item = unsafeBitCast(dict, to: CFDictionary.self)
            
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String,
                  let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String else { continue }
            
            let value = Double(IOReportSimpleGetIntegerValue(item, 0))
            
            switch Self.powerChannel(channel) {
            case .CPU: self.powers.CPU = value.power(unit)
            case .GPU: self.powers.GPU = value.power(unit)
            case .ANE: self.powers.ANE = value.power(unit)
            case .RAM: self.powers.RAM = value.power(unit)
            case .PCI: self.powers.PCI = value.power(unit)
            case .none: break
            }
        }
        
        guard let lastIOSensorsRead = self.lastIOSensorsRead else {
            self.lastIOSensorsRead = now
            return (0, 0, 0, 0, 0)
        }
        let elapsed = now.timeIntervalSince(lastIOSensorsRead)
        defer { self.lastIOSensorsRead = now }
        return (
            Self.appleSiliconPower(currentEnergy: self.powers.CPU, previousEnergy: prevCPU, elapsed: elapsed),
            Self.appleSiliconPower(currentEnergy: self.powers.GPU, previousEnergy: prevGPU, elapsed: elapsed),
            Self.appleSiliconPower(currentEnergy: self.powers.ANE, previousEnergy: prevANE, elapsed: elapsed),
            Self.appleSiliconPower(currentEnergy: self.powers.RAM, previousEnergy: prevRAM, elapsed: elapsed),
            Self.appleSiliconPower(currentEnergy: self.powers.PCI, previousEnergy: prevPCI, elapsed: elapsed)
        )
    }
}
