import Foundation

// Hand-rolled encoders/decoders for mosh's three protobuf (proto2) messages, so the app
// doesn't need a protobuf runtime. Field numbers are from mosh/src/protobufs/*.proto.

/// TransportBuffers.Instruction
struct MoshInstruction {
    var protocolVersion: UInt64 = 2
    var oldNum: UInt64 = 0
    var newNum: UInt64 = 0
    var ackNum: UInt64 = 0
    var throwawayNum: UInt64 = 0
    var diff: [UInt8] = []
    var chaff: [UInt8] = []

    func encoded() -> [UInt8] {
        var w = ProtoWriter()
        w.varint(field: 1, protocolVersion)
        w.varint(field: 2, oldNum)
        w.varint(field: 3, newNum)
        w.varint(field: 4, ackNum)
        w.varint(field: 5, throwawayNum)
        w.bytes(field: 6, diff)
        w.bytes(field: 7, chaff)
        return w.output
    }

    init() {}

    init(decoding bytes: [UInt8]) throws {
        var r = ProtoReader(bytes)
        while let (field, value) = try r.next() {
            switch (field, value) {
            case (1, .varint(let v)): protocolVersion = v
            case (2, .varint(let v)): oldNum = v
            case (3, .varint(let v)): newNum = v
            case (4, .varint(let v)): ackNum = v
            case (5, .varint(let v)): throwawayNum = v
            case (6, .bytes(let b)): diff = b
            case (7, .bytes(let b)): chaff = b
            default: break
            }
        }
    }
}

/// One user-side event; consecutive keystrokes are merged when encoded, like UserStream::diff_from.
enum MoshUserEvent: Equatable {
    case keys([UInt8])
    case resize(cols: Int, rows: Int)

    /// ClientBuffers.UserMessage
    static func encode(_ events: ArraySlice<MoshUserEvent>) -> [UInt8] {
        var message = ProtoWriter()
        var pendingKeys = [UInt8]()

        func flushKeys() {
            guard !pendingKeys.isEmpty else { return }
            var keystroke = ProtoWriter()
            keystroke.bytes(field: 4, pendingKeys)
            var instruction = ProtoWriter()
            instruction.bytes(field: 2, keystroke.output)
            message.bytes(field: 1, instruction.output)
            pendingKeys = []
        }

        for event in events {
            switch event {
            case .keys(let keys):
                pendingKeys += keys
            case .resize(let cols, let rows):
                flushKeys()
                var resize = ProtoWriter()
                resize.varint(field: 5, UInt64(cols))
                resize.varint(field: 6, UInt64(rows))
                var instruction = ProtoWriter()
                instruction.bytes(field: 3, resize.output)
                message.bytes(field: 1, instruction.output)
            }
        }
        flushKeys()
        return message.output
    }
}

/// One instruction from HostBuffers.HostMessage.
enum MoshHostInstruction {
    case hostBytes([UInt8])
    case resize(cols: Int, rows: Int)
    case echoAck(UInt64)

    static func decode(_ bytes: [UInt8]) throws -> [MoshHostInstruction] {
        var result = [MoshHostInstruction]()
        var message = ProtoReader(bytes)
        while let (field, value) = try message.next() {
            guard field == 1, case .bytes(let instructionBytes) = value else { continue }
            var instruction = ProtoReader(instructionBytes)
            while let (extField, extValue) = try instruction.next() {
                guard case .bytes(let body) = extValue else { continue }
                var inner = ProtoReader(body)
                switch extField {
                case 2:
                    while let (f, v) = try inner.next() {
                        if f == 4, case .bytes(let s) = v { result.append(.hostBytes(s)) }
                    }
                case 3:
                    var cols = 0
                    var rows = 0
                    while let (f, v) = try inner.next() {
                        if case .varint(let n) = v {
                            if f == 5 { cols = Int(Int32(truncatingIfNeeded: n)) }
                            if f == 6 { rows = Int(Int32(truncatingIfNeeded: n)) }
                        }
                    }
                    result.append(.resize(cols: cols, rows: rows))
                case 7:
                    while let (f, v) = try inner.next() {
                        if f == 8, case .varint(let n) = v { result.append(.echoAck(n)) }
                    }
                default:
                    break
                }
            }
        }
        return result
    }
}

// MARK: - Protobuf primitives

struct ProtoWriter {
    private(set) var output = [UInt8]()

    mutating func varint(field: Int, _ value: UInt64) {
        rawVarint(UInt64(field << 3))
        rawVarint(value)
    }

    mutating func bytes(field: Int, _ value: [UInt8]) {
        rawVarint(UInt64(field << 3 | 2))
        rawVarint(UInt64(value.count))
        output += value
    }

    private mutating func rawVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            output.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        output.append(UInt8(v))
    }
}

struct ProtoReader {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
    }

    struct Malformed: Error {}

    private let data: [UInt8]
    private var position = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    mutating func next() throws -> (Int, Value)? {
        guard position < data.count else { return nil }
        let key = try readVarint()
        let field = Int(key >> 3)
        switch key & 7 {
        case 0:
            return (field, .varint(try readVarint()))
        case 2:
            let length = Int(try readVarint())
            guard length >= 0, position + length <= data.count else { throw Malformed() }
            defer { position += length }
            return (field, .bytes(Array(data[position..<position + length])))
        case 1:
            guard position + 8 <= data.count else { throw Malformed() }
            position += 8
            return try next()
        case 5:
            guard position + 4 <= data.count else { throw Malformed() }
            position += 4
            return try next()
        default:
            throw Malformed()
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < data.count {
            let byte = data[position]
            position += 1
            if shift < 64 { result |= UInt64(byte & 0x7F) << shift }
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw Malformed()
    }
}

// MARK: - zlib framing

/// mosh compresses each serialized Instruction with zlib's compress()/uncompress(). Foundation's
/// `.zlib` algorithm is raw DEFLATE, so the 2-byte header and Adler-32 trailer are added/stripped here.
enum MoshZlib {
    struct Failed: Error {}

    static func compress(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let deflated = try? (Data(bytes) as NSData).compressed(using: .zlib) else { throw Failed() }
        return [0x78, 0x9C] + Array(deflated as Data) + adler32(bytes).bigEndianBytes4
    }

    static func uncompress(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count >= 6, bytes[0] & 0x0F == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0 else {
            throw Failed()
        }
        let body = Data(bytes[2..<(bytes.count - 4)])
        guard let inflated = try? (body as NSData).decompressed(using: .zlib) else { throw Failed() }
        let result = Array(inflated as Data)
        guard adler32(result) == UInt32(bigEndianBytes: bytes.suffix(4)) else { throw Failed() }
        return result
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }
}

extension UInt32 {
    var bigEndianBytes4: [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: self >> (24 - 8 * $0)) }
    }

    init<C: Collection>(bigEndianBytes bytes: C) where C.Element == UInt8 {
        self = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
