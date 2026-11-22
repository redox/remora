/// A tree-agnostic view of an accessibility element.
///
/// Implementations may be backed by live, slow IPC (Task 8), so consumers must
/// read each property at most once per node and `children` only when they
/// intend to descend.
public protocol AXNode: Sendable {
    var role: String? { get }
    var subrole: String? { get }
    var value: String? { get }
    var title: String? { get }
    var nodeDescription: String? { get }
    var children: [any AXNode] { get }
}
