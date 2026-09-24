# Explicit IO Architecture

## I0a — Capability seam inventory

This document records the seam selection for evolving the package toward an
explicitly passed `IO` value.

The goal is not to make every low-level type contain `IO`. The goal is to make
operations that depend on an execution/system-I/O implementation explicit,
while keeping memory ownership, native-resource ownership, byte-flow state,
allocation, and timing primitives separate.

## Existing separation that remains architectural

### Byte-flow state stays outside `IO`

`Source` and `Destination` own byte-flow policy and staging state.

They are responsible for:

- ring cursor state;
- buffered-byte accounting;
- refill/drain state machines;
- EOF and backpressure semantics;
- short-progress semantics;
- caller-owned versus internally owned staging storage.

The owned and borrowed variants now share `SourceAlgorithm` /
`DestinationAlgorithm`.

`IO` must not absorb these state machines.

### Staging memory stays outside `IO`

Caller-supplied storage remains explicit:

- `BorrowedStreamRingBuffer`;
- `BorrowedSource`;
- `BorrowedDestination`.

Owned ring storage remains an endpoint concern.

`IO` is not an allocator and is not a buffer owner.

### Allocators stay separate

Dynamic allocation policy belongs to the Allocators package and should be
passed separately when an operation actually needs dynamic storage.

The intended eventual application shape remains conceptually:

```swift
func main(
    io: borrowing IO,
    allocator: borrowing some Allocator
) throws {
    ...
}
```

Neither capability substitutes for the other.

### Native resources stay distinct from `IO`

A file descriptor/socket/file handle is an owned resource, not the IO
implementation itself.

Resource values should continue to express unique ownership through
noncopyable types where appropriate.

`IO` drives operations on resources; it does not become the resource.

## Current syscall / execution seams

| Current type / seam | Current responsibility | I0 classification |
| --- | --- | --- |
| `Source` / `BorrowedSource` | byte-flow state over owned/borrowed staging storage | **stay outside IO** |
| `Destination` / `BorrowedDestination` | byte-flow state over owned/borrowed staging storage | **stay outside IO** |
| `MemorySource` / `MemoryDestination` | deterministic memory endpoints | **stay IO-independent** |
| `SystemFileSource` | owns descriptor; open/cache/read/readv-like refill/close boundary | **resource + IO-driven system operations** |
| `SystemFileDestination` | owns descriptor; open/write/writev/close boundary | **resource + IO-driven system operations** |
| `NonblockingSocketBackend` | descriptor ownership, nonblocking configuration, socket receive/send, close | **resource + IO-driven system operations** |
| `ReadinessBackend` | register/remove/poll readiness | **belongs to IO execution capability** |
| `FileSystem` | public filesystem implementation selection and higher-level filesystem semantics | **defer composition; do not fold wholesale into first IO slice** |
| native filesystem helpers | direct C/POSIX namespace/path operations | **later IO/filesystem convergence candidate** |
| Atomos monotonic clock/sleep | cross-platform primitive clock/sleep implementation | **remain in Atomos; IO may compose/use it, not duplicate it** |

## Important boundary: resource versus operation

Current system backends combine two things:

1. ownership of the native resource;
2. the ambient Darwin/Glibc calls used to operate on that resource.

The explicit-IO direction should separate those concepts without forcing an
extra abstraction into the Source/Destination hot loop.

Conceptually:

```text
File / Socket resource
    owns native handle

IO
    defines how system operations are executed

Source / Destination
    own byte-flow + staging state
```

A resource may therefore be constructed through `IO`, or a backend may retain
the resource plus the minimum IO execution handle/capability required to
operate it. Which representation is selected must be benchmarked rather than
assumed.

## `unavailable` and readiness

The byte-stream layer remains synchronous.

`SourceBackend` and `DestinationBackend` continue to report `.unavailable`
when an endpoint cannot progress now.

They must not acquire scheduling/event-loop policy.

`IO` is the appropriate layer to decide what to do next:

```text
endpoint returns unavailable
        ↓
IO / readiness waits or polls
        ↓
retry endpoint operation
```

This preserves the existing separation already expressed by
`ReadinessBackend`.

## Filesystem placement

`FileSystem` already carries its own implementation choice (`foundation` /
`c`) and has a large characterized semantic surface.

Do not immediately make all of `FileSystem` a field or protocol requirement of
the first real `IO`.

Instead:

1. establish the IO representation with a narrow file/resource vertical slice;
2. prove its call/ownership/performance behavior;
3. converge filesystem operations only where explicit execution context or
   retained native resources materially benefit them.

One-shot public URL operations should not gain extra dispatch merely for
architectural symmetry.

## Timing

Atomos remains the owner of monotonic clock and sleep primitives.

If IO later exposes deadlines, timed waits, or timer registration, those
facilities should compose the Atomos primitive rather than reimplement platform
clock logic inside IO.

## I0b implementation target

The next pass should make `IO` non-placeholder through the smallest useful
vertical slice.

### Required properties

The first real `IO` representation must:

- remain an explicitly passed value;
- provide a system/default implementation;
- support substitutable/test implementations;
- avoid allocator ownership;
- avoid staging-buffer ownership;
- avoid native-resource ownership;
- preserve Source/Destination backend runtime polymorphism for now;
- avoid adding dynamic dispatch to byte operations that currently remain
  entirely inside ring state;
- place dispatch only at meaningful system-operation boundaries;
- remain compatible with `~Copyable` resource types.

### First vertical slice

Use file opening + file read/write resource operations as the first slice.

Target conceptual authoring shape:

```swift
let io = IO.system

let file = try io.openFile(...)
```

followed by a reader/writer construction in which caller storage remains
explicit:

```swift
withUnsafeTemporaryAllocation(
    of: UInt8.self,
    capacity: 4096
) { storage in
    var reader = file.reader(
        io: io,
        storage: ...
    )
}
```

The exact public spelling is not fixed by I0a.

The key contract is:

```text
IO
    execution/system-operation implementation

File
    native-resource ownership

Reader/Writer
    byte-flow + caller/owned staging memory
```

### Representation question to measure in I0b

Do not blindly reproduce Zig's userdata + C-style vtable.

Characterize at least the Swift-native representation selected for the initial
implementation against the current direct POSIX baseline at a complete
file-read/file-write path.

The dispatch benchmark already established that backend existential dispatch is
amortized acceptably under syscall-heavy Source/Destination workloads. That
finding should be reused rather than reopening generic-vs-existential backend
architecture unless the new IO boundary introduces measurable additional cost.

## Explicit non-goals for I0b

Do not:

- migrate Readers/Writers/HTTP yet;
- merge allocator capability into IO;
- move ring storage into IO;
- move Source/Destination state into IO;
- redesign SourceBackend/DestinationBackend genericity;
- duplicate Atomos clock primitives;
- migrate the entire filesystem surface in the first implementation pass;
- add abstraction merely to make a diagram symmetrical.

I0b succeeds when one real system-operation vertical slice routes through an
explicit `IO` value with ownership and performance characterized.
