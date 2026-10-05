import Darwin
import Foundation
import MachO

/// A stack of every thread in this process, taken from inside it (#237).
///
/// The window is sandboxed, so it cannot run `sample` or `spindump` against itself, and
/// under heavy load the system's own hang reporter does not sample at all. So the stacks
/// are read with Mach: each thread is suspended in turn, its registers read and its
/// frame-pointer chain walked, and it is resumed. Nothing between the suspend and the
/// resume allocates or takes a lock, because the suspended thread may hold the one it
/// would need; every read of its stack goes through `vm_read_overwrite`, which fails
/// rather than faults on a bad pointer. Addresses are named with `dladdr` only once every
/// thread is running again.
public enum ThreadSampler {
    public struct Stack: Sendable {
        public let name: String
        /// Return addresses, innermost first. The first is the program counter.
        public let frames: [UInt]
    }

    public static let maxFrames = 256

    /// The thread this is called on, as a port to sample later. Kept for the life of the
    /// process: it is never deallocated.
    public static func currentThread() -> thread_act_t {
        mach_thread_self()
    }

    /// Every thread but the caller's, with `first` (when given and still alive) first.
    public static func sampleAll(first: thread_act_t? = nil) -> [Stack] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                          vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride))
        }
        let me = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, me) }

        var threads = (0..<Int(count)).map { list[$0] }.filter { $0 != me }
        if let first, let at = threads.firstIndex(of: first) {
            threads.insert(threads.remove(at: at), at: 0)
        }
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        defer { buffer.deallocate() }
        return threads.compactMap { thread in
            let depth = walk(thread, into: buffer, capacity: maxFrames)
            guard depth > 0 else { return nil }
            return Stack(name: name(of: thread), frames: Array(UnsafeBufferPointer(start: buffer, count: depth)))
        }
    }

    /// One thread's stack, or nil when it has gone or cannot be read.
    public static func sample(_ thread: thread_act_t) -> Stack? {
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        defer { buffer.deallocate() }
        let depth = walk(thread, into: buffer, capacity: maxFrames)
        guard depth > 0 else { return nil }
        return Stack(name: name(of: thread), frames: Array(UnsafeBufferPointer(start: buffer, count: depth)))
    }

    /// Suspends `thread`, writes its return addresses into `buffer`, and resumes it.
    /// No allocation and no locks from the suspend to the resume.
    private static func walk(_ thread: thread_act_t, into buffer: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }

        guard let (pc, link, start) = registers(thread) else { return 0 }
        var depth = 0
        buffer[depth] = pc; depth += 1
        // A leaf that has not pushed a frame (a syscall stub, say) has its caller only in
        // the link register. Where it has, this repeats the frame below; that costs a line.
        if link != 0, depth < capacity { buffer[depth] = link; depth += 1 }

        var frame = start
        var record = (UInt(0), UInt(0))
        let recordSize = vm_size_t(MemoryLayout<(UInt, UInt)>.size)
        while frame != 0, frame % UInt(MemoryLayout<UInt>.alignment) == 0, depth < capacity {
            var read: vm_size_t = 0
            let result = withUnsafeMutablePointer(to: &record) { pointer in
                vm_read_overwrite(mach_task_self_, vm_address_t(frame), recordSize,
                                  vm_address_t(UInt(bitPattern: pointer)), &read)
            }
            guard result == KERN_SUCCESS, read == recordSize else { break }
            let (caller, returnAddress) = (record.0, strip(record.1))
            guard returnAddress != 0 else { break }
            buffer[depth] = returnAddress; depth += 1
            // Stacks grow down: the caller's frame is always above this one.
            guard caller > frame else { break }
            frame = caller
        }
        return depth
    }

    /// The program counter, the link register (0 where there is none) and the frame pointer.
    private static func registers(_ thread: thread_act_t) -> (UInt, UInt, UInt)? {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (strip(UInt(state.__pc)), strip(UInt(state.__lr)), strip(UInt(state.__fp)))
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, x86_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt(state.__rip), 0, UInt(state.__rbp))
        #else
        return nil
        #endif
    }

    /// Drops pointer-authentication bits, which a signed return address carries above the
    /// 47 bits a user address uses.
    private static func strip(_ address: UInt) -> UInt {
        #if arch(arm64)
        address & 0x0000_7FFF_FFFF_FFFF
        #else
        address
        #endif
    }

    private static func name(of thread: thread_act_t) -> String {
        guard let pthread = pthread_from_mach_thread_np(thread) else { return "" }
        var bytes = [CChar](repeating: 0, count: 128)
        guard pthread_getname_np(pthread, &bytes, bytes.count) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Writing it up

    /// One line per frame, `index  image  address  symbol + offset`, and the images the
    /// frames are in with their UUIDs, so `atos` can name what `dladdr` could not (a
    /// stripped Live build).
    public static func describe(_ stacks: [Stack], firstLabel: String = "") -> String {
        var text = ""
        var images: [UInt: (name: String, uuid: String)] = [:]
        for (number, stack) in stacks.enumerated() {
            let label = number == 0 && !firstLabel.isEmpty ? " (\(firstLabel))" : ""
            let name = stack.name.isEmpty ? "" : " \"\(stack.name)\""
            text += "Thread \(number)\(label)\(name):\n"
            for (index, address) in stack.frames.enumerated() {
                // A return address is the instruction after the call; name the call.
                let lookup = index == 0 ? address : address &- 1
                var info = Dl_info()
                guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0 else {
                    text += "  \(pad(index)) ???  0x\(hex(address))\n"
                    continue
                }
                let base = UInt(bitPattern: info.dli_fbase)
                let path = info.dli_fname.map { String(cString: $0) } ?? "???"
                let image = (path as NSString).lastPathComponent
                if images[base] == nil { images[base] = (path, uuid(of: info.dli_fbase)) }
                var line = "  \(pad(index)) \(image)  0x\(hex(address))"
                if let symbol = info.dli_sname, let start = info.dli_saddr {
                    line += "  \(demangle(String(cString: symbol))) + \(lookup &- UInt(bitPattern: start))"
                } else {
                    line += "  \(image) + \(address &- base)"
                }
                text += line + "\n"
            }
            text += "\n"
        }
        text += "Binary images:\n"
        for (base, image) in images.sorted(by: { $0.key < $1.key }) {
            text += "  0x\(hex(base))  \(image.uuid)  \(image.name)\n"
        }
        return text
    }

    private static func pad(_ index: Int) -> String {
        let number = String(index)
        return String(repeating: " ", count: max(0, 3 - number.count)) + number
    }

    private static func hex(_ value: UInt) -> String {
        String(value, radix: 16)
    }

    private static func uuid(of header: UnsafeMutableRawPointer?) -> String {
        guard let header else { return "" }
        let mach = header.assumingMemoryBound(to: mach_header_64.self)
        guard mach.pointee.magic == MH_MAGIC_64 else { return "" }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<mach.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == LC_UUID {
                let id = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: id).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return ""
    }

    private static func demangle(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return symbol }
        let mangled = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
        guard let readable = mangled.withCString({ swiftDemangle($0, strlen($0), nil, nil, 0) }) else {
            return symbol
        }
        defer { free(readable) }
        return String(cString: readable)
    }
}

/// The Swift runtime's own demangler, which every Swift process already links.
@_silgen_name("swift_demangle")
private func swiftDemangle(_ mangled: UnsafePointer<CChar>, _ length: Int,
                           _ output: UnsafeMutablePointer<CChar>?, _ outputLength: UnsafeMutablePointer<Int>?,
                           _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
