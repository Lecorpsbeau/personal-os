import Darwin
import Foundation
import MachO

struct CPUTicks: Equatable, Sendable {
    let total: UInt64
    let idle: UInt64
}

final class CPUUsageCalculator {

    private let lock = NSLock()
    private var previousTicks: CPUTicks?

    var hasBaseline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return previousTicks != nil
    }

    @discardableResult
    func update(with ticks: CPUTicks) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let previous = previousTicks
        previousTicks = ticks

        guard let previous else {
            // The first observation establishes the interval baseline.
            return 0
        }

        // A counter reset invalidates the interval. Keep the new reading as
        // the baseline and report no usage rather than producing a negative
        // or nonsensical percentage.
        guard ticks.total >= previous.total,
              ticks.idle >= previous.idle else {
            return 0
        }

        let totalDelta = ticks.total - previous.total
        guard totalDelta > 0 else {
            return 0
        }

        let idleDelta = ticks.idle - previous.idle
        let busyDelta = totalDelta >= idleDelta
            ? totalDelta - idleDelta
            : 0

        return Double(busyDelta) / Double(totalDelta) * 100
    }

    func reset() {
        lock.lock()
        previousTicks = nil
        lock.unlock()
    }
}

struct MachMemoryRegion: Equatable {

    let address: vm_address_t
    let size: vm_size_t

    init(address: vm_address_t, integerCount: mach_msg_type_number_t) {
        self.address = address
        self.size = vm_size_t(integerCount) * vm_size_t(MemoryLayout<integer_t>.size)
    }

    @discardableResult
    func deallocate(
        using deallocator: (vm_address_t, vm_size_t) -> kern_return_t
    ) -> kern_return_t {
        deallocator(address, size)
    }
}

// CPUCollector is safe to share because its only mutable state is protected
// by CPUUsageCalculator's lock.
final class CPUCollector: @unchecked Sendable {

    private let calculator = CPUUsageCalculator()

    func sample() -> Double {
        guard let ticks = readCPUTicks() else {
            // Do not bridge a failed collection over an unknown interval.
            calculator.reset()
            return 0
        }

        return calculator.update(with: ticks)
    }

    private func readCPUTicks() -> CPUTicks? {
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo else {
            return nil
        }

        let region = MachMemoryRegion(
            address: vm_address_t(UInt(bitPattern: cpuInfo)),
            integerCount: numCPUInfo
        )

        defer {
            // host_processor_info allocates this region in the caller's
            // address space. Mach memory must be returned with
            // vm_deallocate, not free().
            _ = region.deallocate { address, size in
                vm_deallocate(mach_task_self_, address, size)
            }
        }

        let processorCount = Int(numCPUs)
        let integersPerProcessor =
            MemoryLayout<processor_cpu_load_info>.size /
            MemoryLayout<integer_t>.size

        guard processorCount > 0,
              Int(numCPUInfo) >= processorCount * integersPerProcessor else {
            return nil
        }

        let cpuLoad = cpuInfo.withMemoryRebound(
            to: processor_cpu_load_info.self,
            capacity: processorCount
        ) { pointer in
            Array(
                UnsafeBufferPointer(
                    start: pointer,
                    count: processorCount
                )
            )
        }

        var total: UInt64 = 0
        var idle: UInt64 = 0

        for cpu in cpuLoad {
            total += UInt64(cpu.cpu_ticks.0)
            total += UInt64(cpu.cpu_ticks.1)
            total += UInt64(cpu.cpu_ticks.2)
            total += UInt64(cpu.cpu_ticks.3)
            idle += UInt64(cpu.cpu_ticks.2)
        }

        return CPUTicks(total: total, idle: idle)
    }
}
