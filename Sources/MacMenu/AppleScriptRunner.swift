import Cocoa
import ApplicationServices

/// Runs Apple Events off the main thread, with a deadline, and never on a
/// thread that can be blocked by a TCC consent dialog.
///
/// Two hazards this exists for:
///
///   1. `NSAppleScript.executeAndReturnError` is synchronous and its Apple
///      Event carries the default 60-second timeout. A busy browser running
///      the Change Case JavaScript could park the calling thread for a minute.
///   2. The *first* Apple Event to a given app presents macOS's Automation
///      consent dialog and does not return until the user answers it.
///
/// Both used to happen on the main thread while an active event tap was
/// attached to the same run loop. `AEDeterminePermissionToAutomateTarget`
/// (asking with `askUserIfNeeded: false`) now answers the permission question
/// without any possibility of blocking, and the script itself runs on a single
/// dedicated thread that owns every `NSAppleScript` in this process, with the
/// caller waiting only as long as it is willing to.
///
/// NSAppleScript is not thread-safe; confining all of it to `thread` is what
/// makes this safe. Never execute an NSAppleScript anywhere else.
enum AppleScriptRunner {

    enum Permission {
        /// The user has already approved automating this app.
        case granted
        /// The user has refused, or the app is not running.
        case denied
        /// macOS has never asked. Asking blocks, so callers kick off a prompt
        /// on the runner thread and give up on this press.
        case undetermined
    }

    enum Outcome {
        /// The script ran. `errorNumber` is 0 when it succeeded.
        case completed(descriptor: NSAppleEventDescriptor?, errorNumber: Int, errorMessage: String?)
        /// The script did not finish within the caller's deadline. It keeps
        /// running on the runner thread; its result is discarded.
        case timedOut
        /// Another script is still running (typically parked on a consent
        /// dialog). Queuing behind it could block for an unbounded time.
        case busy
    }

    // MARK: - Permission

    /// Whether we may send Apple Events to `bundleID`, asked in the one way
    /// that cannot block: `askUserIfNeeded: false`.
    static func permission(forBundleID bundleID: String) -> Permission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let aeDesc = target.aeDesc else { return .denied }
        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .undetermined
        default:
            // errAEEventNotPermitted (-1743), procNotFound, and anything else
            // we cannot act on.
            return .denied
        }
    }

    /// Fire-and-forget: let macOS show its Automation consent dialog on the
    /// runner thread. Returns immediately; the current hotkey press is lost,
    /// the next one benefits.
    static func requestPermissionInBackground(forBundleID bundleID: String) {
        guard beginJob() else { return }
        submit {
            defer { endJob() }
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            guard let aeDesc = target.aeDesc else { return }
            _ = AEDeterminePermissionToAutomateTarget(
                aeDesc, typeWildCard, typeWildCard, true)
        }
    }

    // MARK: - Execution

    /// Execute `script` on the runner thread, waiting at most `timeout`.
    ///
    /// `script` is built *inside* the job so that the NSAppleScript instance is
    /// created and used on the same thread.
    static func run(
        timeout: TimeInterval,
        script: @escaping () -> NSAppleScript?
    ) -> Outcome {
        guard beginJob() else { return .busy }

        let semaphore = DispatchSemaphore(value: 0)
        // Written on the runner thread, read by the caller only after the
        // semaphore is signalled (or never, on timeout).
        final class Box: @unchecked Sendable {
            var descriptor: NSAppleEventDescriptor?
            var errorNumber = 0
            var errorMessage: String?
        }
        let box = Box()

        submit {
            defer {
                endJob()
                semaphore.signal()
            }
            guard let compiled = script() else {
                box.errorNumber = -1
                box.errorMessage = "could not build AppleScript"
                return
            }
            var errorInfo: NSDictionary?
            let result = compiled.executeAndReturnError(&errorInfo)
            if let errorInfo = errorInfo {
                box.errorNumber = (errorInfo[NSAppleScript.errorNumber] as? Int)
                    ?? (errorInfo["NSAppleScriptErrorNumber"] as? Int) ?? 0
                box.errorMessage = (errorInfo[NSAppleScript.errorMessage] as? String)
                    ?? (errorInfo["NSAppleScriptErrorMessage"] as? String)
                    ?? "unknown AppleScript error"
            } else {
                box.descriptor = result
            }
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            NSLog("[Menu du Jour] AppleScript exceeded its %.1fs deadline — abandoning", timeout)
            return .timedOut
        }
        return .completed(
            descriptor: box.descriptor,
            errorNumber: box.errorNumber,
            errorMessage: box.errorMessage
        )
    }

    // MARK: - The runner thread

    private static let jobLock = NSLock()
    private static var jobInFlight = false

    /// One script at a time. A job parked on a consent dialog must not make
    /// later presses queue up behind it.
    private static func beginJob() -> Bool {
        jobLock.lock()
        defer { jobLock.unlock() }
        if jobInFlight { return false }
        jobInFlight = true
        return true
    }

    private static func endJob() {
        jobLock.lock()
        jobInFlight = false
        jobLock.unlock()
    }

    private final class Job: NSObject {
        let work: () -> Void
        init(_ work: @escaping () -> Void) { self.work = work }
    }

    private final class Executor: NSObject {
        // NSAppleScript and the NSAppleEventDescriptor results it returns are
        // autoreleased Cocoa objects, and this thread is permanent: with no
        // pool of its own they would accumulate for the life of the app.
        @objc func execute(_ job: Job) {
            autoreleasepool { job.work() }
        }
    }

    private static let executor = Executor()

    /// `perform(_:on:...)` delivers through the target thread's run loop, so a
    /// job submitted before that run loop exists can be lost. The first
    /// submitter waits here for the thread to say it is listening.
    private static let runLoopReady = DispatchSemaphore(value: 0)

    private static let thread: Thread = {
        let thread = Thread {
            // A port keeps the run loop alive with no other input sources.
            let keepAlive = NSMachPort()
            RunLoop.current.add(keepAlive, forMode: .default)
            runLoopReady.signal()
            while !Thread.current.isCancelled {
                autoreleasepool {
                    _ = RunLoop.current.run(mode: .default, before: .distantFuture)
                }
            }
        }
        thread.name = "com.luca.menudujour.applescript"
        thread.qualityOfService = .userInitiated
        thread.start()
        return thread
    }()

    private static let startOnce: Void = {
        _ = thread
        // Bounded: if the thread cannot start, jobs will time out rather than
        // hang the caller here.
        _ = runLoopReady.wait(timeout: .now() + 2.0)
    }()

    private static func submit(_ work: @escaping () -> Void) {
        _ = startOnce
        executor.perform(
            #selector(Executor.execute(_:)),
            on: thread,
            with: Job(work),
            waitUntilDone: false
        )
    }
}
