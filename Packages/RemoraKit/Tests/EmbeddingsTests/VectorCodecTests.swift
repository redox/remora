import Foundation
import Testing
import Storage

@Test func codecRoundTrip() {
    let v: [Float] = [0.5, -1, 3.25]
    #expect(VectorCodec.decode(VectorCodec.encode(v), dims: 3) == v)
    #expect(VectorCodec.encode(v).count == 12)
}

@Test func codecIsLittleEndianFloat32() {
    #expect([UInt8](VectorCodec.encode([1.0])) == [0x00, 0x00, 0x80, 0x3F])
}

@Test func codecRejectsWrongLength() {
    #expect(VectorCodec.decode(Data(count: 10), dims: 3) == nil)
}
