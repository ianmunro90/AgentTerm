import CommonCrypto
import Foundation

/// AES-128-OCB3 (RFC 7253) with a 96-bit nonce, 128-bit tag and no associated data —
/// the only mode mosh uses. CommonCrypto provides the raw AES block cipher.
final class AESOCB {
    enum OCBError: Error {
        case badKey
        case authenticationFailed
    }

    private let encryptor: CCCryptorRef
    private let decryptor: CCCryptorRef
    private let lStar: Block
    private let lDollar: Block
    private var l: [Block]

    typealias Block = [UInt8]

    init(key: [UInt8]) throws {
        guard key.count == kCCKeySizeAES128 else { throw OCBError.badKey }
        var enc: CCCryptorRef?
        var dec: CCCryptorRef?
        guard CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                              key, key.count, nil, &enc) == kCCSuccess,
              CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                              key, key.count, nil, &dec) == kCCSuccess,
              let enc, let dec
        else { throw OCBError.badKey }
        encryptor = enc
        decryptor = dec

        var zero = Block(repeating: 0, count: 16)
        Self.cipher(enc, &zero)
        lStar = zero
        lDollar = Self.double(lStar)
        l = [Self.double(lDollar)]
    }

    deinit {
        CCCryptorRelease(encryptor)
        CCCryptorRelease(decryptor)
    }

    /// Returns ciphertext followed by the 16-byte tag.
    func seal(_ plaintext: [UInt8], nonce: [UInt8]) -> [UInt8] {
        var offset = initialOffset(nonce)
        var checksum = Block(repeating: 0, count: 16)
        var output = [UInt8]()
        output.reserveCapacity(plaintext.count + 16)

        let fullBlocks = plaintext.count / 16
        for i in 0..<fullBlocks {
            xorInPlace(&offset, lFor(i + 1))
            let p = Array(plaintext[i * 16..<(i + 1) * 16])
            xorInPlace(&checksum, p)
            var block = xor(p, offset)
            Self.cipher(encryptor, &block)
            output += xor(block, offset)
        }

        let rest = plaintext[(fullBlocks * 16)...]
        if !rest.isEmpty {
            xorInPlace(&offset, lStar)
            var pad = offset
            Self.cipher(encryptor, &pad)
            for (index, byte) in rest.enumerated() {
                output.append(byte ^ pad[index])
            }
            var padded = Array(rest) + [0x80]
            padded += Block(repeating: 0, count: 16 - padded.count)
            xorInPlace(&checksum, padded)
        }

        var tag = xor(xor(checksum, offset), lDollar)
        Self.cipher(encryptor, &tag)
        return output + tag
    }

    /// Verifies the trailing tag and returns the plaintext.
    func open(_ sealed: [UInt8], nonce: [UInt8]) throws -> [UInt8] {
        guard sealed.count >= 16 else { throw OCBError.authenticationFailed }
        let ciphertext = sealed[..<(sealed.count - 16)]
        let receivedTag = sealed[(sealed.count - 16)...]

        var offset = initialOffset(nonce)
        var checksum = Block(repeating: 0, count: 16)
        var output = [UInt8]()
        output.reserveCapacity(ciphertext.count)

        let fullBlocks = ciphertext.count / 16
        for i in 0..<fullBlocks {
            xorInPlace(&offset, lFor(i + 1))
            let start = ciphertext.startIndex + i * 16
            var block = xor(Array(ciphertext[start..<start + 16]), offset)
            Self.cipher(decryptor, &block)
            let p = xor(block, offset)
            xorInPlace(&checksum, p)
            output += p
        }

        let rest = ciphertext[(ciphertext.startIndex + fullBlocks * 16)...]
        if !rest.isEmpty {
            xorInPlace(&offset, lStar)
            var pad = offset
            Self.cipher(encryptor, &pad)
            var p = [UInt8]()
            for (index, byte) in rest.enumerated() {
                p.append(byte ^ pad[index])
            }
            output += p
            var padded = p + [0x80]
            padded += Block(repeating: 0, count: 16 - padded.count)
            xorInPlace(&checksum, padded)
        }

        var tag = xor(xor(checksum, offset), lDollar)
        Self.cipher(encryptor, &tag)
        // Constant-time comparison.
        var difference: UInt8 = 0
        for (a, b) in zip(tag, receivedTag) { difference |= a ^ b }
        guard difference == 0 else { throw OCBError.authenticationFailed }
        return output
    }

    // MARK: OCB internals

    private func initialOffset(_ nonce: [UInt8]) -> Block {
        precondition(nonce.count == 12)
        // Nonce block = num2str(TAGLEN mod 128, 7) || zeros || 1 || N; with a 128-bit tag that is 00 00 00 01 || N.
        var nonceBlock: Block = [0, 0, 0, 1] + nonce
        let bottom = Int(nonceBlock[15] & 0x3F)
        nonceBlock[15] &= 0xC0
        var ktop = nonceBlock
        Self.cipher(encryptor, &ktop)
        var stretch = ktop
        for i in 0..<8 { stretch.append(ktop[i] ^ ktop[i + 1]) }

        // Offset_0 = Stretch[1 + bottom .. 128 + bottom] (bit offsets).
        let byteShift = bottom / 8
        let bitShift = bottom % 8
        var offset = Block(repeating: 0, count: 16)
        for i in 0..<16 {
            let high = stretch[i + byteShift]
            let low = stretch[i + byteShift + 1]
            offset[i] = bitShift == 0 ? high : (high << bitShift) | (low >> (8 - bitShift))
        }
        return offset
    }

    private func lFor(_ blockIndex: Int) -> Block {
        let ntz = blockIndex.trailingZeroBitCount
        while l.count <= ntz { l.append(Self.double(l[l.count - 1])) }
        return l[ntz]
    }

    private static func double(_ block: Block) -> Block {
        var result = Block(repeating: 0, count: 16)
        for i in 0..<15 {
            result[i] = (block[i] << 1) | (block[i + 1] >> 7)
        }
        result[15] = (block[15] << 1) ^ ((block[0] & 0x80) != 0 ? 0x87 : 0)
        return result
    }

    private static func cipher(_ cryptor: CCCryptorRef, _ block: inout Block) {
        var out = Block(repeating: 0, count: 16)
        var moved = 0
        CCCryptorUpdate(cryptor, block, 16, &out, 16, &moved)
        block = out
    }

    private func xor(_ a: Block, _ b: Block) -> Block {
        var out = a
        for i in 0..<16 { out[i] ^= b[i] }
        return out
    }

    private func xorInPlace(_ a: inout Block, _ b: Block) {
        for i in 0..<16 { a[i] ^= b[i] }
    }
}

/// Mosh's packet layer: an 8-byte nonce suffix (direction bit + sequence number) followed by
/// the OCB ciphertext of `timestamp(2) || timestamp_reply(2) || payload`.
struct MoshCrypto {
    static let directionToClient: UInt64 = 1 << 63

    private let ocb: AESOCB

    /// `key` is the 22-character base64 key printed by `mosh-server` ("MOSH CONNECT <port> <key>").
    init(printableKey: String) throws {
        guard printableKey.count == 22, let data = Data(base64Encoded: printableKey + "=="), data.count == 16 else {
            throw AESOCB.OCBError.badKey
        }
        ocb = try AESOCB(key: Array(data))
    }

    func encrypt(sequence: UInt64, plaintext: [UInt8]) -> [UInt8] {
        let nonceTail = sequence.bigEndianBytes
        return nonceTail + ocb.seal(plaintext, nonce: [0, 0, 0, 0] + nonceTail)
    }

    /// Returns the nonce value (direction bit + sequence) and plaintext.
    func decrypt(_ datagram: [UInt8]) throws -> (nonce: UInt64, plaintext: [UInt8]) {
        guard datagram.count >= 24 else { throw AESOCB.OCBError.authenticationFailed }
        let nonceTail = Array(datagram[0..<8])
        let plaintext = try ocb.open(Array(datagram[8...]), nonce: [0, 0, 0, 0] + nonceTail)
        return (UInt64(bigEndianBytes: nonceTail), plaintext)
    }
}

extension UInt64 {
    var bigEndianBytes: [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: self >> (56 - 8 * $0)) }
    }

    init<C: Collection>(bigEndianBytes bytes: C) where C.Element == UInt8 {
        self = bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
