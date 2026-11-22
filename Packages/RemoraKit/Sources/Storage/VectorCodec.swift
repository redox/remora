import Foundation

/// float32 little-endian BLOB encoding of an embedding vector. Lives in Storage (not Embeddings)
/// because `EmbeddingStore` reads and writes the BLOB.
public enum VectorCodec {
    public static func encode(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 4)
        for x in v {
            var bits = x.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// nil unless `d` holds exactly `dims` float32 values.
    public static func decode(_ d: Data, dims: Int) -> [Float]? {
        guard dims >= 0, d.count == dims * 4 else { return nil }
        let bytes = [UInt8](d)
        return (0..<dims).map { i in
            let o = i * 4
            let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
            return Float(bitPattern: bits)
        }
    }
}
