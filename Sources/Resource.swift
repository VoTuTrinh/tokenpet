// Self-measurement: TokenPet must stay cheap. Used by --bench and the About section.
import Darwin
import Foundation

/// Physical footprint in MB (what Activity Monitor's "Memory" column shows).
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

/// Returns freed malloc pages to the system after a big one-off job (the first scan).
func trimMemory() { malloc_zone_pressure_relief(nil, 0) }
