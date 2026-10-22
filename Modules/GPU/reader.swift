//
//  reader.swift
//  GPU
//
//  Created by Serhiy Mytrovtsiy on 17/08/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

public struct device {
    public let vendor: String?
    public let model: String
    public let pci: String
    public var used: Bool
}

let vendors: [Data: String] = [
    Data.init([0x86, 0x80, 0x00, 0x00]): "Intel",
    Data.init([0x02, 0x10, 0x00, 0x00]): "AMD"
]

private func maxANEPower(for platform: Platform?) -> Double {
    switch platform {
    case .m1, .m1Pro, .m1Max:       return 2.0
    case .m1Ultra:                  return 4.0
    case .m2, .m2Pro, .m2Max:       return 2.5
    case .m2Ultra:                  return 5.0
    case .m3, .m3Pro, .m3Max:       return 3.0
    case .m3Ultra:                  return 6.0
    case .m4, .m4Pro, .m4Max:       return 6.0
    case .m5, .m5Pro, .m5Max:       return 8.0
    case .m5Ultra:                  return 16.0
    case .m6, .m6Pro, .m6Max:       return 16.0
    default:                        return 8.0
    }
}

internal class InfoReader: Reader<GPUs> {
    private var gpus: GPUs = GPUs()
    private var displays: [gpu_s] = []
    private var devices: [device] = []

    private var aneChannels: CFMutableDictionary? = nil
    private var aneSubscription: IOReportSubscriptionRef? = nil
    private var previousANEEnergy: Double = 0
    private var previousANERead: Date? = nil
    private var aneMaxPower: Double = 8.0

    private var framesChannels: CFMutableDictionary? = nil
    private var framesSubscription: IOReportSubscriptionRef? = nil
    private var previousFramesCount: Int64 = 0
    private var previousFramesTime: CFAbsoluteTime = 0
    
    public override func setup() {
        if let list = SystemKit.shared.device.info.gpu {
            self.displays = list
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(self.resetAccelerators), name: NSWorkspace.didWakeNotification, object: nil)
        
        guard let PCIdevices = fetchIOService("IOPCIDevice") else {
            return
        }
        let devices = PCIdevices.filter{ $0.object(forKey: "IOName") as? String == "display" }
        
        #if arch(arm64)
        self.aneMaxPower = maxANEPower(for: SystemKit.shared.device.platform)
        self.setupANE()
        self.setupFrames()
        #endif
        
        devices.forEach { (dict: NSDictionary) in
            guard let deviceID = dict["device-id"] as? Data, let vendorID = dict["vendor-id"] as? Data else {
                error("device-id or vendor-id not found", log: self.log)
                return
            }
            let pci = "0x" + Data([deviceID[1], deviceID[0], vendorID[1], vendorID[0]]).map { String(format: "%02hhX", $0) }.joined().lowercased()
            
            guard let modelData = dict["model"] as? Data, let modelName = String(data: modelData, encoding: .ascii) else {
                error("GPU model not found", log: self.log)
                return
            }
            let model = modelName.replacingOccurrences(of: "\0", with: "")
            
            var vendor: String? = nil
            if let v = vendors.first(where: { $0.key == vendorID }) {
                vendor = v.value
            }
            
            self.devices.append(device(
                vendor: vendor,
                model: model,
                pci: pci,
                used: false
            ))
        }
    }
    
    private struct acceleratorInfo {
        let ioClass: String
        let stats: [String: Any]
        let pciMatch: String
        let agcInfo: [String: Int]?
    }
    
    private struct acceleratorService {
        let entry: io_registry_entry_t
        let ioClass: String
        let pciMatch: String
    }
    
    // retained IOAccelerator services with their static properties, so the registry matching
    // does not run on every read. re-discovered periodically, on wake and when a cached
    // service stops serving stats (e.g. eGPU unplugged)
    private var services: [acceleratorService] = []
    private var servicesDiscoveredAt: TimeInterval? = nil
    private let servicesRefreshInterval: TimeInterval = 60
    private let servicesLock = NSLock()
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        self.releaseAccelerators()
    }
    
    @objc private func resetAccelerators() {
        self.servicesLock.lock()
        defer { self.servicesLock.unlock() }
        self.servicesDiscoveredAt = nil
    }
    
    private func releaseAccelerators() {
        self.services.forEach { IOObjectRelease($0.entry) }
        self.services.removeAll()
    }
    
    private func discoverAccelerators() {
        self.releaseAccelerators()
        self.servicesDiscoveredAt = ProcessInfo.processInfo.systemUptime
        
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOAcceleratorClassName), &iterator) == kIOReturnSuccess else {
            return
        }
        defer { IOObjectRelease(iterator) }
        
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            let entry = obj
            obj = IOIteratorNext(iterator)
            
            guard let ioClass = getIOProperty(entry, "IOClass") as? String else {
                error("IOClass not found", log: self.log)
                IOObjectRelease(entry)
                continue
            }
            
            let pciMatch = ((getIOProperty(entry, "IOPCIMatch") as? String) ?? (getIOProperty(entry, "IOPCIPrimaryMatch") as? String) ?? "").lowercased()
            // ownership of the retained entry moves into the cache
            self.services.append(acceleratorService(entry: entry, ioClass: ioClass, pciMatch: pciMatch))
        }
    }
    
    /// Fetches only the registry keys the reader needs from every IOAccelerator, instead of
    /// copying each accelerator's entire property dictionary on every read.
    private func fetchAccelerators() -> [acceleratorInfo]? {
        self.servicesLock.lock()
        defer { self.servicesLock.unlock() }
        
        if self.services.isEmpty || self.servicesDiscoveredAt.map({ ProcessInfo.processInfo.systemUptime - $0 >= self.servicesRefreshInterval }) ?? true {
            self.discoverAccelerators()
        }
        
        var accelerators: [acceleratorInfo] = []
        var stale = false
        for service in self.services {
            guard let stats = getIOProperty(service.entry, "PerformanceStatistics") as? [String: Any] else {
                error("PerformanceStatistics not found", log: self.log)
                stale = true
                continue
            }
            
            accelerators.append(acceleratorInfo(
                ioClass: service.ioClass,
                stats: stats,
                pciMatch: service.pciMatch,
                agcInfo: getIOProperty(service.entry, "AGCInfo") as? [String: Int]
            ))
        }
        if stale {
            self.servicesDiscoveredAt = nil
        }
        
        return accelerators.isEmpty ? nil : accelerators
    }
    
    private func getIOProperty(_ entry: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    
    public override func read() {
        guard let accelerators = self.fetchAccelerators() else {
            return
        }
        var devices = self.devices
        
        for (index, accelerator) in accelerators.enumerated() {
            let IOClass = accelerator.ioClass
            
            var id: String = ""
            var vendor: String? = nil
            var model: String = ""
            var cores: Int? = nil
            
            for (i, device) in devices.enumerated() {
                if accelerator.pciMatch.range(of: device.pci) != nil && !device.used {
                    model = device.model
                    vendor = device.vendor
                    id = "\(model) #\(index)"
                    devices[i].used = true
                    break
                }
            }
            
            let ioClass = IOClass.lowercased()
            var predictModel = ""
            var type: GPU_types = .unknown
            
            let utilization: Int? = accelerator.stats["Device Utilization %"] as? Int ?? accelerator.stats["GPU Activity(%)"] as? Int ?? nil
            let renderUtilization: Int? = accelerator.stats["Renderer Utilization %"] as? Int ?? nil
            let tilerUtilization: Int? = accelerator.stats["Tiler Utilization %"] as? Int ?? nil
            var temperature: Int? = accelerator.stats["Temperature(C)"] as? Int ?? nil
            let fanSpeed: Int? = accelerator.stats["Fan Speed(%)"] as? Int ?? nil
            let coreClock: Int? = accelerator.stats["Core Clock(MHz)"] as? Int ?? nil
            let memoryClock: Int? = accelerator.stats["Memory Clock(MHz)"] as? Int ?? nil
            
            if ioClass == "nvaccelerator" || ioClass.contains("nvidia") { // nvidia
                predictModel = "Nvidia Graphics"
                type = .discrete
            } else if ioClass.contains("amd") { // amd
                predictModel = "AMD Graphics"
                type = .discrete
                
                if temperature == nil || temperature == 0 {
                    if let tmp = SMC.shared.getValue("TGDD"), tmp != 128 {
                        temperature = Int(tmp)
                    }
                }
            } else if ioClass.contains("intel") { // intel
                predictModel = "Intel Graphics"
                type = .integrated
                
                if temperature == nil || temperature == 0 {
                    if let tmp = SMC.shared.getValue("TCGC"), tmp != 128 {
                        temperature = Int(tmp)
                    }
                }
            } else if ioClass.contains("agx") { // apple
                predictModel = accelerator.stats["model"] as? String ?? "Apple Graphics"
                if let display = self.displays.first(where: { $0.vendor == "sppci_vendor_Apple" }) {
                    if let name = display.name {
                        predictModel = name
                    }
                    if let num = display.cores {
                        cores = num
                    }
                }
                type = .integrated
            } else {
                predictModel = "Unknown"
                type = .unknown
            }
            
            if model == "" {
                model = predictModel
            }
            if let v = vendor {
                model = model.removedRegexMatches(pattern: v, replaceWith: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            if self.gpus.list.first(where: { $0.id == id }) == nil {
                self.gpus.list.append(GPU_Info(
                    id: id,
                    type: type.rawValue,
                    IOClass: IOClass,
                    vendor: vendor,
                    model: model,
                    cores: cores
                ))
            }
            guard let idx = self.gpus.list.firstIndex(where: { $0.id == id }) else {
                return
            }
            
            if let agcInfo = accelerator.agcInfo, let state = agcInfo["poweredOffByAGC"] {
                self.gpus.list[idx].state = state == 0
            }
            
            if var value = utilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].utilization = Double(value)/100
            }
            if var value = renderUtilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].renderUtilization = Double(value)/100
            }
            if var value = tilerUtilization {
                if value > 100 {
                    value = 100
                }
                self.gpus.list[idx].tilerUtilization = Double(value)/100
            }
            if let value = temperature {
                self.gpus.list[idx].temperature = Double(value)
            }
            if let value = fanSpeed {
                self.gpus.list[idx].fanSpeed = value
            }
            if let value = coreClock {
                self.gpus.list[idx].coreClock = value
            }
            if let value = memoryClock {
                self.gpus.list[idx].memoryClock = value
            }
        }
        
        #if arch(arm64)
        let anePower = self.readANEPower()
        let aneUtil = anePower.map { min(1.0, max(0.0, $0 / self.aneMaxPower)) }
        let fpsValue = self.readFrames()
        for i in self.gpus.list.indices where self.gpus.list[i].IOClass.lowercased().contains("agx") {
            self.gpus.list[i].aneUtilization = aneUtil ?? 0
            self.gpus.list[i].fps = fpsValue
        }
        #endif
        
        self.gpus.list.sort{ !$0.state && $1.state }
        self.callback(self.gpus)
    }
    
    // MARK: - FPS
    
    private func setupFrames() {
        let groups = ["DCP", "DCP0", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"]
        var merged: CFMutableDictionary? = nil
        
        for group in groups {
            guard let channel = IOReportCopyChannelsInGroup(group as CFString, "swap" as CFString, 0, 0, 0)?.takeRetainedValue() else { continue }
            if merged == nil {
                merged = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channel)
            } else {
                IOReportMergeChannels(merged, channel, nil)
            }
        }
        
        guard let merged, let dict = merged as? [String: Any], dict["IOReportChannels"] != nil else { return }
        
        self.framesChannels = merged
        var sub: Unmanaged<CFMutableDictionary>?
        self.framesSubscription = IOReportCreateSubscription(nil, merged, &sub, 0, nil)
        sub?.release()
    }
    
    private func readFrames() -> Double? {
        guard let subscription = self.framesSubscription,
              let channels = self.framesChannels,
              let sample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = sample as? [String: Any],
              let channelsList = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        let items = channelsList as CFArray
        
        var total: Int64 = 0
        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group.hasPrefix("DCP"),
                  let sub = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as? String,
                  sub == "swap" else { continue }
            total += IOReportSimpleGetIntegerValue(item, 0)
        }
        
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            self.previousFramesCount = total
            self.previousFramesTime = now
        }
        
        guard self.previousFramesTime != 0 else { return nil }
        let elapsed = now - self.previousFramesTime
        guard elapsed > 0 else { return nil }
        let delta = total - self.previousFramesCount
        guard delta >= 0 else { return nil }
        return Double(delta) / elapsed
    }
    
    // MARK: - ANE power
    
    private func setupANE() {
        guard let channel = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        
        let size = CFDictionaryGetCount(channel)
        guard let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, channel),
              let list = (mutable as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return }
        
        // subscribe only to the ANE channels: the group has hundreds of channels (331 on M-series)
        // and every one of them would be sampled and bridged on each read otherwise
        let ane = list.filter { item in
            (IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String?)?.starts(with: "ANE") ?? false
        }
        if !ane.isEmpty {
            (mutable as NSMutableDictionary)["IOReportChannels"] = ane as NSArray
        }
        
        self.aneChannels = mutable
        var sub: Unmanaged<CFMutableDictionary>?
        self.aneSubscription = IOReportCreateSubscription(nil, mutable, &sub, 0, nil)
        sub?.release()
    }
    
    private func readANEPower() -> Double? {
        guard let subscription = self.aneSubscription,
              let channels = self.aneChannels,
              let reportSample = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue(),
              let dict = reportSample as? [String: Any],
              let channelsList = dict["IOReportChannels"] as? NSArray else {
            return nil
        }
        let items = channelsList as CFArray
        
        var currentEnergy: Double = 0
        var found = false
        
        for i in 0..<CFArrayGetCount(items) {
            let item = unsafeBitCast(CFArrayGetValueAtIndex(items, i), to: CFDictionary.self)
            
            guard let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as? String,
                  group == "Energy Model",
                  let channel = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as? String,
                  channel.starts(with: "ANE") else { continue }
            
            let raw = Double(IOReportSimpleGetIntegerValue(item, 0))
            let unit = (IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            
            let joules: Double
            switch unit.lowercased() {
            case "mj":       joules = raw / 1e3
            case "uj", "µj": joules = raw / 1e6
            case "nj":       joules = raw / 1e9
            case "pj":       joules = raw / 1e12
            default:         joules = raw / 1e9
            }
            
            currentEnergy += joules
            found = true
        }
        
        guard found else { return nil }
        
        let now = Date()
        defer {
            self.previousANEEnergy = currentEnergy
            self.previousANERead = now
        }
        
        guard let previousRead = self.previousANERead else { return 0 }
        let elapsed = now.timeIntervalSince(previousRead)
        guard elapsed > 0 else { return 0 }
        return (currentEnergy - self.previousANEEnergy) / elapsed
    }
}
