import Foundation
#if canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The P-256 agreement and HKDF a Linux host uses to dial a control plane (058, T044).
///
/// The same bytes CryptoKit derives on the Mac: a private key is 32 bytes, a public key
/// is the 65-byte X9.63 point, the shared secret is the x coordinate, and the HKDF is
/// SHA-256. Kept here, rather than in `swift-crypto`, so the Linux binary links BoringSSL
/// once — inside `swift-nio-ssl`, for the handshake — and not a second time for the keys.
///
/// Where CryptoKit is there it does the curve itself: the arithmetic here takes a fifth of a
/// second a multiplication unoptimised, which a debug build and a suite of eighty tests
/// dialling at once turned into seconds of every core. `ControlAgreementTests` holds the
/// two to the same bytes.
public enum ControlAgreement {
    public struct Failure: Error, Sendable {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    /// A new key. The private half is what `DeviceKey` writes into a file on a Mac.
    public static func generate() -> (privateKey: Data, publicKey: Data) {
        var generator = SystemRandomNumberGenerator()
        while true {
            let bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            if let key = valid(bytes), let publicKey = try? publicKey(privateKey: key) {
                return (key, publicKey)
            }
        }
    }

    /// The key in `file`, or a new one written `0600` the way `DeviceKey.load(file:)` does.
    public static func loadOrMake(file: URL) throws -> Data {
        if let stored = try? Data(contentsOf: file), let key = valid(stored) { return key }
        let made = generate().privateKey
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Created only if absent: two processes making the key at once (Agents Host and
        // the launcher it just started) must end up with one key, the first one written.
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            let written = made.withUnsafeBytes { write(fd, $0.baseAddress, made.count) }
            fsync(fd)
            close(fd)
            guard written == made.count else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path]) }
            return made
        }
        // Another got there first: theirs is the key, once it is all written.
        for _ in 0..<50 {
            if let stored = try? Data(contentsOf: file), let key = valid(stored) { return key }
            usleep(20_000)
        }
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
    }

    public static func publicKey(privateKey: Data) throws -> Data {
        #if canImport(CryptoKit)
        guard valid(privateKey) != nil,
              let key = try? CryptoKit.P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            throw Failure("That is not a P-256 private key.")
        }
        return key.publicKey.x963Representation
        #else
        return try portablePublicKey(privateKey: privateKey)
        #endif
    }

    /// `publicKey` in this file's own arithmetic: what Linux uses, and what the tests hold
    /// to CryptoKit's.
    static func portablePublicKey(privateKey: Data) throws -> Data {
        guard let scalar = valid(privateKey) else { throw Failure("That is not a P-256 private key.") }
        let point = P256.scalarMultiply(P256.generator, by: scalar)
        let affine = try P256.affine(point)
        return Data([0x04]) + affine.x.bytes + affine.y.bytes
    }

    /// The x coordinate both ends feed to HKDF.
    public static func sharedSecret(privateKey: Data, peerPublic: Data) throws -> Data {
        #if canImport(CryptoKit)
        guard valid(privateKey) != nil,
              let key = try? CryptoKit.P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            throw Failure("That is not a P-256 private key.")
        }
        guard let peer = try? CryptoKit.P256.KeyAgreement.PublicKey(x963Representation: peerPublic),
              let shared = try? key.sharedSecretFromKeyAgreement(with: peer) else {
            throw Failure("That is not a P-256 public key.")
        }
        return shared.withUnsafeBytes { Data($0) }
        #else
        return try portableSharedSecret(privateKey: privateKey, peerPublic: peerPublic)
        #endif
    }

    /// `sharedSecret` in this file's own arithmetic.
    static func portableSharedSecret(privateKey: Data, peerPublic: Data) throws -> Data {
        guard let scalar = valid(privateKey) else { throw Failure("That is not a P-256 private key.") }
        let peer = try P256.point(x963: peerPublic)
        let shared = P256.scalarMultiply(peer, by: scalar)
        return try P256.affine(shared).x.bytes
    }

    public static func sha256(_ data: Data) -> Data { SHA256.sum(data) }

    /// HMAC-SHA256 (RFC 2104), as CryptoKit's `HMAC<SHA256>` computes it.
    public static func hmacSHA256(key: Data, message: Data) -> Data { HMAC.sha256(key: key, message: message) }

    /// HKDF-SHA256 (RFC 5869), the same derivation CryptoKit's `HKDF` and
    /// `hkdfDerivedSymmetricKey` perform.
    public static func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let salt = salt.isEmpty ? Data(repeating: 0, count: 32) : salt
        let prk = HMAC.sha256(key: salt, message: ikm)
        var okm = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while okm.count < length {
            previous = HMAC.sha256(key: prk, message: previous + info + Data([counter]))
            okm.append(previous)
            counter &+= 1
        }
        return Data(okm.prefix(length))
    }

    public static func codeIdentity(secret: Data, host: Bool) -> String {
        let prefix = host ? "e:" : "p:"
        return prefix + sha256(secret).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func codeKey(_ secret: Data) -> Data {
        hkdfSHA256(ikm: secret, salt: Data("agents-control-code-v1".utf8), info: Data(), length: 32)
    }

    public static func hostIdentity(_ id: HostID) -> String { "h:" + id.rawValue }
    public static func clientIdentity(_ id: UUID) -> String { "c:" + id.uuidString }

    public static func hostKey(privateKey: Data, peer: Data, host: HostID) throws -> Data {
        let shared = try sharedSecret(privateKey: privateKey, peerPublic: peer)
        return hkdfSHA256(ikm: shared, salt: Data("agents-control-host-v1".utf8),
                          info: Data(host.rawValue.utf8), length: 32)
    }

    /// A scalar CryptoKit would accept: 32 bytes, not zero, and below the group order.
    private static func valid(_ data: Data) -> Data? {
        guard data.count == 32, data.contains(where: { $0 != 0 }),
              data.lexicographicallyPrecedes(P256.order) else { return nil }
        return data
    }
}

// MARK: - SHA-256

private enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func sum(_ message: Data) -> Data {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var bytes = [UInt8](message)
        let bitCount = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        for chunk in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let o = chunk + i * 4
                w[i] = UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16
                    | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
            }
            for i in 16..<64 {
                let s0 = rot(w[i - 15], 7) ^ rot(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rot(w[i - 2], 17) ^ rot(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rot(e, 6) ^ rot(e, 11) ^ rot(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rot(a, 2) ^ rot(a, 13) ^ rot(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        var out = Data(capacity: 32)
        for word in h {
            out.append(UInt8(truncatingIfNeeded: word >> 24))
            out.append(UInt8(truncatingIfNeeded: word >> 16))
            out.append(UInt8(truncatingIfNeeded: word >> 8))
            out.append(UInt8(truncatingIfNeeded: word))
        }
        return out
    }

    private static func rot(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

private enum HMAC {
    static func sha256(key: Data, message: Data) -> Data {
        var k = [UInt8](key)
        if k.count > 64 { k = [UInt8](SHA256.sum(Data(k))) }
        if k.count < 64 { k.append(contentsOf: repeatElement(0, count: 64 - k.count)) }
        let inner = SHA256.sum(Data(k.map { $0 ^ 0x36 }) + message)
        return SHA256.sum(Data(k.map { $0 ^ 0x5c }) + inner)
    }
}

// MARK: - P-256

/// Jacobian arithmetic over the P-256 prime field. One inverse per scalar multiplication.
private enum P256 {
    /// The group order, big-endian, so a scalar compares against it as bytes.
    static let order = Data(hex: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")

    struct Field: Equatable {
        var w: [UInt64]

        static let zero = Field([0, 0, 0, 0])
        static let one = Field([1, 0, 0, 0])
        /// p = 2^256 − 2^224 + 2^192 + 2^96 − 1.
        static let p = Field([0xffffffffffffffff, 0x00000000ffffffff, 0, 0xffffffff00000001])
        /// 2^256 mod p.
        static let r = Field([0x1, 0xffffffff00000000, 0xffffffffffffffff, 0xfffffffe])
        static let b = Field(hex: "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b")

        init(_ w: [UInt64]) { self.w = w }

        init(hex: String) {
            var bytes = [UInt8]()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16)!)
                index = next
            }
            self = Field(bytes: Data(bytes))
        }

        /// 32 bytes, big-endian, as CryptoKit lays a coordinate out. Copied first:
        /// a `Data` slice keeps the original indices, and `bytes[0..<8]` would trap.
        init(bytes: Data) {
            let bytes = [UInt8](bytes)
            var w = [UInt64](repeating: 0, count: 4)
            for i in 0..<4 {
                var limb: UInt64 = 0
                for b in bytes[(i * 8)..<((i + 1) * 8)] { limb = (limb << 8) | UInt64(b) }
                w[3 - i] = limb
            }
            self.w = w
        }

        var bytes: Data {
            var out = Data(capacity: 32)
            for i in (0..<4).reversed() {
                let limb = w[i]
                for shift in stride(from: 56, through: 0, by: -8) {
                    out.append(UInt8(truncatingIfNeeded: limb >> shift))
                }
            }
            return out
        }

        var isZero: Bool { w.allSatisfy { $0 == 0 } }

        func lessThan(_ other: Field) -> Bool {
            for i in (0..<4).reversed() {
                if w[i] < other.w[i] { return true }
                if w[i] > other.w[i] { return false }
            }
            return false
        }

        func adding(_ other: Field) -> Field {
            var (sum, carry) = Field.add(self, other)
            if carry == 1 {
                let folded = Field.add(sum, .r)
                sum = folded.0
                if folded.1 == 1 { sum = Field.add(sum, .r).0 }
            }
            if !sum.lessThan(.p) { sum = Field.subtract(sum, .p) }
            return sum
        }

        func subtracting(_ other: Field) -> Field {
            if !lessThan(other) { return Field.subtract(self, other) }
            return Field.subtract(.p, Field.subtract(other, self))
        }

        func multiplying(_ other: Field) -> Field {
            var acc = [UInt64](repeating: 0, count: 8)
            for i in 0..<4 {
                var carryLo: UInt64 = 0
                var carryHi: UInt64 = 0
                for j in 0..<4 {
                    let part = Field.mul64(w[i], other.w[j])
                    let (s1, c1) = acc[i + j].addingReportingOverflow(part.lo)
                    let (s2, c2) = s1.addingReportingOverflow(carryLo)
                    acc[i + j] = s2
                    let extra = UInt64((c1 ? 1 : 0) + (c2 ? 1 : 0))
                    let (lo, o1) = part.hi.addingReportingOverflow(carryHi)
                    let (lo2, o2) = lo.addingReportingOverflow(extra)
                    carryLo = lo2
                    carryHi = (o1 ? 1 : 0) + (o2 ? 1 : 0)
                }
                var rest = carryLo
                var restHi = carryHi
                var at = i + 4
                while (rest != 0 || restHi != 0), at < acc.count {
                    let (s, o) = acc[at].addingReportingOverflow(rest)
                    acc[at] = s
                    rest = restHi + (o ? 1 : 0)
                    restHi = 0
                    at += 1
                }
            }
            return Field.reduce(acc)
        }

        func squaring() -> Field { multiplying(self) }

        /// a^(p − 2) mod p.
        func inverting() -> Field {
            let exponent = Field.subtract(.p, Field([2, 0, 0, 0]))
            var result = Field.one
            var base = self
            for i in 0..<256 {
                if exponent.bit(i) { result = result.multiplying(base) }
                if i < 255 { base = base.squaring() }
            }
            return result
        }

        private func bit(_ i: Int) -> Bool { (w[i / 64] >> (i % 64)) & 1 == 1 }

        private static func add(_ a: Field, _ b: Field) -> (Field, UInt64) {
            var w = [UInt64](repeating: 0, count: 4)
            var carry: UInt64 = 0
            for i in 0..<4 {
                let (s1, o1) = a.w[i].addingReportingOverflow(b.w[i])
                let (s2, o2) = s1.addingReportingOverflow(carry)
                w[i] = s2
                carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }
            return (Field(w), carry)
        }

        private static func subtract(_ a: Field, _ b: Field) -> Field {
            var w = [UInt64](repeating: 0, count: 4)
            var borrow: UInt64 = 0
            for i in 0..<4 {
                let (d1, o1) = a.w[i].subtractingReportingOverflow(b.w[i])
                let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                w[i] = d2
                borrow = (o1 || o2) ? 1 : 0
            }
            return Field(w)
        }

        /// A 64×64 multiply. Each column is summed before it is shifted, so the
        /// additions stay inside a `UInt64` — a wrapped `+` here is a wrong point.
        private static func mul64(_ a: UInt64, _ b: UInt64) -> (hi: UInt64, lo: UInt64) {
            let a0 = a & 0xffffffff, a1 = a >> 32
            let b0 = b & 0xffffffff, b1 = b >> 32
            let p00 = a0 * b0
            let p01 = a0 * b1
            let p10 = a1 * b0
            let p11 = a1 * b1
            let col1 = (p00 >> 32) + (p01 & 0xffffffff) + (p10 & 0xffffffff)
            let col2 = (p01 >> 32) + (p10 >> 32) + (p11 & 0xffffffff) + (col1 >> 32)
            let col3 = (p11 >> 32) + (col2 >> 32)
            let lo = (p00 & 0xffffffff) | ((col1 & 0xffffffff) << 32)
            let hi = (col2 & 0xffffffff) | (col3 << 32)
            return (hi, lo)
        }

        /// Fold a 512-bit product by 2^256 ≡ r (mod p) until it fits under p.
        private static func reduce(_ words: [UInt64]) -> Field {
            var words = words
            for _ in 0..<12 {
                while words.last == 0, words.count > 4 { words.removeLast() }
                if words.count <= 4 {
                    var low = Field(words + Array(repeating: 0, count: 4 - words.count))
                    if !low.lessThan(.p) { low = subtract(low, .p) }
                    return low
                }
                let low = Array(words.prefix(4))
                let high = Array(words.dropFirst(4))
                words = addWords(low, timesR(high))
            }
            return .zero
        }

        /// `high * (2^224 − 2^192 − 2^96 + 1)`, which is 2^256 · high modulo p before folding.
        private static func timesR(_ high: [UInt64]) -> [UInt64] {
            let up = addWords(shift(high, 224), high)
            return subWords(subWords(up, shift(high, 192)), shift(high, 96))
        }

        private static func shift(_ words: [UInt64], _ bits: Int) -> [UInt64] {
            let wordShift = bits / 64
            let bitShift = bits % 64
            var out = [UInt64](repeating: 0, count: words.count + wordShift + 1)
            for i in words.indices {
                let at = i + wordShift
                if bitShift == 0 {
                    out[at] = words[i]
                } else {
                    out[at] |= words[i] << bitShift
                    out[at + 1] |= words[i] >> (64 - bitShift)
                }
            }
            return out
        }

        private static func addWords(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
            var out = [UInt64](repeating: 0, count: max(a.count, b.count) + 1)
            var carry: UInt64 = 0
            for i in 0..<out.count - 1 {
                let av = i < a.count ? a[i] : 0
                let bv = i < b.count ? b[i] : 0
                let (s1, o1) = av.addingReportingOverflow(bv)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                out[i] = s2
                carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
            }
            out[out.count - 1] = carry
            return out
        }

        private static func subWords(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
            var out = a
            if out.count < b.count { out.append(contentsOf: repeatElement(0, count: b.count - out.count)) }
            var borrow: UInt64 = 0
            for i in 0..<out.count {
                let bv = i < b.count ? b[i] : 0
                let (d1, o1) = out[i].subtractingReportingOverflow(bv)
                let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                out[i] = d2
                borrow = (o1 || o2) ? 1 : 0
            }
            return out
        }
    }

    struct Point {
        var x, y, z: Field
        var infinity: Bool
        static let infinity = Point(x: .zero, y: .one, z: .zero, infinity: true)
    }

    static let generator = Point(
        x: Field(hex: "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"),
        y: Field(hex: "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"),
        z: .one, infinity: false)

    static func point(x963: Data) throws -> Point {
        guard x963.count == 65, x963.first == 0x04 else { throw ControlAgreement.Failure("That is not a P-256 public key.") }
        let raw = [UInt8](x963)
        let x = Field(bytes: Data(raw[1..<33]))
        let y = Field(bytes: Data(raw[33..<65]))
        let left = y.squaring()
        let right = x.squaring().multiplying(x).subtracting(x.adding(x).adding(x)).adding(.b)
        guard left == right else { throw ControlAgreement.Failure("That public key is not on the curve.") }
        return Point(x: x, y: y, z: .one, infinity: false)
    }

    static func scalarMultiply(_ point: Point, by scalar: Data) -> Point {
        var result = Point.infinity
        let bytes = [UInt8](scalar)
        for i in stride(from: 255, through: 0, by: -1) {
            result = double(result)
            let bit = (bytes[31 - i / 8] >> (i % 8)) & 1
            if bit == 1 { result = add(result, point) }
        }
        return result
    }

    static func affine(_ point: Point) throws -> (x: Field, y: Field) {
        guard !point.infinity, !point.z.isZero else { throw ControlAgreement.Failure("No shared point.") }
        let inverse = point.z.inverting()
        let inverse2 = inverse.squaring()
        return (point.x.multiplying(inverse2), point.y.multiplying(inverse2.multiplying(inverse)))
    }

    /// Doubling with a = −3: 3(X² − Z⁴) = 3(X − Z²)(X + Z²).
    private static func double(_ p: Point) -> Point {
        if p.infinity || p.y.isZero || p.z.isZero { return .infinity }
        let a = p.x.squaring()
        let b = p.y.squaring()
        let c = b.squaring()
        let d = p.x.adding(b).squaring().subtracting(a).subtracting(c).adding(
            p.x.adding(b).squaring().subtracting(a).subtracting(c))
        let z2 = p.z.squaring()
        let e = p.x.subtracting(z2).multiplying(p.x.adding(z2))
        let e3 = e.adding(e).adding(e)
        let f = e3.squaring()
        let x3 = f.subtracting(d.adding(d))
        let eightC = c.adding(c).adding(c).adding(c).adding(c).adding(c).adding(c).adding(c)
        let y3 = e3.multiplying(d.subtracting(x3)).subtracting(eightC)
        let z3 = p.y.adding(p.y).multiplying(p.z)
        return Point(x: x3, y: y3, z: z3, infinity: false)
    }

    private static func add(_ p: Point, _ q: Point) -> Point {
        if p.infinity || p.z.isZero { return q }
        if q.infinity || q.z.isZero { return p }
        let z1z1 = p.z.squaring()
        let z2z2 = q.z.squaring()
        let u1 = p.x.multiplying(z2z2)
        let u2 = q.x.multiplying(z1z1)
        let s1 = p.y.multiplying(q.z).multiplying(z2z2)
        let s2 = q.y.multiplying(p.z).multiplying(z1z1)
        let h = u2.subtracting(u1)
        let r = s2.subtracting(s1)
        if h.isZero { return r.isZero ? double(p) : .infinity }
        let hh = h.squaring()
        let i = hh.adding(hh).adding(hh).adding(hh)
        let j = h.multiplying(i)
        let rr = r.adding(r)
        let v = u1.multiplying(i)
        let x3 = rr.squaring().subtracting(j).subtracting(v.adding(v))
        let y3 = rr.multiplying(v.subtracting(x3)).subtracting(s1.adding(s1).multiplying(j))
        let z3 = p.z.adding(q.z).squaring().subtracting(z1z1).subtracting(z2z2).multiplying(h)
        return Point(x: x3, y: y3, z: z3, infinity: false)
    }
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self = Data(bytes)
    }
}
