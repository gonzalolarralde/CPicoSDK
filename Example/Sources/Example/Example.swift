import CPicoSDK
import CPicoConcurrency
import ConcurrencyShims
import Synchronization
import PSRAM // Optional, only needed if using PSRAM.

@main
struct App: EmbeddedAsyncApp {
    static func configure(with configurator: inout Configurator) {
        // Enable only when the target hardware includes a PSRAM chip and PSRAM support is required.
        configurator.configure(PSRAMConfiguration())
    }

    static func setup() async {
        stdio_init_all()
        status_led_init()

        // Checking atomics
        let atomicBool = Atomic<Bool>(false)
        print("Atomic exchange: old=\(atomicBool.exchange(true, ordering: .sequentiallyConsistent)) new=\(atomicBool.load(ordering: .sequentiallyConsistent))")

        // Checking custom allocator
        print("Testing PSRAM allocator: ")
        if let mem = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 4, in: .psram) {
            print("Allocated 1024 bytes in PSRAM at \(String(UInt(bitPattern: mem), radix: 16))")
            mem.deallocate()
        } else {
            print("Failed to allocate memory in PSRAM.")
        }

        print("Testing PSRAM fallback: ")
        if let mem = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 4, in: .psramIfAvailable) {
            print("Allocated 1024 bytes in PSRAM or SRAM memory at \(String(UInt(bitPattern: mem), radix: 16))")
            mem.deallocate()
        } else {
            print("Failed to allocate memory in PSRAM or SRAM.")
        }

        print("Scheduling 1 second alarm...")
        sleep_ms(1000)
        print("One second!")

        // Keep one Unicode-aware string operation in the example so the finalizer
        // can demonstrate automatic linking of libswiftUnicodeDataTables when needed.
        print("Composed/decomposed match: \("Cafe\u{301}".contains("é"))")

        // Asset sample
        print("Embedded asset bytes: \(Asset.sample.data.count) at 0x\(String(UInt(bitPattern: Asset.sample.data.baseAddress!), radix: 16))")
        print("Embedded asset content: \(String(decoding: Asset.sample.data, as: UTF8.self))")

        print("Hello, world!")

        Foo.$bar.withValue("HelloWorld") {
            print("Task local value: \(Foo().getBar())")
        }

        cshims_tls_probe_run()
        cshims_threading_defer_probe_run()

        // Keep this pass focused on scheduler/core1 task execution. The LED
        // task uses Task.yield(), which exercises a separate embedded runtime
        // current-task/TLS failure path.

        if !CPUStats.enabled {
            print("CPU Usage metrics not enabled.")
        }

        if enableMulticoreSchedulerStress {
            startMulticoreSchedulerStress()
        } else {
            print("Skipping multicore scheduler stress")
        }

        // multicore_launch_core1(ledExample)
        // try! pioExample()
    }

    static func loop() async {
        let now = time_us_64()
        if now &- lastAppStatsPrintUs >= 1_000_000 {
            lastAppStatsPrintUs = now
            guard enableMulticoreSchedulerStress else {
                singleCoreLoopHits &+= 1
                print("singlecore c=\(get_core_num()) i=\(singleCoreLoopHits)")
                await Task.yield()
                return
            }
            enqueueRuntimeSchedulerMulticoreProbe()
            let stats = runtimeSchedulerMulticoreStats()
            #if CPUMetrics
            let cpu0 = runtimeSchedulerCPUUsageSnapshot(for: .core0)
            let cpu1 = runtimeSchedulerCPUUsageSnapshot(for: .core1)
            let c0t = cpu0.map { UInt32($0.taskUsagePercent) } ?? 0
            let c0i = cpu0.map { UInt32($0.interruptUsagePercent) } ?? 0
            let c0d = cpu0.map { UInt32($0.idleUsagePercent) } ?? 0
            let c1t = cpu1.map { UInt32($0.taskUsagePercent) } ?? 0
            let c1i = cpu1.map { UInt32($0.interruptUsagePercent) } ?? 0
            let c1d = cpu1.map { UInt32($0.idleUsagePercent) } ?? 0
            #else
            let c0t: UInt32 = 0
            let c0i: UInt32 = 0
            let c0d: UInt32 = 0
            let c1t: UInt32 = 0
            let c1i: UInt32 = 0
            let c1d: UInt32 = 0
            #endif
            print("app c=\(get_core_num()) q=\(stats.pushed) q0=\(stats.pushedCore0) q1=\(stats.pushedCore1) p0=\(stats.poppedCore0) p1=\(stats.poppedCore1) d0=\(stats.deferredCore0) d1=\(stats.deferredCore1) r0=\(stats.runCore0) r1=\(stats.runCore1) seed10=\(stats.core1SeedRunsOnCore0) seed11=\(stats.core1SeedRunsOnCore1) cpu0=\(c0t)/\(c0i)/\(c0d) cpu1=\(c1t)/\(c1i)/\(c1d) ta=\(stats.activeTasks) to0=\(stats.tasksOwnedCore0) to1=\(stats.tasksOwnedCore1) tn0=\(stats.newTaskCore0) tn1=\(stats.newTaskCore1) tr0=\(stats.reuseCore0) tr1=\(stats.reuseCore1) tw=\(stats.enqueueWhileRunning) ti=\(stats.taskIdle) te=\(stats.taskEvicted) tb=\(stats.activeEvictBlocked) tid1=\(stats.lastCore1TaskIDLow) tok1=\(String(stats.lastCore1OwnerToken, radix: 16)) tq1=\(stats.lastCore1QueuedCount) trn1=\(stats.lastCore1RunningCount) job1=\(String(stats.lastCore1JobAddress, radix: 16)) st=\(String(stats.lastSeedTaskAddress, radix: 16)) so=\(stats.lastSeedOwnerCore) sm=\(stats.core1SeedMigrations) ec=\(stats.lastEnqueueCore) ea=\(stats.lastEnqueueHadAsyncTask) ecur=\(stats.lastEnqueueHadCurrentTask) eo=\(stats.lastSelectedOwnerCore) f1=\(stats.forcedCore1SeedOwners) fp=\(stats.pendingCore1SeedOwnerForces) b1=\(stats.core1Boots) probe1=\(stats.core1Probes) full=\(stats.queueFull) null=\(stats.nullJobsDropped)")
        }
        await Task.yield()
    }
}

// MARK: Scheduler Stress

nonisolated(unsafe) var stressCore0Hits: UInt32 = 0
nonisolated(unsafe) var stressCore1Hits: UInt32 = 0
nonisolated(unsafe) var startStressWorkers = false
nonisolated(unsafe) var lastAppStatsPrintUs: UInt64 = 0
nonisolated(unsafe) var enableMulticoreSchedulerStress = true
nonisolated(unsafe) var singleCoreLoopHits: UInt32 = 0

func startMulticoreSchedulerStress() {
    print("Starting multicore scheduler stress")
    startRuntimeSchedulerMulticore()
    for _ in 0..<16 {
        enqueueRuntimeSchedulerMulticoreProbe()
    }

    // Keep the broader stress workers paused while validating whether the
    // forced core1 seed task can run without racing other root tasks onto core1.
    if startStressWorkers {
        for id in UInt32(0)..<4 {
            Task {
                await schedulerStressWorker(id: id)
            }
        }
    }
}

func schedulerStressWorker(id: UInt32) async {
    var iteration: UInt32 = 0
    var checksum: UInt32 = id &+ 1

    while true {
        for round in UInt32(0)..<250 {
            checksum = checksum &* 1_664_525 &+ 1_013_904_223 &+ id &+ round
        }

        if iteration % 128 == 0 {
            let core = get_core_num()
            if core == 0 {
                stressCore0Hits &+= 1
                let stats = runtimeSchedulerMulticoreStats()
                print("stress t=\(id) i=\(iteration) c=\(core) c0=\(stressCore0Hits) c1=\(stressCore1Hits) r0=\(stats.runCore0) r1=\(stats.runCore1) seed10=\(stats.core1SeedRunsOnCore0) seed11=\(stats.core1SeedRunsOnCore1) q1=\(stats.pushedCore1) p1=\(stats.poppedCore1) ta=\(stats.activeTasks) tn1=\(stats.newTaskCore1) tr1=\(stats.reuseCore1) tw=\(stats.enqueueWhileRunning) ti=\(stats.taskIdle) te=\(stats.taskEvicted) tb=\(stats.activeEvictBlocked) tid1=\(stats.lastCore1TaskIDLow) tok1=\(String(stats.lastCore1OwnerToken, radix: 16)) tq1=\(stats.lastCore1QueuedCount) trn1=\(stats.lastCore1RunningCount) st=\(String(stats.lastSeedTaskAddress, radix: 16)) so=\(stats.lastSeedOwnerCore) sm=\(stats.core1SeedMigrations) ec=\(stats.lastEnqueueCore) ea=\(stats.lastEnqueueHadAsyncTask) ecur=\(stats.lastEnqueueHadCurrentTask) eo=\(stats.lastSelectedOwnerCore) f1=\(stats.forcedCore1SeedOwners) fp=\(stats.pendingCore1SeedOwnerForces) n=\(stats.nullJobsDropped) k=\(checksum)")
            } else {
                stressCore1Hits &+= 1
            }
        }

        await Task.yield()
        iteration &+= 1
    }
}

// MARK: LED Example

func blinkLeds() async throws(CancellationError) {
    var last_state: Bool = false

    while true {
        status_led_set_state(last_state)
        last_state = !last_state
        try await Task.sleep(ms: 100)
    }
}

func blinkLedsWithBlockingSleep() {
    Task {
        var lastState = false
        while true {
            status_led_set_state(lastState)
            lastState = !lastState
            sleep_ms(100)
            await Task.yield()
        }
    }
}

@c
func ledExample() {
    var last_state = false

    while true {
        status_led_set_state(last_state)
        last_state = !last_state

        // In async contexts this is discouraged, as sleep_ms will
        // block the entire async context. This example works fine
        // when not using or expecting to use Concurrency features.
        sleep_ms(100)

        Task.tightLoop()
    }
}

// MARK: PIO Example

enum PIOError: Error {
    case noFreeStateMachine
    case pioNotResolved
}

// This is a reimplementation of hello_pio from pico-examples
// https://github.com/raspberrypi/pico-examples/blob/master/pio/hello_pio/hello.c
func pioExample() throws(PIOError) {
    // Note that this is not the LED pin, we will blink on GPIO 20 for this example.
    // Please connect something visible to see the effect!
    let pin: UInt32 = 20

    var pio: PIO?
    let sm: UInt32 = 0
    var offset: UInt32 = 0

    // ------------------------------------------------------
    // Option 1: Claim a free state machine and load the program automatically
    // ------------------------------------------------------

    // // This will find a free pio and state machine for our program and load it for us
    // // We use pio_claim_free_sm_and_add_program_for_gpio_range so we can address gpios >= 32 if needed and supported by the hardware
    // guard pio_claim_free_sm_and_add_program_for_gpio_range(hello.program, &pio, &sm, &offset, pin, 1, true) else {
    //     throw PIOError.noFreeStateMachine
    // }

    // guard let pio = pio else {
    //     throw PIOError.pioNotResolved
    // }

    // ------------------------------------------------------
    // Option 2: Manually use a specific PIO and state machine
    // ------------------------------------------------------

    // This is the manual way of doing the same as above
    pio = pio0
    guard let pio = pio else {
        throw PIOError.pioNotResolved
    }

    guard let newOffset = UInt32(exactly: pio_add_program(pio, hello.program)) else {
        throw PIOError.noFreeStateMachine
    }
    offset = newOffset

    // ------------------------------------------------------

    print("Loaded program at \(offset)")

    // Configure it to run our program, and start it, using the
    // helper function we included in our .pio file.
    hello.program_init(pio: pio, sm: sm, offset: offset, pin: pin);
    
    // The state machine is now running. Any value we push to its TX FIFO will
    // appear on the pin.
    // press a key to exit
    while (getchar_timeout_us(0) == PICO_ERROR_TIMEOUT.rawValue) {
        // Blink
        pio_sm_put_blocking(pio, sm, 1);
        sleep_ms(500);
        // Blonk
        pio_sm_put_blocking(pio, sm, 0);
        sleep_ms(500);
    }

    print("Pin \(pin) will stop blinking now.")

    // This will free resources and unload our program
    pio_remove_program_and_unclaim_sm(hello.program, pio, sm, offset);
}

struct Foo {
    @TaskLocal
    static var bar: String?

    func getBar() -> String {
        return Foo.bar ?? "no bar"
    }
}
