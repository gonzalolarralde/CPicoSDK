import CPicoSDK
import PSRAMAllocatorShim
import TLSF

private enum SparkFunPSRAM {
    static let secToFs: UInt64 = 1_000_000_000_000_000
    static let psramMaxSelectFs64: UInt32 = 125_000_000
    static let psramMinDeselectFs: UInt32 = 50_000_000
    static let psramMaxSckHz: UInt32 = 109_000_000

    static let cmdQuadEnd: UInt32 = 0xF5
    static let cmdQuadEnable: UInt32 = 0x35
    static let cmdReadID: UInt32 = 0x9F
    static let cmdResetEnable: UInt32 = 0x66
    static let cmdReset: UInt32 = 0x99
    static let cmdQuadRead: UInt32 = 0xEB
    static let cmdQuadWrite: UInt32 = 0x38
    static let cmdNoop: UInt32 = 0xFF
    static let expectedID: UInt32 = 0x5D

}

private nonisolated(unsafe) var allocatorHeap: tlsf_t?
private nonisolated(unsafe) var allocatorSRAMPool: pool_t?
private nonisolated(unsafe) var allocatorPSRAMPool: pool_t?
private nonisolated(unsafe) var allocatorPSRAMSize: Int = 0
private nonisolated(unsafe) var allocatorInitialized = false
private nonisolated(unsafe) var allocatorConfiguredCSPin: UInt32?
private nonisolated(unsafe) var allocatorDetectedPSRAMSize: Int = 0

private let qmiPollTimeout: UInt32 = 10_000_000

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func qmiDirectCSRRead32() -> UInt32 {
    psram_mmio_read32_cshim(&qmi_hw.pointee.direct_csr)
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func qmiDirectCSRWrite32(_ value: UInt32) {
    psram_mmio_write32_cshim(&qmi_hw.pointee.direct_csr, value)
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func qmiDirectCSRSetBits(_ mask: UInt32) {
    psram_mmio_set_bits32_cshim(&qmi_hw.pointee.direct_csr, mask)
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func qmiDirectCSRClearBits(_ mask: UInt32) {
    psram_mmio_clear_bits32_cshim(&qmi_hw.pointee.direct_csr, mask)
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func qmiDirectRXRead32() -> UInt32 {
    qmi_hw.pointee.direct_rx
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func qmiDirectTXWrite32(_ value: UInt32) {
    psram_mmio_write32_cshim(&qmi_hw.pointee.direct_tx, value)
}

@inline(__always)
private func psramLocation() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(bitPattern: 0x1100_0000)
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func waitQmiBusyClear() -> Bool {
    var timeout: UInt32 = qmiPollTimeout
    while (qmiDirectCSRRead32() & QMI_DIRECT_CSR_BUSY_BITS) != 0 {
        timeout = timeout &- 1
        if timeout == 0 { return false }
    }
    return true
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func waitQmiTxNotFull() -> Bool {
    var timeout: UInt32 = qmiPollTimeout
    while (qmiDirectCSRRead32() & QMI_DIRECT_CSR_TXFULL_BITS) != 0 {
        timeout = timeout &- 1
        if timeout == 0 { return false }
    }
    return true
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func waitQmiRxNotEmpty() -> Bool {
    var timeout: UInt32 = qmiPollTimeout
    while (qmiDirectCSRRead32() & QMI_DIRECT_CSR_RXEMPTY_BITS) != 0 {
        timeout = timeout &- 1
        if timeout == 0 { return false }
    }
    return true
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func getPSRAMSize() -> Int {
    let intrStash = save_and_disable_interrupts()
    qmiDirectCSRWrite32((30 << QMI_DIRECT_CSR_CLKDIV_LSB) | QMI_DIRECT_CSR_EN_BITS)

    guard waitQmiBusyClear() else {
        qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
        restore_interrupts(intrStash)
        return 0
    }

    qmiDirectCSRSetBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS)
    qmiDirectTXWrite32(
        QMI_DIRECT_TX_OE_BITS | (QMI_DIRECT_TX_IWIDTH_VALUE_Q << QMI_DIRECT_TX_IWIDTH_LSB) | SparkFunPSRAM.cmdQuadEnd
    )

    guard waitQmiBusyClear() else {
        qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
        restore_interrupts(intrStash)
        return 0
    }
    if (qmiDirectCSRRead32() & QMI_DIRECT_CSR_RXEMPTY_BITS) == 0 {
        _ = qmiDirectRXRead32()
    }
    qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

    qmiDirectCSRSetBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

    var kgd: UInt32 = 0
    var eid: UInt32 = 0

    var i: UInt32 = 0
    while i < 7 {
        guard waitQmiTxNotFull() else {
            qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return 0
        }
        qmiDirectTXWrite32(i == 0 ? SparkFunPSRAM.cmdReadID : SparkFunPSRAM.cmdNoop)

        guard waitQmiRxNotEmpty() else {
            qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return 0
        }

        let rx = qmiDirectRXRead32() & 0xff
        if i == 5 {
            kgd = rx
        } else if i == 6 {
            eid = rx
        }
        i = i &+ 1
    }

    qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)

    restore_interrupts(intrStash)
    return interpretedPSRAMSize(kgd: kgd, eid: eid)
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
private func interpretedPSRAMSize(kgd: UInt32, eid: UInt32) -> Int {
    var size = 0
    if kgd == SparkFunPSRAM.expectedID {
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
public func probePSRAM(csPin: UInt32) -> (kgd: UInt32, eid: UInt32, size: Int) {
    gpio_set_function(csPin, GPIO_FUNC_XIP_CS1)

    let intrStash = save_and_disable_interrupts()
    qmiDirectCSRWrite32((30 << QMI_DIRECT_CSR_CLKDIV_LSB) | QMI_DIRECT_CSR_EN_BITS)

    guard waitQmiBusyClear() else {
        qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
        restore_interrupts(intrStash)
        return (0, 0, 0)
    }

    qmiDirectCSRSetBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS)
    qmiDirectTXWrite32(
        QMI_DIRECT_TX_OE_BITS | (QMI_DIRECT_TX_IWIDTH_VALUE_Q << QMI_DIRECT_TX_IWIDTH_LSB) | SparkFunPSRAM.cmdQuadEnd
    )

    guard waitQmiBusyClear() else {
        qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
        restore_interrupts(intrStash)
        return (0, 0, 0)
    }
    if (qmiDirectCSRRead32() & QMI_DIRECT_CSR_RXEMPTY_BITS) == 0 {
        _ = qmiDirectRXRead32()
    }
    qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

    qmiDirectCSRSetBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

    var kgd: UInt32 = 0
    var eid: UInt32 = 0
    var i: UInt32 = 0
    while i < 7 {
        guard waitQmiTxNotFull() else {
            qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return (0, 0, 0)
        }
        qmiDirectTXWrite32(i == 0 ? SparkFunPSRAM.cmdReadID : SparkFunPSRAM.cmdNoop)

        guard waitQmiRxNotEmpty() else {
            qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return (0, 0, 0)
        }

        let rx = qmiDirectRXRead32() & 0xff
        if i == 5 {
            kgd = rx
        } else if i == 6 {
            eid = rx
        }
        i = i &+ 1
    }

    qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
    restore_interrupts(intrStash)

    return (kgd, eid, interpretedPSRAMSize(kgd: kgd, eid: eid))
}

public func probePSRAMViaCShim(csPin: UInt32) -> (ok: Bool, kgd: UInt32, eid: UInt32, size: Int) {
    var kgd: UInt32 = 0
    var eid: UInt32 = 0
    let ok = psram_probe_id_cshim(csPin, &kgd, &eid) != 0
    let kgd32 = kgd & 0xff
    let eid32 = eid & 0xff
    return (ok, kgd32, eid32, interpretedPSRAMSize(kgd: kgd32, eid: eid32))
}

public func debugQMIState() -> (primask: UInt32, directCSR: UInt32, busy: Bool, txFull: Bool, rxEmpty: Bool, assertCS1: Bool, en: Bool) {
    let primask: UInt32 = (save_and_disable_interrupts() & 1)
    let csr = qmiDirectCSRRead32()
    restore_interrupts(primask)
    return (
        primask: primask,
        directCSR: csr,
        busy: (csr & QMI_DIRECT_CSR_BUSY_BITS) != 0,
        txFull: (csr & QMI_DIRECT_CSR_TXFULL_BITS) != 0,
        rxEmpty: (csr & QMI_DIRECT_CSR_RXEMPTY_BITS) != 0,
        assertCS1: (csr & QMI_DIRECT_CSR_ASSERT_CS1N_BITS) != 0,
        en: (csr & QMI_DIRECT_CSR_EN_BITS) != 0
    )
}

@discardableResult
public func sanitizeQMIDirectStateForDebug(maxDrainReads: UInt32 = 16) -> UInt32 {
    let intrStash = save_and_disable_interrupts()
    var csr = qmiDirectCSRRead32()
    csr &= ~(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
    qmiDirectCSRWrite32(csr)

    var drained: UInt32 = 0
    while drained < maxDrainReads && (qmiDirectCSRRead32() & QMI_DIRECT_CSR_RXEMPTY_BITS) == 0 {
        _ = qmiDirectRXRead32()
        drained = drained &+ 1
    }
    restore_interrupts(intrStash)
    return drained
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
public func setPSRAMTiming() {
    let sysHz = UInt64(clock_get_hz(clk_sys))
    if sysHz == 0 { return }

    let clockDivider = UInt32((sysHz + UInt64(SparkFunPSRAM.psramMaxSckHz) - 1) / UInt64(SparkFunPSRAM.psramMaxSckHz))
    let fsPerCycle = SparkFunPSRAM.secToFs / sysHz
    if fsPerCycle == 0 { return }

    let maxSelect = UInt32(UInt64(SparkFunPSRAM.psramMaxSelectFs64) / fsPerCycle)
    let minDeselect = UInt32((UInt64(SparkFunPSRAM.psramMinDeselectFs) + fsPerCycle - 1) / fsPerCycle)

    let intrStash = save_and_disable_interrupts()

    let timingValue = (QMI_M1_TIMING_PAGEBREAK_VALUE_1024 << QMI_M1_TIMING_PAGEBREAK_LSB)
        | (3 << QMI_M1_TIMING_SELECT_HOLD_LSB)
        | (1 << QMI_M1_TIMING_COOLDOWN_LSB)
        | (1 << QMI_M1_TIMING_RXDELAY_LSB)
        | (maxSelect << QMI_M1_TIMING_MAX_SELECT_LSB)
        | (minDeselect << QMI_M1_TIMING_MIN_DESELECT_LSB)
        | (clockDivider << QMI_M1_TIMING_CLKDIV_LSB)

    qmi_hw.pointee.m.1.timing = timingValue
    restore_interrupts(intrStash)
}

@inline(never)
@section(".time_critical.psram")
@_optimize(none)
public func setupPSRAM(csPin: UInt32) -> Int {
    gpio_set_function(csPin, GPIO_FUNC_XIP_CS1)

    let psramSize = getPSRAMSize()
    if psramSize == 0 {
        allocatorConfiguredCSPin = csPin
        allocatorDetectedPSRAMSize = 0
        return 0
    }

    var intrStash = save_and_disable_interrupts()
    qmiDirectCSRWrite32((30 << QMI_DIRECT_CSR_CLKDIV_LSB) | QMI_DIRECT_CSR_EN_BITS)

    guard waitQmiBusyClear() else {
        qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
        restore_interrupts(intrStash)
        return 0
    }

    var setupStep: UInt32 = 0
    while setupStep < 3 {
        qmiDirectCSRSetBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS)

        guard waitQmiTxNotFull() else {
            qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return 0
        }

        if setupStep == 0 {
            qmiDirectTXWrite32(SparkFunPSRAM.cmdResetEnable)
        } else if setupStep == 1 {
            qmiDirectTXWrite32(SparkFunPSRAM.cmdReset)
        } else {
            qmiDirectTXWrite32(SparkFunPSRAM.cmdQuadEnable)
        }

        guard waitQmiBusyClear() else {
            qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
            restore_interrupts(intrStash)
            return 0
        }
        qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS)
        busy_wait_us_32(1)
        if (qmiDirectCSRRead32() & QMI_DIRECT_CSR_RXEMPTY_BITS) == 0 {
            _ = qmiDirectRXRead32()
        }
        setupStep = setupStep &+ 1
    }

    qmiDirectCSRClearBits(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS)
    restore_interrupts(intrStash)

    setPSRAMTiming()
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

    qmi_hw.pointee.m.1.rfmt = rfmtValue
    qmi_hw.pointee.m.1.rcmd = (SparkFunPSRAM.cmdQuadRead << QMI_M1_RCMD_PREFIX_LSB) | (0 << QMI_M1_RCMD_SUFFIX_LSB)
    qmi_hw.pointee.m.1.wfmt = wfmtValue
    qmi_hw.pointee.m.1.wcmd = (SparkFunPSRAM.cmdQuadWrite << QMI_M1_WCMD_PREFIX_LSB) | (0 << QMI_M1_WCMD_SUFFIX_LSB)

    xip_ctrl_hw.pointee.ctrl |= XIP_CTRL_WRITABLE_M1_BITS
    restore_interrupts(intrStash)
    allocatorConfiguredCSPin = csPin
    allocatorDetectedPSRAMSize = psramSize
    return psramSize
}

public func configurePSRAMAllocator(csPin: UInt32) {
    allocatorConfiguredCSPin = csPin
}

public func sfePicoAllocInit() -> Bool {
    if allocatorInitialized { return true }

    allocatorHeap = nil
    allocatorSRAMPool = nil
    allocatorPSRAMPool = nil
    allocatorPSRAMSize = 0

    if allocatorDetectedPSRAMSize > 0 {
        allocatorPSRAMSize = allocatorDetectedPSRAMSize
    } else if let csPin = allocatorConfiguredCSPin {
        allocatorPSRAMSize = setupPSRAM(csPin: csPin)
    } else {
        fatalError("PSRAMAllocator requires explicit initialization. Call setupPSRAM(csPin:) before allocation.")
    }

    if allocatorPSRAMSize > 0, let psram = psramLocation() {
        let heap = tlsf_create_with_pool(psram, allocatorPSRAMSize, 64 * 1024 * 1024)
        allocatorHeap = heap
        if let heap {
            allocatorPSRAMPool = tlsf_get_pool(heap)
        }
    }

    allocatorInitialized = true
    return true
}

public func sfeMemMalloc(_ size: Int) -> UnsafeMutableRawPointer? {
    guard sfePicoAllocInit(), let heap = allocatorHeap else { return nil }
    return tlsf_malloc(heap, size)
}

public func sfeMemFree(_ ptr: UnsafeMutableRawPointer?) {
    guard sfePicoAllocInit(), let heap = allocatorHeap else { return }
    tlsf_free(heap, ptr)
}

public func sfeMemRealloc(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    guard sfePicoAllocInit(), let heap = allocatorHeap else { return nil }
    return tlsf_realloc(heap, ptr, size)
}

public func sfeMemCalloc(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer? {
    guard sfePicoAllocInit(), let heap = allocatorHeap else { return nil }
    let (totalSize, overflow) = num.multipliedReportingOverflow(by: size)
    if overflow || totalSize < 0 { return nil }
    guard let ptr = tlsf_malloc(heap, totalSize) else { return nil }
    memset(ptr, 0, totalSize)
    return ptr
}

public func maxFreeWalker(_ ptr: UnsafeMutableRawPointer?, _ size: Int, _ used: Int32, _ user: UnsafeMutableRawPointer?) -> Bool {
    guard let user else { return true }
    let maxSize = user.assumingMemoryBound(to: Int.self)
    if used == 0, maxSize.pointee < size {
        maxSize.pointee = size
    }
    return true
}

public func memorySizeWalker(_ ptr: UnsafeMutableRawPointer?, _ size: Int, _ used: Int32, _ user: UnsafeMutableRawPointer?) -> Bool {
    guard let user else { return true }
    user.assumingMemoryBound(to: Int.self).pointee += size
    return true
}

public func memoryUsedWalker(_ ptr: UnsafeMutableRawPointer?, _ size: Int, _ used: Int32, _ user: UnsafeMutableRawPointer?) -> Bool {
    guard let user else { return true }
    if used != 0 {
        user.assumingMemoryBound(to: Int.self).pointee += size
    }
    return true
}

public func poolWalkTotal(_ walker: @convention(c) (UnsafeMutableRawPointer?, Int, Int32, UnsafeMutableRawPointer?) -> Bool) -> Int {
    guard sfePicoAllocInit(), allocatorHeap != nil else { return 0 }
    var total = 0
    withUnsafeMutablePointer(to: &total) { totalPtr in
        let user = UnsafeMutableRawPointer(totalPtr)
        if let sramPool = allocatorSRAMPool {
            tlsf_walk_pool(sramPool, walker, user)
        }
        if let psramPool = allocatorPSRAMPool {
            tlsf_walk_pool(psramPool, walker, user)
        }
    }
    return total
}

@_cdecl("sfe_setup_psram")
public func sfe_setup_psram_c(_ psram_cs_pin: UInt32) -> Int {
    setupPSRAM(csPin: psram_cs_pin)
}

@_cdecl("sfe_psram_update_timing")
public func sfe_psram_update_timing_c() {
    setPSRAMTiming()
}

@_cdecl("sfe_pico_alloc_init")
public func sfe_pico_alloc_init_c() -> Bool {
    sfePicoAllocInit()
}

@_cdecl("sfe_mem_malloc")
public func sfe_mem_malloc_c(_ size: Int) -> UnsafeMutableRawPointer? {
    sfeMemMalloc(size)
}

@_cdecl("sfe_mem_free")
public func sfe_mem_free_c(_ ptr: UnsafeMutableRawPointer?) {
    sfeMemFree(ptr)
}

@_cdecl("sfe_mem_realloc")
public func sfe_mem_realloc_c(_ ptr: UnsafeMutableRawPointer?, _ size: Int) -> UnsafeMutableRawPointer? {
    sfeMemRealloc(ptr, size)
}

@_cdecl("sfe_mem_calloc")
public func sfe_mem_calloc_c(_ num: Int, _ size: Int) -> UnsafeMutableRawPointer? {
    sfeMemCalloc(num, size)
}

@_cdecl("sfe_mem_max_free_size")
public func sfe_mem_max_free_size_c() -> Int {
    poolWalkTotal(maxFreeWalker)
}

@_cdecl("sfe_mem_size")
public func sfe_mem_size_c() -> Int {
    poolWalkTotal(memorySizeWalker)
}

@_cdecl("sfe_mem_used")
public func sfe_mem_used_c() -> Int {
    poolWalkTotal(memoryUsedWalker)
}
