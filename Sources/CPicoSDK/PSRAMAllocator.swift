#if PSRAM

#if Variant_RP2350A && Radio_None
    import _CPicoSDK_pico2
#elseif Variant_RP2350A && Radio_CYW43439
    import _CPicoSDK_pico2_w
#elseif Variant_RP2350B && Radio_None
    import _CPicoSDK_pimoroni_pico_plus2_rp2350
#elseif Variant_RP2350B && Radio_CYW43439
    import _CPicoSDK_pimoroni_pico_plus2_w_rp2350
#else
    import _CPicoSDK_pico2_w
#endif

import CShims
import TLSF

/// Allocator implementation to provide dynamic memory allocation from PSRAM,
/// using the Pico's QMI interface to access it and TLSF as the heap management 
/// algorithm.
/// 
/// This implementation is heavily based on https://github.com/sparkfun/sparkfun-pico
public final class PSRAMAllocator {
    public enum Error: Swift.Error {
        case noMemoryDetected
        case heapInitializationFailed
    }

    struct Commands {
        static let quadEnd: UInt32 = 0xF5
        static let quadEnable: UInt32 = 0x35
        static let readID: UInt32 = 0x9F
        static let resetEnable: UInt32 = 0x66
        static let reset: UInt32 = 0x99
        static let quadRead: UInt32 = 0xEB
        static let quadWrite: UInt32 = 0x38
        static let noop: UInt32 = 0xFF
    }

    static let secToFs: UInt64 = 1_000_000_000_000_000
    static let psramMaxSelectFs64: UInt32 = 125_000_000
    static let psramMinDeselectFs: UInt32 = 50_000_000
    static let psramMaxSckHz: UInt32 = 109_000_000
    static let qmiPollTimeout: UInt32 = 10_000_000

    static let expectedID: UInt32 = 0x5D

    @inline(never)
    @section(".time_critical.psram")
    @_optimize(none)
    private static func waitQmiBusyClear() -> Bool {
        var timeout: UInt32 = qmiPollTimeout
        while (cshims_mmio_read32(&qmi_hw.pointee.direct_csr) & QMI_DIRECT_CSR_BUSY_BITS) != 0 {
            timeout = timeout &- 1
            if timeout == 0 { return false }
        }
        return true
    }

    @inline(never)
    @section(".time_critical.psram")
    @_optimize(none)
    private static func waitQmiTxNotFull() -> Bool {
        var timeout: UInt32 = qmiPollTimeout
        while (cshims_mmio_read32(&qmi_hw.pointee.direct_csr) & QMI_DIRECT_CSR_TXFULL_BITS) != 0 {
            timeout = timeout &- 1
            if timeout == 0 { return false }
        }
        return true
    }

    @inline(never)
    @section(".time_critical.psram")
    @_optimize(none)
    private static func waitQmiRxNotEmpty() -> Bool {
        var timeout: UInt32 = qmiPollTimeout
        while (cshims_mmio_read32(&qmi_hw.pointee.direct_csr) & QMI_DIRECT_CSR_RXEMPTY_BITS) != 0 {
            timeout = timeout &- 1
            if timeout == 0 { return false }
        }
        return true
    }

    @inline(never)
    @section(".time_critical.psram")
    @_optimize(none)
    private static func getPSRAMSize() -> Int {
        let intrStash = save_and_disable_interrupts()
        cshims_mmio_write32(&qmi_hw.pointee.direct_csr, (30 << QMI_DIRECT_CSR_CLKDIV_LSB) | QMI_DIRECT_CSR_EN_BITS)

        guard waitQmiBusyClear() else {
            cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return 0
        }

        cshims_mmio_set_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS)
        cshims_mmio_write32(&qmi_hw.pointee.direct_tx, 
            QMI_DIRECT_TX_OE_BITS | (QMI_DIRECT_TX_IWIDTH_VALUE_Q << QMI_DIRECT_TX_IWIDTH_LSB) | Commands.quadEnd
        )

        guard waitQmiBusyClear() else {
            cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return 0
        }
        if (cshims_mmio_read32(&qmi_hw.pointee.direct_csr) & QMI_DIRECT_CSR_RXEMPTY_BITS) == 0 {
            _ = cshims_qmi_direct_rx_read32()
        }
        cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

        cshims_mmio_set_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

        var kgd: UInt32 = 0
        var eid: UInt32 = 0

        var i: UInt32 = 0
        while i < 7 {
            guard waitQmiTxNotFull() else {
                cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
                restore_interrupts(intrStash)
                return 0
            }
            cshims_mmio_write32(&qmi_hw.pointee.direct_tx, i == 0 ? Commands.readID : Commands.noop)

            guard waitQmiRxNotEmpty() else {
                cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
                restore_interrupts(intrStash)
                return 0
            }

            let rx = cshims_qmi_direct_rx_read32() & 0xff
            if i == 5 {
                kgd = rx
            } else if i == 6 {
                eid = rx
            }
            i = i &+ 1
        }

        cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)

        restore_interrupts(intrStash)
        return interpretedPSRAMSize(kgd: kgd, eid: eid)
    }

    @inline(never)
    @section(".time_critical.psram")
    @_optimize(none)
    private static func interpretedPSRAMSize(kgd: UInt32, eid: UInt32) -> Int {
        var size = 0
        if kgd == expectedID {
            size = 1 * 1024 * 1024
            let sizeID = (eid >> 5) & 0x7
            if eid == 0x26 || sizeID == 2 {
                size *= 8
            } else if sizeID == 0 {
                size *= 2
            } else if sizeID == 1 {
                size *= 4
            }
        }
        return size
    }

    @inline(never)
    @section(".time_critical.psram")
    @_optimize(none)
    public static func probePSRAM(csPin: UInt32) -> (kgd: UInt32, eid: UInt32, size: Int) {
        gpio_set_function(csPin, GPIO_FUNC_XIP_CS1)

        let intrStash = save_and_disable_interrupts()
        cshims_mmio_write32(&qmi_hw.pointee.direct_csr, ((30 << QMI_DIRECT_CSR_CLKDIV_LSB) | QMI_DIRECT_CSR_EN_BITS))

        guard waitQmiBusyClear() else {
            cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return (0, 0, 0)
        }

        cshims_mmio_set_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS)
        cshims_mmio_write32(&qmi_hw.pointee.direct_tx, 
            QMI_DIRECT_TX_OE_BITS | (QMI_DIRECT_TX_IWIDTH_VALUE_Q << QMI_DIRECT_TX_IWIDTH_LSB) | Commands.quadEnd
        )

        guard waitQmiBusyClear() else {
            cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return (0, 0, 0)
        }
        if (cshims_mmio_read32(&qmi_hw.pointee.direct_csr) & QMI_DIRECT_CSR_RXEMPTY_BITS) == 0 {
            _ = cshims_qmi_direct_rx_read32()
        }
        cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

        cshims_mmio_set_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

        var kgd: UInt32 = 0
        var eid: UInt32 = 0
        var i: UInt32 = 0
        while i < 7 {
            guard waitQmiTxNotFull() else {
                cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
                restore_interrupts(intrStash)
                return (0, 0, 0)
            }
            cshims_mmio_write32(&qmi_hw.pointee.direct_tx, i == 0 ? Commands.readID : Commands.noop)

            guard waitQmiRxNotEmpty() else {
                cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
                restore_interrupts(intrStash)
                return (0, 0, 0)
            }

            let rx = cshims_qmi_direct_rx_read32() & 0xff
            if i == 5 {
                kgd = rx
            } else if i == 6 {
                eid = rx
            }
            i = i &+ 1
        }

        cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
        restore_interrupts(intrStash)

        return (kgd, eid, interpretedPSRAMSize(kgd: kgd, eid: eid))
    }

    @inline(never)
    @section(".time_critical.psram")
    @_optimize(none)
    public static func setPSRAMTiming(sysClockHz: UInt64) {
        let clockDivider = UInt32((sysClockHz + UInt64(psramMaxSckHz) - 1) / UInt64(psramMaxSckHz))
        let fsPerCycle = secToFs / sysClockHz
        if fsPerCycle == 0 { return }

        let maxSelect = UInt32(UInt64(psramMaxSelectFs64) / fsPerCycle)
        let minDeselect = UInt32((UInt64(psramMinDeselectFs) + fsPerCycle - 1) / fsPerCycle)

        let intrStash = save_and_disable_interrupts()

        let timingValue = (QMI_M1_TIMING_PAGEBREAK_VALUE_1024 << QMI_M1_TIMING_PAGEBREAK_LSB)
            | (3 << QMI_M1_TIMING_SELECT_HOLD_LSB)
            | (1 << QMI_M1_TIMING_COOLDOWN_LSB)
            | (1 << QMI_M1_TIMING_RXDELAY_LSB)
            | (maxSelect << QMI_M1_TIMING_MAX_SELECT_LSB)
            | (minDeselect << QMI_M1_TIMING_MIN_DESELECT_LSB)
            | (clockDivider << QMI_M1_TIMING_CLKDIV_LSB)

        cshims_mmio_write32(&qmi_hw.pointee.m.1.timing, timingValue)
        restore_interrupts(intrStash)
    }

    @inline(never)
    @section(".time_critical.psram")
    @_optimize(none)
    public static func setupPSRAM(csPin: UInt32, sysClockHz: UInt64) throws(Error) -> Int {
        gpio_set_function(csPin, GPIO_FUNC_XIP_CS1)

        let psramSize = getPSRAMSize()
        if psramSize == 0 {
            throw Error.noMemoryDetected
        }

        var intrStash = save_and_disable_interrupts()
        cshims_mmio_write32(&qmi_hw.pointee.direct_csr, ((30 << QMI_DIRECT_CSR_CLKDIV_LSB) | QMI_DIRECT_CSR_EN_BITS))

        guard waitQmiBusyClear() else {
            cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return 0
        }

        var setupStep: UInt32 = 0
        while setupStep < 3 {
            cshims_mmio_set_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

            guard waitQmiTxNotFull() else {
                cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
                restore_interrupts(intrStash)
                return 0
            }

            if setupStep == 0 {
                cshims_mmio_write32(&qmi_hw.pointee.direct_tx, Commands.resetEnable)
            } else if setupStep == 1 {
                cshims_mmio_write32(&qmi_hw.pointee.direct_tx, Commands.reset)
            } else {
                cshims_mmio_write32(&qmi_hw.pointee.direct_tx, Commands.quadEnable)
            }

            guard waitQmiBusyClear() else {
                cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
                restore_interrupts(intrStash)
                return 0
            }
            cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS)
            
            var count = 20
            while count > 0 {
                count -= 1
            }

            if (cshims_mmio_read32(&qmi_hw.pointee.direct_csr) & QMI_DIRECT_CSR_RXEMPTY_BITS) == 0 {
                _ = cshims_qmi_direct_rx_read32()
            }
            setupStep = setupStep &+ 1
        }

        cshims_mmio_clear_bits32(&qmi_hw.pointee.direct_csr, QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
        restore_interrupts(intrStash)

        setPSRAMTiming(sysClockHz: sysClockHz)
        intrStash = save_and_disable_interrupts()

        let rfmtValue = (QMI_M1_RFMT_PREFIX_WIDTH_VALUE_Q << QMI_M1_RFMT_PREFIX_WIDTH_LSB)
            | (QMI_M1_RFMT_ADDR_WIDTH_VALUE_Q << QMI_M1_RFMT_ADDR_WIDTH_LSB)
            | (QMI_M1_RFMT_SUFFIX_WIDTH_VALUE_Q << QMI_M1_RFMT_SUFFIX_WIDTH_LSB)
            | (QMI_M1_RFMT_DUMMY_WIDTH_VALUE_Q << QMI_M1_RFMT_DUMMY_WIDTH_LSB)
            | (QMI_M1_RFMT_DUMMY_LEN_VALUE_24 << QMI_M1_RFMT_DUMMY_LEN_LSB)
            | (QMI_M1_RFMT_DATA_WIDTH_VALUE_Q << QMI_M1_RFMT_DATA_WIDTH_LSB)
            | (QMI_M1_RFMT_PREFIX_LEN_VALUE_8 << QMI_M1_RFMT_PREFIX_LEN_LSB)
            | (QMI_M1_RFMT_SUFFIX_LEN_VALUE_NONE << QMI_M1_RFMT_SUFFIX_LEN_LSB)

        let wfmtValue = (QMI_M1_WFMT_PREFIX_WIDTH_VALUE_Q << QMI_M1_WFMT_PREFIX_WIDTH_LSB)
            | (QMI_M1_WFMT_ADDR_WIDTH_VALUE_Q << QMI_M1_WFMT_ADDR_WIDTH_LSB)
            | (QMI_M1_WFMT_SUFFIX_WIDTH_VALUE_Q << QMI_M1_WFMT_SUFFIX_WIDTH_LSB)
            | (QMI_M1_WFMT_DUMMY_WIDTH_VALUE_Q << QMI_M1_WFMT_DUMMY_WIDTH_LSB)
            | (QMI_M1_WFMT_DUMMY_LEN_VALUE_NONE << QMI_M1_WFMT_DUMMY_LEN_LSB)
            | (QMI_M1_WFMT_DATA_WIDTH_VALUE_Q << QMI_M1_WFMT_DATA_WIDTH_LSB)
            | (QMI_M1_WFMT_PREFIX_LEN_VALUE_8 << QMI_M1_WFMT_PREFIX_LEN_LSB)
            | (QMI_M1_WFMT_SUFFIX_LEN_VALUE_NONE << QMI_M1_WFMT_SUFFIX_LEN_LSB)

        cshims_mmio_write32(&qmi_hw.pointee.m.1.rfmt, rfmtValue)
        cshims_mmio_write32(&qmi_hw.pointee.m.1.rcmd, (Commands.quadRead << QMI_M1_RCMD_PREFIX_LSB) | (0 << QMI_M1_RCMD_SUFFIX_LSB))
        cshims_mmio_write32(&qmi_hw.pointee.m.1.wfmt, wfmtValue)
        cshims_mmio_write32(&qmi_hw.pointee.m.1.wcmd, (Commands.quadWrite << QMI_M1_WCMD_PREFIX_LSB) | (0 << QMI_M1_WCMD_SUFFIX_LSB))

        cshims_mmio_set_bits32(&xip_ctrl_hw.pointee.ctrl, XIP_CTRL_WRITABLE_M1_BITS)
        restore_interrupts(intrStash)

        return psramSize
    }

    let psramBase = UnsafeMutableRawPointer(bitPattern: 0x1100_0000)!
    let heap: tlsf_t
    let psramPool: pool_t
    let psramSize: Int

    let csPin: UInt32

    public init(csPin: UInt32) throws(Error) {
        self.csPin = csPin

        let psramSize = try Self.setupPSRAM(csPin: csPin, sysClockHz: UInt64(clock_get_hz(clk_sys)))

        guard let heap = tlsf_create_with_pool(psramBase, psramSize, 64 * 1024 * 1024) else {
            throw Error.heapInitializationFailed
        }

        self.psramSize = psramSize
        self.heap = heap
        self.psramPool = tlsf_get_pool(heap)
    }

    public func sfeMemMalloc(_ size: Int) -> UnsafeMutableRawPointer? {
        tlsf_malloc(heap, size)
    }

    public func sfeMemFree(_ ptr: UnsafeMutableRawPointer?) {
        tlsf_free(heap, ptr)
    }

    public func sfeMemRealloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
        tlsf_realloc(heap, ptr, size)
    }

    public func sfeMemCalloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer? {
        let (totalSize, overflow) = num.multipliedReportingOverflow(by: size)
        if overflow || totalSize < 0 { return nil }
        guard let ptr = tlsf_malloc(heap, totalSize) else { return nil }
        memset(ptr, 0, totalSize)
        return ptr
    }

    public var maxFreeSize: Int {
        poolWalkTotal { ptr, size, used, user in
            guard let user else { return true }
            let maxSize = user.assumingMemoryBound(to: Int.self)
            if used == 0, maxSize.pointee < size {
                maxSize.pointee = size
            }
            return true
        }
    }

    public var totalMemory: Int {
        poolWalkTotal { ptr, size, used, user in
            guard let user else { return true }
            user.assumingMemoryBound(to: Int.self).pointee += size
            return true
        }
    }

    public var usedMemory: Int {
        poolWalkTotal { ptr, size, used, user in
            guard let user else { return true }
            if used != 0 {
                user.assumingMemoryBound(to: Int.self).pointee += size
            }
            return true
        }
    }

    private func poolWalkTotal(_ walker: @convention(c) (UnsafeMutableRawPointer?, Int, Int32, UnsafeMutableRawPointer?) -> Bool) -> Int {
        var total = 0
        withUnsafeMutablePointer(to: &total) { totalPtr in
            let user = UnsafeMutableRawPointer(totalPtr)
            tlsf_walk_pool(psramPool, walker, user)
        }
        return total
    }
}

// @_cdecl("sfe_setup_psram")
// public func sfe_setup_psram_c(_ psram_cs_pin: UInt32) -> Int {
//     setupPSRAM(csPin: psram_cs_pin)
// }

// @_cdecl("sfe_psram_update_timing")
// public func sfe_psram_update_timing_c() {
//     setPSRAMTiming()
// }

// @_cdecl("sfe_pico_alloc_init")
// public func sfe_pico_alloc_init_c() -> Bool {
//     sfePicoAllocInit()
// }

// @_cdecl("sfe_mem_malloc")
// public func sfe_mem_malloc_c(_ size: Int) -> UnsafeMutableRawPointer? {
//     sfeMemMalloc(size)
// }

// @_cdecl("sfe_mem_free")
// public func sfe_mem_free_c(_ ptr: UnsafeMutableRawPointer?) {
//     sfeMemFree(ptr)
// }

// @_cdecl("sfe_mem_realloc")
// public func sfe_mem_realloc_c(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
//     sfeMemRealloc(ptr, size)
// }

// @_cdecl("sfe_mem_calloc")
// public func sfe_mem_calloc_c(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer? {
//     sfeMemCalloc(num, size)
// }

// @_cdecl("sfe_mem_max_free_size")
// public func sfe_mem_max_free_size_c() -> Int {
//     poolWalkTotal(maxFreeWalker)
// }

// @_cdecl("sfe_mem_size")
// public func sfe_mem_size_c() -> Int {
//     poolWalkTotal(memorySizeWalker)
// }

// @_cdecl("sfe_mem_used")
// public func sfe_mem_used_c() -> Int {
//     poolWalkTotal(memoryUsedWalker)
// }

#endif
