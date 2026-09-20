/// Optimized byte-stream primitives evolving toward the low-level `IO` architecture.
///
/// `IO` optimized byte-stream primitives intentionally separate two concerns:
///
/// - `Source` / `Destination` describe how bytes move.
/// - A future `IO` execution capability will describe how potentially blocking work is
///   scheduled, cancelled, waited on, or otherwise driven.
///
/// The central performance rule is that common stream mechanics stay *north* of the
/// runtime-selected backend boundary. `Source` and `Destination` therefore own their
/// ordinary buffers and cursor state. Small reads/writes can operate on that state
/// without dynamically dispatching into an endpoint. A backend is consulted only when
/// meaningful endpoint work is required through `refill` or `drain`.
///
/// The current backend representation uses Swift protocol existentials. That choice is
/// deliberately experimental rather than architectural law. We still need to compare it
/// with generic backends, explicit vtables/closure tables, and possible hybrid designs
/// using release builds, SIL/assembly, allocation counts, ARC traffic, and cross-module
/// call sites.
///
/// The byte-stream layer is deliberately synchronous. `unavailable` represents an
/// endpoint that remains valid but cannot make progress *now*. A future execution layer
/// can decide whether that means polling, suspension, blocking a worker, registration
/// with an event loop, or some other scheduling strategy.
///
/// Foundation is intentionally absent from this core. Text decoding, `Data`, files,
/// sockets, compression, TLS, and similar facilities should build on these byte-flow
/// semantics rather than become the semantics themselves.
