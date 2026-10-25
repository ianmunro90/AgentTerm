import Foundation
import Network

/// A mosh client: the State Synchronization Protocol over UDP, ported from mosh's
/// Network::Connection, TransportSender and Transport (mosh/src/network). The client's state is
/// its stream of keystrokes/resizes; the server's state is the screen (MoshFramebuffer).
/// All work happens on a private serial queue; callbacks arrive on the main queue.
final class MoshClient {
    enum Event {
        case frame(MoshFramebuffer)
        /// Milliseconds since the server was last heard from (sent about once a second).
        case contact(sinceLastHeard: UInt64)
        case closed(String?)
    }

    // Timing constants from transportsender.h / network.h.
    private let sendIntervalMin = 20.0, sendIntervalMax = 250.0
    private let ackInterval: UInt64 = 3000, ackDelay: UInt64 = 100
    private let activeRetryTimeout: UInt64 = 10000, sendMinDelay: UInt64 = 1
    private let portHopInterval: UInt64 = 10000
    private let shutdownRetries = 16
    private let maxFragmentPayload = 1000

    private let queue = DispatchQueue(label: "agentterm.mosh")
    private let crypto: MoshCrypto
    private let endpoint: NWEndpoint
    private let onEvent: (Event) -> Void
    private var timer: DispatchSourceTimer?
    private var finished = false
    /// Set by close(): the owner drops its reference straight away, but the client must live
    /// until the server has acknowledged the shutdown (or retries run out), or the server lingers.
    private var keepAliveUntilFinished: MoshClient?

    // Connection layer
    private var connections: [NWConnection] = []
    private var nextSequence: UInt64 = 0
    private var expectedReceiverSequence: UInt64 = 0
    private var savedTimestamp = -1
    private var savedTimestampReceivedAt: UInt64 = 0
    private var srtt = 1000.0, rttvar = 500.0, rttHit = false
    private var lastHeard: UInt64 = 0
    private var lastPortChoice: UInt64
    private var lastRoundtripSuccess: UInt64 = 0
    private var lastContactReport: UInt64 = 0

    // Sender: the user stream as an event log; a "state" is a count of events.
    private struct SentState {
        var timestamp: UInt64
        var num: UInt64
        var eventCount: Int
    }

    private var events: [MoshUserEvent] = []
    private var eventBase = 0
    private var sentStates: [SentState]
    private var assumedIndex = 0
    private var ackNum: UInt64 = 0
    private var pendingDataAck = false
    private var nextAckTime: UInt64
    private var nextSendTime: UInt64 = .max
    private var mindelayClock: UInt64 = .max
    private var senderLastHeard: UInt64 = 0
    private var nextInstructionID: UInt64 = 0
    private var shutdownInProgress = false
    private var shutdownTries = 0
    private var shutdownStart: UInt64 = 0

    // Receiver
    private struct ReceivedState {
        var num: UInt64
        var frame: MoshFramebuffer
    }

    private var receivedStates: [ReceivedState]
    private var fragmentID: UInt64?
    private var fragments: [Int: [UInt8]] = [:]
    private var fragmentsTotal: Int?

    private var currentEventCount: Int { eventBase + events.count }

    /// - Parameters: `host`/`port`/`key` come from `MOSH CONNECT <port> <key>`.
    init(host: String, port: UInt16, key: String, cols: Int, rows: Int, onEvent: @escaping (Event) -> Void) throws {
        crypto = try MoshCrypto(printableKey: key)
        endpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        self.onEvent = onEvent
        let now = Self.now()
        lastPortChoice = now
        nextAckTime = now
        sentStates = [SentState(timestamp: now, num: 0, eventCount: 0)]
        // mosh-server started without a tty begins at 80x24; our state 0 must match it exactly.
        receivedStates = [ReceivedState(num: 0, frame: MoshFramebuffer(width: 80, height: 24))]
        events.append(.resize(cols: cols, rows: rows))
    }

    deinit {
        EventLog.record("mosh client deinit finished=\(finished)")
    }

    func start() {
        queue.async {
            self.openConnection()
            self.tick()
        }
    }

    func send(_ bytes: [UInt8]) {
        queue.async {
            guard !self.finished, !self.shutdownInProgress else { return }
            self.events.append(.keys(bytes))
            self.tick()
        }
    }

    func resize(cols: Int, rows: Int) {
        queue.async {
            guard !self.finished, !self.shutdownInProgress else { return }
            self.events.append(.resize(cols: cols, rows: rows))
            self.tick()
        }
    }

    /// Call when the app returns to the foreground: the old socket may be dead after suspension,
    /// so move to a fresh local port (the server follows the client's new address).
    func wake() {
        queue.async {
            guard !self.finished else { return }
            self.hopPort()
            self.tick()
        }
    }

    /// Asks the server to exit (mosh's shutdown handshake), then closes.
    func close() {
        queue.async {
            guard !self.finished else { return }
            if self.shutdownInProgress { return }
            EventLog.record("mosh close requested")
            self.keepAliveUntilFinished = self
            self.shutdownInProgress = true
            self.shutdownStart = Self.now()
            self.tick()
        }
    }

    // MARK: Timing (TransportSender::calculate_timers / tick)

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private var sendInterval: UInt64 {
        UInt64(min(max(ceil(srtt / 2), sendIntervalMin), sendIntervalMax))
    }

    private var timeout: UInt64 {
        UInt64(min(max(ceil(srtt + 4 * rttvar), 50), 1000))
    }

    private func calculateTimers() {
        let now = Self.now()
        // update_assumed_receiver_state
        assumedIndex = 0
        for index in 1..<sentStates.count {
            if now - sentStates[index].timestamp < timeout + ackDelay {
                assumedIndex = index
            } else {
                break
            }
        }
        // rationalize_states: forget events the receiver is known to have
        let known = sentStates[0].eventCount
        if known > eventBase {
            events.removeFirst(known - eventBase)
            eventBase = known
        }

        if pendingDataAck, nextAckTime > now + ackDelay {
            nextAckTime = now + ackDelay
        }
        let last = sentStates[sentStates.count - 1]
        if currentEventCount != last.eventCount {
            if mindelayClock == .max { mindelayClock = now }
            nextSendTime = max(mindelayClock + sendMinDelay, last.timestamp + sendInterval)
        } else if currentEventCount != sentStates[assumedIndex].eventCount, senderLastHeard + activeRetryTimeout > now {
            nextSendTime = last.timestamp + sendInterval
            if mindelayClock != .max { nextSendTime = max(nextSendTime, mindelayClock + sendMinDelay) }
        } else if currentEventCount != sentStates[0].eventCount, senderLastHeard + activeRetryTimeout > now {
            nextSendTime = last.timestamp + timeout + ackDelay
        } else {
            nextSendTime = .max
        }
        if shutdownInProgress || ackNum == .max {
            nextAckTime = last.timestamp + sendInterval
        }
    }

    private func tick() {
        guard !finished else { return }
        calculateTimers()
        let now = Self.now()

        if shutdownInProgress {
            if sentStates[0].num == .max || shutdownTries >= shutdownRetries || now - shutdownStart >= activeRetryTimeout {
                finish(nil)
                return
            }
        }

        if now >= nextAckTime || now >= nextSendTime {
            var diff = diffFrom(sentStates[assumedIndex].eventCount)
            // attempt_prospective_resend_optimization
            if assumedIndex != 0 {
                let resend = diffFrom(sentStates[0].eventCount)
                if resend.count <= diff.count || (resend.count < 1000 && resend.count - diff.count < 100) {
                    assumedIndex = 0
                    diff = resend
                }
            }
            if diff.isEmpty {
                if now >= nextAckTime {
                    sendEmptyAck()
                    mindelayClock = .max
                }
                if now >= nextSendTime {
                    nextSendTime = .max
                    mindelayClock = .max
                }
            } else {
                sendToReceiver(diff)
                mindelayClock = .max
            }
        }

        reportContact(now)
        scheduleTimer()
    }

    private func scheduleTimer() {
        calculateTimers()
        let now = Self.now()
        let next = min(nextAckTime, nextSendTime)
        let wait = next > now ? min(next - now, 1000) : 0
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            timer = source
        }
        timer?.schedule(deadline: .now() + .milliseconds(Int(max(wait, 1))))
    }

    private func reportContact(_ now: UInt64) {
        guard now - lastContactReport >= 1000 else { return }
        lastContactReport = now
        let since = lastHeard == 0 ? now - lastPortChoice : now - lastHeard
        emit(.contact(sinceLastHeard: since))
    }

    // MARK: Sending

    private func diffFrom(_ eventCount: Int) -> [UInt8] {
        let start = eventCount - eventBase
        guard start >= 0, start < events.count else { return [] }
        return MoshUserEvent.encode(events[start...])
    }

    private func addSentState(_ state: SentState) {
        sentStates.append(state)
        if sentStates.count > 32 {
            sentStates.remove(at: sentStates.count - 16)
        }
    }

    private func sendEmptyAck() {
        let now = Self.now()
        let num = shutdownInProgress ? UInt64.max : sentStates[sentStates.count - 1].num + 1
        addSentState(SentState(timestamp: now, num: num, eventCount: currentEventCount))
        sendInFragments([], newNum: num)
        nextAckTime = now + ackInterval
        nextSendTime = .max
    }

    private func sendToReceiver(_ diff: [UInt8]) {
        let now = Self.now()
        let last = sentStates[sentStates.count - 1]
        var num = currentEventCount == last.eventCount ? last.num : last.num + 1
        if shutdownInProgress { num = .max }
        if num == last.num {
            sentStates[sentStates.count - 1].timestamp = now
        } else {
            addSentState(SentState(timestamp: now, num: num, eventCount: currentEventCount))
        }
        sendInFragments(diff, newNum: num)
        assumedIndex = sentStates.count - 1
        nextAckTime = now + ackInterval
        nextSendTime = .max
    }

    private func sendInFragments(_ diff: [UInt8], newNum: UInt64) {
        var instruction = MoshInstruction()
        instruction.oldNum = sentStates[assumedIndex].num
        instruction.newNum = newNum
        instruction.ackNum = ackNum
        instruction.throwawayNum = sentStates[0].num
        instruction.diff = diff
        instruction.chaff = (0..<Int.random(in: 0...16)).map { _ in UInt8.random(in: 0...255) }
        if newNum == .max { shutdownTries += 1 }

        guard let payload = try? MoshZlib.compress(instruction.encoded()) else { return }
        // Chaff makes every instruction distinct, so every send gets a new fragment id (as in mosh).
        nextInstructionID += 1
        var chunks = stride(from: 0, to: payload.count, by: maxFragmentPayload).map {
            Array(payload[$0..<min($0 + maxFragmentPayload, payload.count)])
        }
        if chunks.isEmpty { chunks = [[]] }
        for (index, chunk) in chunks.enumerated() {
            let final: UInt16 = index == chunks.count - 1 ? 0x8000 : 0
            let header = nextInstructionID.bigEndianBytes + [UInt8((final | UInt16(index)) >> 8), UInt8(index & 0xFF)]
            sendPacket(header + chunk)
        }
        pendingDataAck = false
    }

    private func sendPacket(_ payload: [UInt8]) {
        let now = Self.now()
        if now - lastPortChoice > portHopInterval, now - lastRoundtripSuccess > portHopInterval {
            hopPort()
        }
        var reply: UInt16 = 0xFFFF
        if savedTimestamp >= 0, now - savedTimestampReceivedAt < 1000 {
            reply = UInt16(truncatingIfNeeded: savedTimestamp + Int(now - savedTimestampReceivedAt))
            savedTimestamp = -1
            savedTimestampReceivedAt = 0
        }
        let timestamp = UInt16(truncatingIfNeeded: now)
        let plaintext = [UInt8(timestamp >> 8), UInt8(timestamp & 0xFF), UInt8(reply >> 8), UInt8(reply & 0xFF)] + payload
        let datagram = crypto.encrypt(sequence: nextSequence, plaintext: plaintext)
        nextSequence += 1
        connections.last?.send(content: Data(datagram), completion: .idempotent)
    }

    // MARK: Sockets

    private func openConnection() {
        let connection = NWConnection(to: endpoint, using: .udp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state {
                self.queue.async {
                    self.connections.removeAll { $0 === connection }
                    if self.connections.isEmpty, !self.finished { self.openConnection() }
                }
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
        connections.append(connection)
        // Keep a couple of old sockets so late replies still arrive (mosh keeps up to 10).
        while connections.count > 3 {
            connections.removeFirst().cancel()
        }
    }

    private func hopPort() {
        lastPortChoice = Self.now()
        openConnection()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self else { return }
            if let data { self.handleDatagram(Array(data)) }
            if error == nil, let connection, !self.finished {
                self.receive(on: connection)
            }
        }
    }

    // MARK: Receiving (Connection::recv_one, Transport::recv)

    private func handleDatagram(_ datagram: [UInt8]) {
        guard !finished, let (nonce, plaintext) = try? crypto.decrypt(datagram) else { return }
        guard nonce & MoshCrypto.directionToClient != 0, plaintext.count >= 4 else { return }
        let sequence = nonce & ~MoshCrypto.directionToClient
        let timestamp = UInt16(plaintext[0]) << 8 | UInt16(plaintext[1])
        let timestampReply = UInt16(plaintext[2]) << 8 | UInt16(plaintext[3])
        let now = Self.now()

        if sequence >= expectedReceiverSequence {
            expectedReceiverSequence = sequence + 1
            if timestamp != 0xFFFF {
                savedTimestamp = Int(timestamp)
                savedTimestampReceivedAt = now
            }
            if timestampReply != 0xFFFF {
                let r = Double(UInt16(truncatingIfNeeded: now) &- timestampReply)
                if r < 5000 {
                    if !rttHit {
                        srtt = r
                        rttvar = r / 2
                        rttHit = true
                    } else {
                        rttvar = 0.75 * rttvar + 0.25 * abs(srtt - r)
                        srtt = 0.875 * srtt + 0.125 * r
                    }
                }
            }
            lastHeard = now
        }

        let payload = Array(plaintext[4...])
        guard payload.count >= 10 else { return }
        let id = UInt64(bigEndianBytes: payload[0..<8])
        let combined = UInt16(payload[8]) << 8 | UInt16(payload[9])
        let number = Int(combined & 0x7FFF)
        if fragmentID != id {
            fragmentID = id
            fragments = [:]
            fragmentsTotal = nil
        }
        fragments[number] = Array(payload[10...])
        if combined & 0x8000 != 0 { fragmentsTotal = number + 1 }
        guard let total = fragmentsTotal, fragments.count == total else { return }
        let assembled = (0..<total).flatMap { fragments[$0] ?? [] }
        fragmentID = nil
        fragments = [:]
        fragmentsTotal = nil

        guard let decompressed = try? MoshZlib.uncompress(assembled),
              let instruction = try? MoshInstruction(decoding: decompressed)
        else { return }
        process(instruction)
        tick()
    }

    private func process(_ instruction: MoshInstruction) {
        guard instruction.protocolVersion == 2 else {
            finish("mosh protocol version mismatch (server speaks \(instruction.protocolVersion))")
            return
        }
        // process_acknowledgment_through
        if sentStates.contains(where: { $0.num == instruction.ackNum }) {
            sentStates.removeAll { $0.num < instruction.ackNum }
        }
        lastRoundtripSuccess = sentStates[0].timestamp

        guard !receivedStates.contains(where: { $0.num == instruction.newNum }),
              let reference = receivedStates.first(where: { $0.num == instruction.oldNum })
        else { return }

        // process_throwaway_until
        if receivedStates.contains(where: { $0.num >= instruction.throwawayNum }) {
            receivedStates.removeAll { $0.num < instruction.throwawayNum }
        }
        guard receivedStates.count <= 1024 else { return }

        var state = ReceivedState(num: instruction.newNum, frame: reference.frame)
        if !instruction.diff.isEmpty {
            guard let hostInstructions = try? MoshHostInstruction.decode(instruction.diff) else { return }
            for hostInstruction in hostInstructions {
                switch hostInstruction {
                case .hostBytes(let bytes): state.frame.apply(bytes)
                case .resize(let cols, let rows): state.frame.resize(width: cols, height: rows)
                case .echoAck: break
                }
            }
        }

        if let later = receivedStates.firstIndex(where: { $0.num > state.num }) {
            receivedStates.insert(state, at: later)
            return
        }
        receivedStates.append(state)
        ackNum = state.num
        senderLastHeard = Self.now()
        if !instruction.diff.isEmpty { pendingDataAck = true }

        if state.num == .max {
            // The server's shell exited: acknowledge, then stop.
            sendEmptyAck()
            finish("session ended")
            return
        }
        emit(.frame(state.frame))
    }

    // MARK: Lifecycle

    private func finish(_ message: String?) {
        guard !finished else { return }
        finished = true
        EventLog.record("mosh finish message=\(message ?? "nil") shutdownAcked=\(sentStates[0].num == .max) tries=\(shutdownTries)")
        timer?.cancel()
        timer = nil
        connections.forEach { $0.cancel() }
        connections = []
        emit(.closed(message))
        keepAliveUntilFinished = nil
    }

    private func emit(_ event: Event) {
        let onEvent = self.onEvent
        DispatchQueue.main.async { onEvent(event) }
    }
}
