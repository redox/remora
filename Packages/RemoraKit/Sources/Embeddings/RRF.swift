/// Reciprocal rank fusion of ranked lists.
public enum RRF {
    public static let k = 60.0

    /// Σ 1/(k + rank) over the lists (rank 1-based), sorted descending, ties by first appearance.
    public static func fuse<Key: Hashable>(_ lists: [[Key]]) -> [(Key, Double)] {
        var scores: [Key: Double] = [:]
        var order: [Key] = []
        for list in lists {
            var seen = Set<Key>()
            for (i, key) in list.enumerated() where seen.insert(key).inserted {
                if scores[key] == nil { order.append(key) }
                scores[key, default: 0] += 1 / (k + Double(i + 1))
            }
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return order.map { ($0, scores[$0]!) }.sorted {
            $0.1 != $1.1 ? $0.1 > $1.1 : position[$0.0]! < position[$1.0]!
        }
    }
}
