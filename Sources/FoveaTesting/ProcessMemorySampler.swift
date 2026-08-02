import Foundation

#if canImport(Darwin)
    import Darwin
#endif

package enum ProcessMemorySampler {
    package static func physicalFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return info.phys_footprint
        #else
            return nil
        #endif
    }
}
