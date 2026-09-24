/// Optional readiness metadata exposed by endpoint backends.
///
/// The synchronous endpoint operation remains the source of truth. This capability only
/// identifies a descriptor an explicit `IO` runtime may wait on after `.unavailable`.
/// Backends that are not descriptor-waitable inherit the default `nil` implementation.
public protocol IOReadinessProviding:
    ~Copyable
{
    var readinessDescriptor:
        Int32?
    {
        get
    }
}

public extension IOReadinessProviding
where Self: ~Copyable
{
    var readinessDescriptor:
        Int32?
    {
        nil
    }
}
