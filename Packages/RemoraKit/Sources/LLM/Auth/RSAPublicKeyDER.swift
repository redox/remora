import Foundation

/// Minimal DER codec for a PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`,
/// the format `SecKeyCreateWithData` / `SecKeyCopyExternalRepresentation` use for RSA public keys.
/// Inputs and outputs are unsigned big-endian magnitudes.
enum RSAPublicKeyDER {
    static func encode(modulus: Data, exponent: Data) -> Data {
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }

    static func decode(_ der: Data) -> (modulus: Data, exponent: Data)? {
        let bytes = [UInt8](der)
        var i = 0
        guard let seq = readTLV(bytes, &i, tag: 0x30), i == bytes.count else { return nil }
        var j = seq.lowerBound
        guard let n = readTLV(bytes, &j, tag: 0x02), let e = readTLV(bytes, &j, tag: 0x02), j == seq.upperBound else { return nil }
        guard let modulus = magnitude(bytes[n]), let exponent = magnitude(bytes[e]) else { return nil }
        return (Data(modulus), Data(exponent))
    }

    private static func integer(_ value: Data) -> Data {
        var v = [UInt8](value.drop(while: { $0 == 0 }))
        if v.isEmpty { v = [0] }
        if v[0] & 0x80 != 0 { v.insert(0, at: 0) }
        return Data([0x02]) + length(v.count) + Data(v)
    }

    private static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var m = n
        while m > 0 { bytes.insert(UInt8(m & 0xFF), at: 0); m >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    /// Reads one tag-length-value at `i`; returns the value's range and advances `i` past it.
    private static func readTLV(_ b: [UInt8], _ i: inout Int, tag: UInt8) -> Range<Int>? {
        guard i < b.count, b[i] == tag else { return nil }
        i += 1
        guard i < b.count else { return nil }
        var len = Int(b[i])
        i += 1
        if len & 0x80 != 0 {
            let count = len & 0x7F
            guard (1...4).contains(count), i + count <= b.count else { return nil }
            len = b[i..<(i + count)].reduce(0) { $0 << 8 | Int($1) }
            i += count
        }
        guard len >= 0, i + len <= b.count else { return nil }
        defer { i += len }
        return i..<(i + len)
    }

    /// A positive INTEGER's magnitude with the sign-padding zero removed.
    private static func magnitude(_ v: ArraySlice<UInt8>) -> [UInt8]? {
        guard let first = v.first, first & 0x80 == 0 else { return nil }
        let m = [UInt8](v.drop(while: { $0 == 0 }))
        return m.isEmpty ? nil : m
    }
}
