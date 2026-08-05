import Darwin
import Foundation

/// Transport for the (opt-in, default-off) Discord Rich Presence feature:
/// framing codec, wire serialization, and the socket lifecycle.
///
/// Nothing in this file is wired into the app yet — no production path
/// constructs a `DiscordIPCClient`, and the opt-in switch does not exist. The
/// transport ships one milestone ahead of the wiring on purpose: everything
/// here is hermetically testable, while "can it leak" only becomes answerable
/// once there is a switch to flip.
///
/// `DiscordPresence.Payload.fields` is the published surface. This file may
/// rename a key on the way out (Discord nests the asset key as
/// `assets.large_image`); it may not add a field, drop one, or alter a value.
/// `leafStrings(_:)` exists so that contract is asserted against the actual
/// serialized bytes rather than a hand-maintained list.
enum DiscordIPC {
    /// Public constant, not a secret. A Discord application id is visible to
    /// anyone who sees the presence; the client secret and bot token this
    /// feature does not need must never enter the repo or the bundle.
    static let applicationID = "1534085299163107348"

    /// Discord does not document a frame length limit, so this is ours. 64 KiB
    /// is ~50x the largest frame this client can provoke (a READY carrying a
    /// user object is well under 1 KiB) and small enough that a hostile
    /// endpoint cannot make us allocate anything interesting. The bound is
    /// checked before any allocation sized from the wire.
    static let maxFrameLength: UInt32 = 64 * 1024

    enum Opcode: UInt32 {
        case handshake = 0, frame = 1, close = 2, ping = 3, pong = 4
    }

    enum Failure: Error {
        /// Deliberately the only case: this error is not logged, and a richer
        /// one would only invite putting a path or an errno somewhere.
        case unavailable
    }

    // MARK: - Framing

    /// 4-byte little-endian opcode, 4-byte little-endian length, then `body`.
    static func encode(_ op: Opcode, _ body: Data) -> Data {
        var out = Data(capacity: 8 + body.count)
        withUnsafeBytes(of: op.rawValue.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    enum DecodeResult: Equatable {
        /// Not a whole frame yet; `buffer` is untouched.
        case needMore
        /// A complete frame with a known opcode and a parseable JSON body.
        case frame(Opcode, Data)
        /// Consumed and dropped: unknown opcode, or a body that is not valid
        /// UTF-8 JSON. Silent by design — logging the content of a frame from
        /// an endpoint we do not control is the thing we are avoiding.
        case discard
        /// The stream is not trustworthy; the caller must disconnect.
        case fatal
    }

    /// Consume one frame from the front of `buffer`.
    static func decode(from buffer: inout Data) -> DecodeResult {
        guard buffer.count >= 8 else { return .needMore }
        let base = buffer.startIndex
        let rawOpcode = readLE32(buffer, at: base)
        let length = readLE32(buffer, at: base + 4)
        // Before the buffer-completeness check, and before any allocation: a
        // 4 GiB length must be refused outright, not waited on.
        guard length <= maxFrameLength else { return .fatal }
        let total = 8 + Int(length)
        guard buffer.count >= total else { return .needMore }
        let body = Data(buffer[(base + 8)..<(base + total)])
        buffer.removeFirst(total)
        guard let op = Opcode(rawValue: rawOpcode) else { return .discard }
        // One validity check covers both malformed JSON and malformed UTF-8:
        // JSONSerialization rejects a body that is not valid UTF-8 as well.
        // A separate encoding check would be unreachable code pretending to be
        // a second guard.
        guard (try? JSONSerialization.jsonObject(with: body)) != nil else { return .discard }
        return .frame(op, body)
    }

    private static func readLE32(_ data: Data, at index: Data.Index) -> UInt32 {
        UInt32(data[index])
            | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16
            | UInt32(data[index + 3]) << 24
    }

    // MARK: - Serialization

    static func handshakeJSON() -> Data {
        serialize(["v": 1, "client_id": applicationID])
    }

    /// Map the published surface onto Discord's activity wire shape. `nil`
    /// clears the activity (`"activity":null`), which is what `stop()` sends
    /// before closing the socket.
    static func activityJSON(
        _ payload: DiscordPresence.Payload?, pid: Int32, nonce: String
    ) -> Data {
        var activity: Any = NSNull()
        if let payload {
            var fields: [String: Any] = [:]
            for (key, value) in payload.fields {
                // Renaming is allowed, adding is not. An unrecognized key goes
                // out under its own name rather than being dropped: the
                // contract says the transport must not drop a published field.
                if key == "largeImageKey" {
                    fields["assets"] = ["large_image": value]
                } else {
                    fields[key] = value
                }
            }
            activity = fields
        }
        return serialize([
            "cmd": "SET_ACTIVITY",
            "args": ["pid": Int(pid), "activity": activity],
            "nonce": nonce,
        ])
    }

    /// Every scalar leaf of a serialized frame, rendered as a string — numbers
    /// and booleans included, so that a field smuggled in as a number (a
    /// `startTimestamp`, a pid, a hostname hash) is just as visible to the
    /// privacy assertions as a string would be. Keys are not leaves, which is
    /// what keeps renaming a field legal — see `leafKeys` for the channel that
    /// costs, and why "adding is visible" is only true with both.
    ///
    /// It walks the real JSON, including nesting. A hand-written list of what
    /// "should" be in there asserts the author's memory, not the bytes.
    static func leafStrings(_ json: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(
            with: json, options: [.fragmentsAllowed]) else { return [] }
        var out: [String] = []
        func walk(_ any: Any) {
            switch any {
            case let dict as [String: Any]:
                for key in dict.keys.sorted() { walk(dict[key]!) }
            case let array as [Any]:
                for element in array { walk(element) }
            case let string as String:
                out.append(string)
            case is NSNull:
                out.append("null")
            default:
                out.append(String(describing: any))
            }
        }
        walk(root)
        return out
    }

    /// Every object key in a serialized frame, nesting included.
    ///
    /// `leafStrings` ignores keys on purpose, and that leaves the key itself as
    /// an unwatched channel: a frame carrying `"x-<hostname>": [:]` adds no
    /// leaf (an empty object has none) and changes no count at the levels that
    /// are counted, so every value-side assertion stays green while the
    /// hostname ships. Pinning the key set is what closes it, which is why
    /// both functions exist rather than one.
    static func leafKeys(_ json: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(
            with: json, options: [.fragmentsAllowed]) else { return [] }
        var out: [String] = []
        func walk(_ any: Any) {
            switch any {
            case let dict as [String: Any]:
                for key in dict.keys.sorted() {
                    out.append(key)
                    walk(dict[key]!)
                }
            case let array as [Any]:
                for element in array { walk(element) }
            default:
                break
            }
        }
        walk(root)
        return out
    }

    static let readyEvent = "ready"

    /// The only thing ever read out of an inbound frame, and the only string it
    /// can produce. A READY frame carries the Discord account's username, id
    /// and avatar; none of it may enter this process's state, its logs, or
    /// anything persisted. Returning a fixed token rather than the parsed
    /// object is the mechanism, not a stylistic choice.
    static func inbound(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["evt"] as? String == "READY" else { return "other" }
        return readyEvent
    }

    private static func serialize(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    // MARK: - Socket

    /// `nil` when the path does not fit in `sun_path`. Truncation must never be
    /// the fallback: a truncated `sun_path` does not fail, it connects to a
    /// *different* path.
    static func unixSocketAddress(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    /// Only `discord-ipc-0`. Probing `discord-ipc-1..9` would widen the set of
    /// endpoints a same-user process can squat on for no user-visible gain.
    static func connectToDiscord() throws -> Int32 {
        guard let dir = ProcessInfo.processInfo.environment["TMPDIR"] else {
            throw Failure.unavailable
        }
        let path = (dir as NSString).appendingPathComponent("discord-ipc-0")
        guard var addr = unixSocketAddress(path: path) else { throw Failure.unavailable }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unavailable }
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw Failure.unavailable
        }
        return fd
    }
}

/// Owns one Discord IPC connection: handshake, throttled publishing, bounded
/// reconnection, and a single kill switch.
///
/// All mutable state lives on `queue`, a serial utility queue — hence
/// `@unchecked Sendable`. Socket I/O must never run on the main thread or share
/// the tray's refresh Task.
final class DiscordIPCClient: @unchecked Sendable {
    /// Matches the reference implementation's `UPDATE_MIN_INTERVAL_MS`. Also a
    /// privacy floor: sampling frequency is what turns a presence into a
    /// working-hours trace, so this is not a performance knob to tune down.
    static let minPublishInterval: TimeInterval = 15
    /// `RECONNECT_DELAY_MS` in the reference implementation. Discord not
    /// running is the normal case, not an error worth retrying quickly.
    static let reconnectDelaySeconds: TimeInterval = 30
    /// Bounded on purpose: after ~2.5 minutes of CONSECUTIVE failures, stop. A
    /// presence is not worth a background loop that outlives the user's
    /// interest in it. The counter resets once a connection reaches READY, so
    /// a long session that watches Discord restart six times still reconnects.
    /// Without any reset the budget was per `start()` lifetime, which the user
    /// would experience as the presence silently never coming back; resetting
    /// on the socket open instead would reconnect forever against a peer that
    /// accepts and immediately drops.
    static let maxReconnectAttempts = 5

    /// A peer that accepts the socket and then says nothing must not hold the
    /// client connected-but-never-ready forever. `SO_RCVTIMEO` cannot cover
    /// this: the read source only calls `readAvailable()` when bytes arrive,
    /// so a silent endpoint never triggers a `recv()` and the socket timeout
    /// is never observed. Discord answers a handshake in milliseconds.
    static let readyTimeoutSeconds: TimeInterval = 10

    /// Instance-level so the selftest can shrink it. Production never assigns.
    var reconnectDelay: TimeInterval = DiscordIPCClient.reconnectDelaySeconds
    /// Instance-level so the selftest can assert on the bytes that reach the
    /// socket rather than on an internal flag. **Production never assigns**,
    /// and this is not a knob: the static it defaults to is a privacy floor,
    /// because publish frequency is what turns a presence into a working-hours
    /// trace. Lowering it in shipping code is a privacy regression, not tuning.
    var publishInterval: TimeInterval = DiscordIPCClient.minPublishInterval
    /// Instance-level for the same reason.
    var readyTimeout: TimeInterval = DiscordIPCClient.readyTimeoutSeconds

    private let connectFD: @Sendable () throws -> Int32
    private let queue = DispatchQueue(label: "com.nyanako.tokenbar.discord-ipc", qos: .utility)

    private var fd: Int32 = -1
    private var running = false
    private var ready = false
    private var buffer = Data()
    private var source: DispatchSourceRead?
    private var reconnectWork: DispatchWorkItem?
    private var throttleWork: DispatchWorkItem?
    private var readyWork: DispatchWorkItem?
    private var attempts = 0
    private var lastSent: DispatchTime?
    private var pending: DiscordPresence.Payload?
    /// What Discord currently holds, so `flush` can tell a fresh sample from a
    /// restore of bytes it already has.
    private var lastSentPayload: DiscordPresence.Payload?
    private var hasPending = false
    private var inboundToken = ""
    private var writeErrno: Int32 = 0

    init(connect: @escaping @Sendable () throws -> Int32) {
        self.connectFD = connect
    }

    // MARK: - Public surface

    /// Idempotent: a second call while running is a no-op, not a second socket.
    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.attempts = 0
            self.openConnection()
        }
    }

    /// The single kill switch: cancel every scheduled wake-up, clear the
    /// activity on Discord's side, then close the socket. Order matters — the
    /// clear cannot be sent through a closed socket.
    func stop() {
        queue.async {
            let wasRunning = self.running
            self.running = false
            self.reconnectWork?.cancel()
            self.throttleWork?.cancel()
            self.readyWork?.cancel()
            self.readyWork = nil
            // Cleared whether or not it was running. `giveUp()` deliberately
            // leaves `pending` behind so a later `start()` can restore, and a
            // `stop()` that bailed on `!running` would leave that payload
            // alive to be republished after the user turned the feature off.
            self.hasPending = false
            self.pending = nil
            self.lastSentPayload = nil
            if wasRunning, self.fd >= 0 {
                self.writeFrame(
                    .frame,
                    DiscordIPC.activityJSON(nil, pid: self.pid(), nonce: self.nonce()))
            }
            self.teardown()
        }
    }

    /// `nil` clears the activity. Coalescing, not queueing: only the newest
    /// payload is ever published.
    func publish(_ payload: DiscordPresence.Payload?) {
        queue.async {
            guard self.running else { return }
            self.pending = payload
            self.hasPending = true
            self.flush()
        }
    }

    // MARK: - Selftest seams
    //
    // Internal, not `#if DEBUG`: a symbol that exists only in one configuration
    // is a symbol that breaks the release build the first time someone calls it
    // without the guard.

    /// Blocks until everything already queued has run.
    func drainForTesting() { queue.sync {} }

    var isConnectedForTesting: Bool { queue.sync { fd >= 0 } }
    var inboundTokenForTesting: String { queue.sync { inboundToken } }
    var writeErrnoForTesting: Int32 { queue.sync { writeErrno } }
    var reconnectPendingForTesting: Bool {
        queue.sync { reconnectWork.map { !$0.isCancelled } ?? false }
    }

    /// Runs `breakPeer` and writes on the *same* queue item, so the read
    /// source's EOF handler cannot tear the connection down in between. That
    /// makes "write to a socket whose peer is gone" — the SIGPIPE case —
    /// deterministic instead of a race.
    ///
    /// Takes a closure rather than a descriptor: an earlier signature accepted
    /// an `Int32` and closed it, which is a `close()` on whatever number the
    /// caller passed. Ordering is the only thing this seam needs to own.
    func probeWriteForTesting(after breakPeer: @Sendable () -> Void) {
        queue.sync {
            breakPeer()
            writeFrame(.frame, DiscordIPC.activityJSON(nil, pid: pid(), nonce: nonce()))
        }
    }

    /// Drives the reconnect path directly so the "stopped means stopped"
    /// assertion does not have to wait for a real disconnect it can no longer
    /// provoke (after `stop()` there is no socket left to break).
    func scheduleReconnectForTesting() {
        queue.async { self.scheduleReconnect() }
    }

    // MARK: - Connection

    private func openConnection() {
        // The one place a connection can come into existence, and therefore the
        // one place that has to honour "after stop(), no path reconnects".
        //
        // There is deliberately no second `fd < 0` *guard* here: `start()`'s
        // `!running` guard is what keeps a live connection from being replaced,
        // and two guards for one invariant means neither can be shown to fail
        // on its own.
        guard running else { return }
        // Not a guard — a precondition made true. Reaching here with a live fd
        // would overwrite `fd` and `source` without cancelling the old source,
        // leaking the descriptor while libdispatch kept firing on it. That was
        // reachable from `scheduleReconnectForTesting`, and would be reachable
        // from any future caller too, so it is closed here at the one place a
        // connection is born rather than at each call site.
        if fd >= 0 { teardown() }
        guard let newFD = try? connectFD() else {
            scheduleReconnect()
            return
        }
        // Immediately, before any write can happen: Darwin's default for a
        // write to a closed socket is SIGPIPE, which kills the whole app, and
        // Discord quitting mid-session is ordinary.
        //
        // The return value is checked because this call really can fail — it
        // returns EINVAL on a socket whose peer has already gone away, which is
        // reachable if Discord dies between `connect()` and here. A socket we
        // could not make SIGPIPE-safe is not one we are willing to write to, so
        // it is dropped rather than used.
        var on: Int32 = 1
        guard setsockopt(
            newFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            close(newFD)
            scheduleReconnect()
            return
        }
        // Backstop against a peer that opens the socket and then says nothing.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(newFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(newFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        fd = newFD
        buffer.removeAll()
        ready = false

        let readSource = DispatchSource.makeReadSource(fileDescriptor: newFD, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        // Closing in the cancel handler, not beside `cancel()`: the source may
        // still be about to run its event handler on this fd.
        readSource.setCancelHandler { close(newFD) }
        source = readSource
        readSource.resume()

        writeFrame(.handshake, DiscordIPC.handshakeJSON())
        armReadyDeadline()
    }

    /// An endpoint that accepts the socket and then stays silent would
    /// otherwise hold the client connected-but-never-ready forever, with every
    /// publish parked behind `ready`. `SO_RCVTIMEO` does not cover it: the read
    /// source only fires when bytes arrive, so no `recv()` ever runs on an idle
    /// socket and its timeout is never observed.
    private func armReadyDeadline() {
        readyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, !self.ready, self.fd >= 0 else { return }
            self.handleDisconnect()
        }
        readyWork = work
        queue.asyncAfter(deadline: .now() + readyTimeout, execute: work)
    }

    private func scheduleReconnect() {
        guard attempts < Self.maxReconnectAttempts else {
            // The budget is spent, so go back to the stopped state instead of
            // sitting in `running` with nothing scheduled. Leaving it true
            // made a later `start()` hit the idempotence guard and silently do
            // nothing, which turned a bounded retry into a permanent dead
            // client for anything started once at launch. `pending` is kept:
            // a later `start()` should republish what was last intended.
            giveUp()
            return
        }
        attempts += 1
        let work = DispatchWorkItem { [weak self] in self?.openConnection() }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + reconnectDelay, execute: work)
    }

    /// Not `stop()`: there is no socket left to send a clear on, and this is
    /// not the user asking to stop. It only returns the client to a state a
    /// later `start()` can act on.
    private func giveUp() {
        running = false
        attempts = 0
        throttleWork?.cancel()
        throttleWork = nil
        reconnectWork?.cancel()
        reconnectWork = nil
        teardown()
    }

    private func teardown() {
        ready = false
        readyWork?.cancel()
        readyWork = nil
        buffer.removeAll()
        fd = -1
        if let source {
            source.cancel()
            self.source = nil
        }
    }

    private func handleDisconnect() {
        teardown()
        if running { scheduleReconnect() }
    }

    // MARK: - Reading

    private func readAvailable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &chunk, chunk.count, 0)
        if count == 0 { handleDisconnect(); return }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { return }
            handleDisconnect()
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        while true {
            switch DiscordIPC.decode(from: &buffer) {
            case .needMore:
                return
            case .discard:
                continue
            case .fatal:
                handleDisconnect()
                return
            case .frame(let op, let body):
                switch op {
                case .ping:
                    // The protocol wants the ping's own body echoed back. These
                    // are the peer's bytes going to the peer that sent them:
                    // nothing local is added, nothing is retained, and the
                    // length is already bounded by `maxFrameLength`. Do not
                    // "improve" this into something that reads or logs `body`.
                    writeFrame(.pong, body)
                case .close:
                    handleDisconnect()
                    return
                default:
                    inboundToken = DiscordIPC.inbound(body)
                    if inboundToken == DiscordIPC.readyEvent {
                        ready = true
                        // The retry budget resets HERE, not when `connect()`
                        // returns. A socket that opens and dies before the
                        // handshake — Discord running but refusing us — is
                        // still a failed attempt; resetting on the open would
                        // let that case reconnect at `reconnectDelay` forever,
                        // which is the unbounded background loop
                        // `maxReconnectAttempts` exists to prevent.
                        attempts = 0
                        readyWork?.cancel()
                        readyWork = nil
                        // A replacement connection starts with no activity on
                        // Discord's side, so whatever we last intended has to
                        // go out again. Without this the presence stays
                        // missing after a Discord restart until some later
                        // producer update — up to the tray's 5-minute poll.
                        if pending != nil { hasPending = true }
                        flush()
                    }
                }
            }
        }
    }

    // MARK: - Writing

    private func flush() {
        guard running, ready, hasPending, fd >= 0 else { return }
        // The floor limits how often NEW information is published — sampling
        // frequency is what turns a presence into a working-hours trace. Two
        // cases carry none, and making them wait points the rule backwards:
        //   - a clear removes information rather than adding it, and delaying
        //     one keeps a stale presence public for up to 15s after the user
        //     hid the clients that produced it;
        //   - a restore after a reconnect re-sends bytes Discord already had,
        //     so it discloses nothing a fresh sample would.
        let carriesNewInformation = pending != nil && pending != lastSentPayload
        if carriesNewInformation, let lastSent {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastSent.uptimeNanoseconds)
                / 1_000_000_000
            if elapsed < publishInterval {
                // Deferred, not dropped: hiding a client has to reach the
                // published presence in the same turn, and dropping the update
                // would leave it visible until the next poll.
                let work = DispatchWorkItem { [weak self] in self?.flush() }
                throttleWork?.cancel()
                throttleWork = work
                queue.asyncAfter(
                    deadline: .now() + (publishInterval - elapsed), execute: work)
                return
            }
        }
        // Cleared only once the bytes are actually out. A write that fails
        // tears the connection down, and marking the payload sent beforehand
        // meant the newest activity was lost with the socket: the next READY
        // saw `hasPending == false` and published nothing, leaving the
        // presence stale until some later producer update. The throttle clock
        // only advances on success for the same reason — a failed send must
        // not consume the 15s window.
        if writeFrame(.frame, DiscordIPC.activityJSON(pending, pid: pid(), nonce: nonce())) {
            hasPending = false
            lastSent = .now()
            lastSentPayload = pending
        }
    }

    @discardableResult
    private func writeFrame(_ op: DiscordIPC.Opcode, _ body: Data) -> Bool {
        guard fd >= 0 else { return false }
        let frame = DiscordIPC.encode(op, body)
        let socketFD = fd
        var failed = false
        frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = send(socketFD, raw.baseAddress! + offset, raw.count - offset, 0)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                writeErrno = errno
                failed = true
                return
            }
        }
        if failed { handleDisconnect() }
        return !failed
    }

    private func pid() -> Int32 { ProcessInfo.processInfo.processIdentifier }
    private func nonce() -> String { UUID().uuidString }
}
