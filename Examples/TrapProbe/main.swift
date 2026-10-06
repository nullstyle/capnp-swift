// TrapProbe: proves a trap inside the Zig core symbolicates to a source line.
//
// scripts/check-dsym.sh runs this. It prints the main image's load address,
// installs a SIGTRAP/SIGILL handler, and calls the test hook
// capnp_core_debug_trap(), which executes a trap instruction inside
// `debugTrapFrame` in core/src/abi.zig. The handler prints the trapping
// program counter and exits with status 42. The script then asks `atos` to map
// that PC, through a dSYM built from this executable, to core/src/abi.zig:<line>.
//
// The handler reads the PC from the signal's ucontext: the same value a crash
// report records for the crashing frame.

import CapnpCore
import Darwin
import MachO

/// Writes "<label>0x<hex>\n" to stderr without allocating (signal context).
private func writeHex(_ label: StaticString, _ value: UInt64) {
    _ = write(2, label.utf8Start, label.utf8CodeUnitCount)
    var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
              UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &buf) { out in
        out[0] = UInt8(ascii: "0")
        out[1] = UInt8(ascii: "x")
        let digits: StaticString = "0123456789abcdef"
        for i in 0..<16 {
            let nibble = Int((value >> UInt64(60 - 4 * i)) & 0xf)
            out[2 + i] = digits.utf8Start[nibble]
        }
        out[18] = UInt8(ascii: "\n")
        _ = write(2, out.baseAddress, 19)
    }
}

private func onTrap(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { _exit(3) }
    let uc = context.assumingMemoryBound(to: ucontext_t.self)
    #if arch(arm64)
    let pc = UInt64(uc.pointee.uc_mcontext.pointee.__ss.__pc)
    #elseif arch(x86_64)
    let pc = UInt64(uc.pointee.uc_mcontext.pointee.__ss.__rip)
    #else
    #error("unsupported architecture")
    #endif
    writeHex("trap_signal=", UInt64(signal))
    writeHex("trap_pc=", pc)
    _exit(42)
}

var action = sigaction()
action.__sigaction_u.__sa_sigaction = onTrap
action.sa_flags = SA_SIGINFO
sigemptyset(&action.sa_mask)
sigaction(SIGTRAP, &action, nil)  // arm64: brk
sigaction(SIGILL, &action, nil)   // x86_64: ud2

guard let header = _dyld_get_image_header(0) else { fatalError("no main image") }
#if arch(arm64)
print("arch=arm64")
#elseif arch(x86_64)
print("arch=x86_64")
#endif
print("load_address=0x\(String(UInt(bitPattern: header), radix: 16))")
print("core=\(String(cString: capnp_core_version()))")
fflush(stdout)

capnp_core_debug_trap()
