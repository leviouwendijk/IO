# IO Hazard Characterization

This file records hazard findings that must survive individual repair passes.
It mirrors `PERFORMANCE.md`: first characterize actual behavior on the target
build, then change production code, then re-run the same fixtures.

## V0: characterization only

`tio_hazard` runs every probe in an isolated child process
(`tio_hazard --hazard-probe <id>`). SIGPIPE deaths, runtime traps, and hangs are
recorded as observations; the parent always exits 0.

Verdicts describe current behavior:

- `PRESENT`: the audited hazard reproduced;
- `ABSENT`: the fixture was established and the hazard did not occur;
- `INCONCLUSIVE`: the fixture could not be established, or a stress probe did
  not observe a race that is structurally proven by inspection.

No production source is modified by V0.

## Probe map

| Probe | Finding | Isolation | Desired post-fix behavior |
| --- | --- | --- | --- |
| `bounded-stream-wrapped-ring` | #1 | child | bounded stream bounds against the first contiguous region; destination receives 6...19 |
| `socket-peer-close-vector-write` | #2 | child | EPIPE surfaces as an error; no SIGPIPE |
| `socket-peer-close-scalar-send` | #2 | child | same, scalar path (Darwin `SO_NOSIGPIPE`) |
| `pipe-destination-peer-close` | #2 | child | documented policy for pipes (caller-level SIGPIPE handling) |
| `socket-after-close-fd-reuse` | #3b | child | closed backend never issues syscalls on its old descriptor number |
| `reactor-shutdown-wake-churn` | #3a | child, stress | wake pipe closed only when no `wake()` can run; stress may stay inconclusive |
| `wait-negative-fd-*` | #4 | child, timeout | prompt `.invalid_descriptor` on both runtimes, with or without deadline |
| `wait-empty-interest-*` | #4 | child, timeout | prompt error on both runtimes; no trap, no hang |
| `cross-runtime-deadline` | #5 | child | a 20 ms deadline means ~20 ms on any `IO` |
| `computed-blocking-runtime-deadline` | #5 | child | an expired deadline times out immediately through `IO.blocking` |
| `run-blocking-cancellation-completion` | #6 | child | once started, completion wins over cancellation |
| `destination-progress-before-error` | #7a | child | `write` returns `.partial(accepted)` before any further throwing drain |
| `scanner-kernel-*-index` | #8b | child | scanner rejects out-of-range/backward kernel indices before pointer arithmetic (throws) |
| `scanner-throw-progress` | #9 | child | successfully returned fragments are committed; only the throwing fragment replays |
| `line-fingerprint-structure` | fp | child | structurally different line arrays never collide by construction |
| `close-on-exec-descriptors` | #11 | child | every library-opened descriptor carries `FD_CLOEXEC` |
| `darwin-large-direct-write` | #10 | child | >INT_MAX transfers are chunked at the syscall boundary |
| `deep-tree-remove-descriptor-limit` | fs | child, rlimit 64 | removal depth is not bounded by the descriptor limit |
| `replace-permission-window` | fs | child, stress | replacement carries the original's metadata before it becomes visible |

Not characterized in V0: `readdir`-during-unlink skipping (not deterministic on
APFS), Linux no-replace move TOCTOU (Darwin target uses `renamex_np`), durable
replace (`fsync`) policy.

## V0 results

Run 2026-09-24 · `swift run tio_hazard` · debug build · arm64e macOS · 23 present, 0 absent, 1 inconclusive.

| Probe | V0 verdict | Observation |
| --- | --- | --- |
| `bounded-stream-wrapped-ring` | PRESENT | destination received `[6, 7, 0, 0, 0, 0, 0, 0, 14…19]`; six bytes read past the first physical region (allocator padding happened to be zero) |
| `socket-peer-close-vector-write` | PRESENT | killed by SIGPIPE |
| `socket-peer-close-scalar-send` | PRESENT | killed by SIGPIPE |
| `pipe-destination-peer-close` | PRESENT | killed by SIGPIPE |
| `socket-after-close-fd-reuse` | PROBE DEFECT | child died of SIGPIPE before refill/drain: the kernel reused the closed descriptor number for the replacement socketpair itself, and the probe then closed it; probe fixed in cluster 1 |
| `destination-progress-before-error` | PRESENT | write threw after the backend accepted 3 caller bytes |
| `darwin-large-direct-write` | PRESENT | >INT_MAX direct write rejected with EINVAL |
| `wait-negative-fd-blocking` | PRESENT | hang |
| `wait-negative-fd-blocking-deadline` | PRESENT | `timed_out` after 102.1 ms instead of `invalid_descriptor` |
| `wait-negative-fd-evented` | PRESENT | hang |
| `wait-empty-interest-blocking` | PRESENT | hang |
| `wait-empty-interest-evented` | PRESENT | SIGTRAP, `evented-io-runtime.swift:325` precondition |
| `cross-runtime-deadline` | PRESENT | 20 ms deadline → 325.7 ms one way, 0.0 ms the other |
| `computed-blocking-runtime-deadline` | PRESENT | expired deadline still waited 21.2 ms |
| `run-blocking-cancellation-completion` | PRESENT | produced 42, caller received `CancellationError` |
| `reactor-shutdown-wake-churn` | INCONCLUSIVE | no stray write in 400 races; race remains structurally proven |
| `scanner-kernel-negative-index` | PRESENT | SIGTRAP, `UnsafeRawBufferPointer with negative count` |
| `scanner-kernel-past-end-index` | PRESENT | callback received fragment count 33 over 17 readable bytes |
| `scanner-kernel-backward-index` | PRESENT | SIGTRAP, negative count |
| `scanner-throw-progress` | PRESENT | resumed scan replayed `"one"` |
| `line-fingerprint-structure` | PRESENT | `["a\nb"] ≡ ["a", "b"]`, `["a", ""] ≡ ["a\n"]` |
| `close-on-exec-descriptors` | PRESENT | SystemFileSource, SystemFileDestination, and both wake-pipe descriptors lack `FD_CLOEXEC` |
| `deep-tree-remove-descriptor-limit` | PRESENT | `errno 24` (`process_file_limit`) at depth 120 under soft limit 64; tree left partially removed |
| `replace-permission-window` | PRESENT | 0644 observed 3111 times across 300 replaces; the window is wide, not narrow |

## Cluster 1: memory and process safety

Findings #1, #2, #3b, #8b. Gate: `tio_hazard_gate` runs only the probes listed in
`HazardRunner.repairedProbeIDs` and exits 1 unless every one is ABSENT.

- #1 `Source.stream(to:maximumCount:)`: the bounded path now bounds against the
  first contiguous readable region, exactly like the unbounded path.
- #2 `POSIXBrokenPipeSignal`: Darwin sockets get `SO_NOSIGPIPE`, Darwin pipes/FIFOs
  get `F_SETNOSIGPIPE`; Linux socket sends pass `MSG_NOSIGNAL`. The socket vector
  drain now uses `sendmsg` so the flag reaches the vector path.
  `SystemFileDestination` suppresses the signal for pipes/FIFOs/sockets at open.
  Linux pipes remain a caller/process policy.
- #3b `NonblockingSocketBackend`: every syscall runs under the lifecycle lock shared
  with `close()` and is refused with `EBADF` once closed; `closed` is no longer
  an unsynchronized field. The scalar `EINTR` retry is a loop, not recursion.
- #8b `ByteLineScanner`: kernel-reported indices outside
  `fragmentStart..<readable.count` throw
  `StreamContractError.byte_match_index_out_of_range` before any pointer
  arithmetic; this also rejects backward indices.

### Cluster 1 run (2026-09-24, debug, arm64e macOS)

`tio_hazard`: 16 present, 6 absent, 2 inconclusive. `tio_hazard_gate`: FAILED (exit 1).
`tio_core` 19/19, `tio_stream` 20/20, `tio_scan` 6/6, `tio_file` 19/19.

| Probe | Verdict | Observation |
| --- | --- | --- |
| `bounded-stream-wrapped-ring` | ABSENT | logical sequence 6...19 delivered |
| `socket-peer-close-vector-write` | INCONCLUSIVE | backend init threw: `SO_NOSIGPIPE` refused with `EINVAL` |
| `socket-peer-close-scalar-send` | INCONCLUSIVE | same |
| `pipe-destination-peer-close` | ABSENT | `EPIPE` (errno 32), process survived |
| `socket-after-close-fd-reuse` | ABSENT | kernel reused descriptor 3 naturally; refill/drain refused with `EBADF` |
| `scanner-kernel-*-index` | ABSENT | all three rejected with `byte_match_index_out_of_range` |
| `reactor-shutdown-wake-churn` | PRESENT | child killed by SIGPIPE at iteration 200+: a late `wake()` wrote into a closed or reused pipe; the #3a race is now observed, not only proven structurally |

Finding: Darwin refuses `SO_NOSIGPIPE` (`EINVAL`) on a socket that is already shut
down in both directions, which is exactly the state both socket probes create
(peer closed before adoption). Throwing from `init` was too strict, and silently
continuing would leave writes that raise SIGPIPE.

### Cluster 1b

- `POSIXBrokenPipeSignal.suppress` returns a typed `Suppression`
  (`suppressed`, `not_applicable`, `socket_already_shut_down`, `failed(errno)`).
- `NonblockingSocketBackend` adopts an already shut-down socket but refuses its
  writes with `EPIPE` without entering the kernel; reads still drain buffered data
  and observe EOF. The closed check still wins (`EBADF` after `close()`).
- `SystemFileDestination` refuses to open an already shut-down socket (`EPIPE`).
- New probe `socket-peer-close-after-adopt` (#2) covers the realistic ordering:
  adopt a live socket, lose the peer, then write. It joins the gate.

### Cluster 1b run (2026-09-24, debug, arm64e macOS)

`tio_hazard`: 15 present, 9 absent, 1 inconclusive. `tio_hazard_gate`: passed, 9/9 ABSENT.
`tio_core` 19/19, `tio_stream` 20/20, `tio_scan` 6/6, `tio_file` 19/19.

All four socket/pipe broken-pipe probes surface `EPIPE` (errno 32) and survive; the
adopted-after-shutdown sockets now take the refused-write path. `reactor-shutdown-wake-churn`
was INCONCLUSIVE again (400 races, no observation); its cluster 1 SIGPIPE shows the race
is timing-dependent, not absent.

Baseline commit `fb64617`: explicit-IO restructure, hazard harness, and cluster 1/1b
repairs, committed before cluster 2 so later diffs are reviewable.

## Cluster 2: execution

Findings #3a, #4, #5, #6. Gate grows by the eight wait/deadline/runBlocking probes.

- #5 `IOMonotonicDomain`: one process-wide anchor on Atomos `MonotonicClock` replaces the
  per-runtime epochs. `IO.deadline(after:)` reads it directly and both built-in runtimes
  report it from `monotonicNanoseconds()`, so a deadline means the same instant on any
  `IO`, including successive `IO.blocking` values.
- #4 `IO.wait`, `BlockingIORuntime`, and the evented reactor reject negative descriptors
  (`invalid_descriptor`) and empty interest (new `IOExecutionError.invalid_interest`)
  before touching `poll`. The reactor's `precondition` is gone.
- #6 `IO.runBlocking` checks cancellation only before submission; once the operation has
  run, its value is returned even if the caller was cancelled.
- #3a The reactor's wake pipe is closed in `deinit` instead of at the end of `run()`, so no
  late `wake()` can write into a closed or reused descriptor. The stress probe stays
  ungated because it can never prove absence.

### Cluster 2 run (2026-09-24, debug, arm64e macOS)

`tio_hazard`: 7 present, 17 absent, 1 inconclusive. `tio_hazard_gate`: passed, 17/17 ABSENT.
`tio_exec` 20/20, `tio_core` 19/19, `tio_stream` 20/20, `tio_scan` 6/6, `tio_file` 19/19.

| Probe | Verdict | Observation |
| --- | --- | --- |
| `wait-negative-fd-*` (3) | ABSENT | rejected with `invalid_descriptor` after 0.0 ms |
| `wait-empty-interest-*` (2) | ABSENT | rejected with `invalid_interest` after 0.0 ms; no trap |
| `cross-runtime-deadline` | ABSENT | 20 ms deadline waits ~21-22 ms in both directions |
| `computed-blocking-runtime-deadline` | ABSENT | expired deadline returns after 0.1 ms |
| `run-blocking-cancellation-completion` | ABSENT | already-running operation delivered 42 despite cancellation |
| `reactor-shutdown-wake-churn` | INCONCLUSIVE | structural fix applied; stress probe cannot prove absence |

## Cluster 3: progress accounting

Findings #7a, #9, #10. Gate grows by `destination-progress-before-error`,
`darwin-large-direct-write`, and `scanner-throw-progress`.

- #7a A backend failure after `Destination.write` accepted a prefix no longer hides that
  prefix: the write returns `.partial(accepted)` and the failure is deferred to the next
  `write` or `flush`, which throws it once. A failure with nothing accepted still throws
  immediately with its original type.
- #9 `ByteLineScanner.scan` commits consumed bytes and line state for every fragment whose
  callback returned, even when a later callback throws; the failing fragment is delivered
  again on the next scan. Fragment and line counters advance only after the callback
  returns, so a redelivered fragment is not counted twice.
- #10 `POSIXTransferLimit` caps every read/write-family syscall at `0x7FFF_F000` bytes
  (Darwin rejects counts above `INT_MAX` with `EINVAL`; Linux caps at the same value). The
  resulting short transfer is handled by the existing Source/Destination loops.

### Cluster 3 run (2026-09-24, debug, arm64e macOS)

`tio_hazard`: 4 present, 20 absent, 1 inconclusive. `tio_hazard_gate`: passed, 20/20 ABSENT.
`tio_exec` 20/20, `tio_core` 19/19, `tio_stream` 20/20, `tio_scan` 6/6, `tio_file` 19/19.

| Probe | Verdict | Observation |
| --- | --- | --- |
| `destination-progress-before-error` | ABSENT | write reported `.partial(3)` matching the backend-accepted prefix |
| `darwin-large-direct-write` | ABSENT | 2 GiB + 4 KiB direct write to `/dev/null` completed through clamped syscalls |
| `scanner-throw-progress` | ABSENT | resumed scan delivered `["two", "three"]`; `"one"` not replayed |

## Cluster 4: descriptors and filesystem

Findings #11, deep-tree removal, replace permission window, line fingerprint structure.
Gate grows by the four remaining probes; only `reactor-shutdown-wake-churn` stays ungated.

- #11 `SystemFileSource` and `SystemFileDestination` open with `O_CLOEXEC`; the reactor
  wake pipe gets `FD_CLOEXEC` right after `pipe` (Darwin has no `pipe2`).
- Deep-tree removal: recursive removal holds at most 16 directory streams. Deeper
  subtrees are emptied by `removeDirectoryContentsBounded`, which descends one level at
  a time, climbs back through `..`, and verifies each ascent by device/inode (`ESTALE`
  if the tree moved concurrently).
- Replace permission window: the Darwin native replace applies the original's mode,
  birth time, and ACL to the replacement *before* the rename swap, so the original path
  never shows the replacement's own permissions. The probe now reports ABSENT when its
  observer (which previously caught the window thousands of times per run) sees nothing.
- Line fingerprints: `ContentFingerprint.fingerprint(for: [String])` length-frames each
  line and reports algorithm `fnv1a64-lines`. Values differ from earlier line
  fingerprints by design.

### Cluster 4 run (2026-09-24, debug, arm64e macOS)

`tio_hazard`: 0 present, 24 absent, 1 inconclusive. `tio_hazard_gate`: passed, 24/24 ABSENT.
`tio_fs` 20/20, `tio_exec` 20/20, `tio_core` 19/19, `tio_stream` 20/20, `tio_scan` 6/6, `tio_file` 19/19.

| Probe | Verdict | Observation |
| --- | --- | --- |
| `close-on-exec-descriptors` | ABSENT | source, destination, and both wake-pipe descriptors report `FD_CLOEXEC` |
| `deep-tree-remove-descriptor-limit` | ABSENT | depth-120 tree removed under soft `RLIMIT_NOFILE` 64; root gone |
| `replace-permission-window` | ABSENT | no 0644 observation across 300 replaces |
| `line-fingerprint-structure` | ABSENT | structurally different line arrays fingerprint differently |

Only `reactor-shutdown-wake-churn` (#3a) remains INCONCLUSIVE: structurally repaired in cluster 2,
but a stress probe cannot prove absence, so it stays outside the gate.

## Cluster 5: Linux no-replace move

- Linux `FileSystem.c.move` previously checked the destination with `lstat` and then called
  plain `rename(2)`, which replaces; a destination created in between was silently
  overwritten. `systemRenameNoReplace` now uses `renameat2(RENAME_NOREPLACE)` (resolved with
  `dlsym`, since the Glibc module does not import it), which fails atomically with `EEXIST`.
  The `lstat` + `rename` path remains only as a fallback for `ENOSYS`/`EINVAL`/missing symbol.
- Verification gap: the harness is Darwin-only and this cluster's build compiles only the
  Darwin branch. The Glibc branch is unbuilt and unprobed until a Linux run exists.

## Cluster 6: deterministic #3a check

- The cluster 2 repair made the wake pipe close only in the reactor's `deinit`. Because `wake()`
  is an instance method, a running `wake()` keeps the reactor alive, so the descriptors cannot
  be closed or reused under it. The stress probe could never show that.
- `reactor-wake-after-shutdown` checks it directly through package-only hooks on
  `EventedIORuntime` (`wakePipeDescriptorsForTesting`, `wakeForTesting`): after `shutdown()`
  the pipe descriptors keep their FIFO identity, 16 freshly opened files never receive their
  numbers, 1000 late `wake()` calls write nothing into those files, and the pipe closes only
  after the runtime is released. The probe is gated; `reactor-shutdown-wake-churn` stays as an
  ungated stress characterization.

### Cluster 6 run (2026-09-24, debug, arm64e macOS)

`tio_hazard`: 0 present, 25 absent, 1 inconclusive. `tio_hazard_gate`: passed, 25/25 ABSENT.
`tio_exec` 20/20.

| Probe | Verdict | Observation |
| --- | --- | --- |
| `reactor-wake-after-shutdown` | ABSENT | wake pipe kept its identity through shutdown and 1000 late wakes; no fresh descriptor affected; closed on release |
| `reactor-shutdown-wake-churn` | INCONCLUSIVE | ungated stress characterization; no stray write across 400 races |

Every audit finding now has a gated probe. Open outside the harness: the cluster 5 Glibc
branch is unbuilt and unprobed, and Atomos is still pinned to `branch: "master"`.
