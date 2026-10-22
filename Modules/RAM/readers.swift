//
//  readers.swift
//  Memory
//
//  Created by Serhiy Mytrovtsiy on 12/04/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

internal class UsageReader: Reader<RAM_Usage> {
    public var totalSize: Double = 0
    
    public override func setup() {
        var stats = host_basic_info()
        var count = UInt32(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(machHostPort, HOST_BASIC_INFO, $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            self.totalSize = Double(stats.max_mem)
            return
        }
        
        self.totalSize = 0
        error("host_info(): \(String(cString: mach_error_string(kerr), encoding: String.Encoding.ascii) ?? "unknown error")", log: self.log)
    }
    
    public override func read() {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.offset(of: \.swapped_count)! / MemoryLayout<integer_t>.size)
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let active = Double(stats.active_count) * Double(vm_page_size)
            let speculative = Double(stats.speculative_count) * Double(vm_page_size)
            let inactive = Double(stats.inactive_count) * Double(vm_page_size)
            let wired = Double(stats.wire_count) * Double(vm_page_size)
            let compressed = Double(stats.compressor_page_count) * Double(vm_page_size)
            let purgeable = Double(stats.purgeable_count) * Double(vm_page_size)
            let external = Double(stats.external_page_count) * Double(vm_page_size)
            let swapins = Int64(stats.swapins)
            let swapouts = Int64(stats.swapouts)
            
            let used = active + inactive + speculative + wired + compressed - purgeable - external
            let free = self.totalSize - used
            
            var intSize: size_t = MemoryLayout<uint>.size
            var pressureLevel: Int = 0
            sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &intSize, nil, 0)
            
            var pressureValue: RAMPressure
            switch pressureLevel {
            case 2: pressureValue = .warning
            case 4: pressureValue = .critical
            default: pressureValue = .normal
            }
            
            var stringSize: size_t = MemoryLayout<xsw_usage>.size
            var swap: xsw_usage = xsw_usage()
            sysctlbyname("vm.swapusage", &swap, &stringSize, nil, 0)
            
            self.callback(RAM_Usage(
                total: self.totalSize,
                used: used,
                free: free,
                
                active: active,
                inactive: inactive,
                wired: wired,
                compressed: compressed,
                
                app: used - wired - compressed,
                cache: purgeable + external,
                
                swap: Swap(
                    total: Double(swap.xsu_total),
                    used: Double(swap.xsu_used),
                    free: Double(swap.xsu_avail)
                ),
                pressure: Pressure(level: pressureLevel, value: pressureValue),
                
                swapins: swapins,
                swapouts: swapouts
            ))
            return
        }
        
        error("host_statistics64(): \(String(cString: mach_error_string(result), encoding: String.Encoding.ascii) ?? "unknown error")", log: self.log)
    }
}

public class ProcessReader: Reader<[TopProcess]> {
    private let title: String = "RAM"
    
    private var numberOfProcesses: Int {
        get { Store.shared.int(key: "\(self.title)_processes", defaultValue: 8) }
    }
    
    private var combinedProcesses: Bool{
        get { Store.shared.bool(key: "\(self.title)_combinedProcesses", defaultValue: false) }
    }
    
    private var legacyReader: Bool {
        get { Store.shared.bool(key: "\(self.title)_processesLegacyReader", defaultValue: false) }
    }
    
    private typealias dynGetResponsiblePidFuncType = @convention(c) (CInt) -> CInt
    
    private var nameCache: [Int32: (ts: TimeInterval, command: String)] = [:]
    
    // processes of other users (root daemons, WindowServer, kernel_task...) cannot be read with
    // libproc without privileges, their memory comes from the setuid top, refreshed less often
    private var privileged: (ts: DispatchTime, combined: Bool, list: [TopProcess])? = nil
    private let privilegedInterval: Double = 5
    
    public override func setup() {
        self.popup = true
        self.preview = true
        self.setInterval(Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: 1))
    }
    
    public override func start() {
        self.privileged = nil
        super.start()
    }
    
    public override func read() {
        if self.numberOfProcesses == 0 {
            return
        }
        
        // legacy reader (settings): top for all the processes on every read. otherwise in-process
        // sampling via libproc (no fork/exec of top) merged with top for the processes libproc
        // cannot read; falls back to top on failure
        let processes = self.legacyReader ? self.readWithTop() : (self.readLocalProcesses() ?? self.readWithTop())
        
        if !self.combinedProcesses {
            self.callback(processes)
            return
        }
        
        var processGroups: [String: [TopProcess]] = [:]
        for process in processes {
            let responsiblePid = ProcessReader.getResponsiblePid(process.pid)
            let groupKey = "\(responsiblePid)"
            
            if processGroups[groupKey] != nil {
                processGroups[groupKey]!.append(process)
            } else {
                processGroups[groupKey] = [process]
            }
        }
        
        var result: [TopProcess] = []
        for (_, processes) in processGroups {
            let totalUsage = processes.reduce(0) { $0 + $1.usage }
            let firstProcess = processes.first!
            let name: String
            
            if let app = NSRunningApplication(processIdentifier: pid_t(ProcessReader.getResponsiblePid(firstProcess.pid))),
               let appName = app.localizedName {
                name = appName
            } else {
                name = firstProcess.name
            }
            
            result.append(TopProcess(
                pid: ProcessReader.getResponsiblePid(firstProcess.pid),
                name: name,
                usage: totalUsage
            ))
        }
        
        result.sort { $0.usage > $1.usage }
        self.callback(Array(result.prefix(self.numberOfProcesses)))
    }
    
    private func readLocalProcesses() -> [TopProcess]? {
        guard let pids = listAllPids() else { return nil }
        
        var list: [(pid: Int32, usage: Double, name: String?)] = []
        list.reserveCapacity(pids.count)
        var inaccessible: Set<Int32> = []
        for pid in pids {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?.self), capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result != -1 else {
                inaccessible.insert(pid)
                continue
            }
            // physical memory footprint, the value shown by top's mem column
            list.append((pid, Double(usage.ri_phys_footprint), nil))
        }
        guard !list.isEmpty else { return nil }
        
        for process in self.privilegedProcesses(inaccessible) {
            list.append((Int32(process.pid), process.usage, process.name))
        }
        list.sort { $0.usage > $1.usage }
        
        // in combined mode all processes are needed for the grouping by responsible pid
        let limit = self.combinedProcesses ? list.count : self.numberOfProcesses
        var processes: [TopProcess] = []
        processes.reserveCapacity(min(limit, list.count))
        for item in list.prefix(limit) {
            processes.append(TopProcess(pid: Int(item.pid), name: item.name ?? self.processName(item.pid), usage: item.usage))
        }
        return processes
    }
    
    private func privilegedProcesses(_ pids: Set<Int32>) -> [TopProcess] {
        guard !pids.isEmpty else { return [] }
        let now = DispatchTime.now()
        let combined = self.combinedProcesses
        if let cached = self.privileged, cached.combined == combined,
           Double(now.uptimeNanoseconds - cached.ts.uptimeNanoseconds) / 1_000_000_000 < self.privilegedInterval {
            return cached.list.filter { pids.contains(Int32($0.pid)) }
        }
        // top returns the processes of all users, the ones libproc could read are dropped
        let list = self.readWithTop()
        self.privileged = (now, combined, list)
        return list.filter { pids.contains(Int32($0.pid)) }
    }
    
    private func processName(_ pid: Int32) -> String {
        let now = Date().timeIntervalSince1970
        var command: String
        if let cached = self.nameCache[pid], now - cached.ts < 30 {
            command = cached.command
        } else {
            command = processDisplayName(pid) ?? "\(pid)"
            self.nameCache[pid] = (now, command)
            if self.nameCache.count > 2048 {
                self.nameCache = [:]
            }
        }
        
        var name: String = command
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            name = n
        }
        if command.contains("com.apple.Virtua") && name.contains("Docker") {
            name = "Docker"
        }
        
        return name
    }
    
    private func readWithTop() -> [TopProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        if self.combinedProcesses {
            task.arguments = ["-l", "1", "-o", "mem", "-stats", "pid,command,mem"]
        } else {
            task.arguments = ["-l", "1", "-o", "mem", "-n", "\(self.numberOfProcesses)", "-stats", "pid,command,mem"]
        }
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        defer {
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
        }
        
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        do {
            try task.run()
        } catch let err {
            error("top(): \(err.localizedDescription)", log: self.log)
            return []
        }
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)
        _ = String(data: errorData, encoding: .utf8)
        guard let output, !output.isEmpty else { return [] }
        
        var processes: [TopProcess] = []
        output.enumerateLines { (line, _) in
            if line.matches("^\\d+\\** +.* +\\d+[A-Z]*\\+?\\-? *$") {
                processes.append(ProcessReader.parseProcess(line))
            }
        }
        
        return processes
    }
    
    private static let dynGetResponsiblePidFunc: UnsafeMutableRawPointer? = {
        let result = dlsym(UnsafeMutableRawPointer(bitPattern: -1), "responsibility_get_pid_responsible_for_pid")
        if result == nil {
            error("Error loading responsibility_get_pid_responsible_for_pid")
        }
        return result
    }()
    
    static func getResponsiblePid(_ childPid: Int) -> Int {
        guard ProcessReader.dynGetResponsiblePidFunc != nil else {
            return childPid
        }
        let responsiblePid = unsafeBitCast(ProcessReader.dynGetResponsiblePidFunc, to: dynGetResponsiblePidFuncType.self)(CInt(childPid))
        guard responsiblePid != -1 else {
            return childPid
        }
        return Int(responsiblePid)
    }
    
    static public func parseProcess(_ raw: String) -> TopProcess {
        var str = raw.trimmingCharacters(in: .whitespaces)
        let pidString = str.find(pattern: "^\\d+")
        
        if let range = str.range(of: pidString) {
            str = str.replacingCharacters(in: range, with: "")
        }
        
        var arr = str.split(separator: " ")
        if arr.first == "*" {
            arr.removeFirst()
        }
        
        var usageString = str.suffix(6)
        if let lastElement = arr.last {
            usageString = lastElement
            arr.removeLast()
        }
        
        var command = arr.joined(separator: " ")
            .replacingOccurrences(of: pidString, with: "")
            .trimmingCharacters(in: .whitespaces)
        
        command = command.removedRegexMatches(pattern: " (\\+|\\-)*$", replaceWith: "")
        
        let pid = Int(pidString.filter("01234567890.".contains)) ?? 0
        var usage = Double(usageString.filter("01234567890.".contains)) ?? 0
        if usageString.last == "G" {
            usage *= 1024 // apply gigabyte multiplier
        } else if usageString.last == "K" {
            usage /= 1024 // apply kilobyte divider
        } else if usageString.last == "M" && usageString.count == 5 {
            usage /= 1024
            usage *= 1000
        }
        
        var name: String = command
        if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName {
            name = n
        }
        
        if command.contains("com.apple.Virtua") && name.contains("Docker") {
            name = "Docker"
        }
        
        return TopProcess(pid: pid, name: name, usage: usage * Double(1000 * 1000))
    }
}
