# IO Performance Findings

This file records benchmark-backed implementation findings that should survive individual optimization passes.

## Filesystem resolution

### Semantic contract

`FileSystem.resolve(_:)` is nonthrowing.

The R0a characterization established:

- fully resolvable regular paths and symbolic links return a canonical resolved path;
- relative and absolute symbolic-link targets resolve;
- directory symbolic links and children through them resolve;
- chained links and `..` inside link targets resolve;
- lexical `.` / `..` are normalized;
- if complete resolution fails because of a missing component, broken link, or symbolic-link loop, the original path is returned in lexically standardized form rather than partially resolved.

The `.foundation` implementation remains the reference oracle while native candidates are developed.

### R0b: naive native `realpath`

The first native implementation used:

`URL -> standardizedFileURL -> NativePath -> realpath -> URL -> standardizedFileURL`

It was approximately 1.8–2.1x slower than Foundation on successfully resolved regular/symlink paths.

This was not evidence that POSIX resolution is inherently slower. It exposed avoidable boundary work.

### R0c decomposition

Measured on the macOS development machine:

- `withUnsafeFileSystemRepresentation` is approximately 0.22 microseconds in these fixtures;
- eager `standardizedFileURL` is commonly about 6–13 microseconds;
- `NativePath(fileSystemURL:)` preparation commonly costs about 10–18 microseconds because it standardizes and copies filesystem bytes;
- `realpath(..., nil)` allocation was not the dominant cost;
- a fixed `PATH_MAX` buffer and libc-allocated `realpath` output were broadly similar.

Conclusion:

Do not automatically convert a public `URL` into `NativePath` for a one-shot POSIX operation. `NativePath` is valuable when a path stays native across multiple operations/traversal steps.

### R0d: lazy input standardization

Changing the candidate shape to:

success:
`URL -> filesystem representation -> realpath -> URL -> standardizedFileURL`

failure:
`URL -> standardizedFileURL`

removed most of the self-inflicted overhead.

Observed median results showed:

- regular file: native fixed-buffer candidate about 1.26x faster than Foundation;
- missing leaf: about 1.14x faster;
- broken link: about 1.40x faster;
- symlink loop: about 1.24x faster;
- relative link, directory link, and symlink chain still about 10–20% slower than Foundation.

The remaining successful-symlink gap strongly implicates the final `standardizedFileURL`.

On macOS, `realpath` exposes paths such as `/private/var/...`; Foundation standardization presents these as `/var/...`. A native implementation therefore needs equivalent presentation semantics without paying the full Foundation normalization cost.

## Current experiment

R0e compares:

1. fixed-buffer `realpath` with a narrow native Darwin presentation rewrite for `/private/var`, `/private/tmp`, and `/private/etc`;
2. a leaf-first `lstat/readlink` resolver for symbolic-link chains, falling back to the native-presentation `realpath` path when intermediate-component resolution is required.

Both candidates must match the complete R0a semantic fixture before their benchmark results are accepted.

## General optimization rule

Prefer:

`public representation -> one native boundary -> public representation`

for isolated operations.

Prefer:

`native representation -> syscall -> native representation -> syscall -> ...`

when a traversal or composed operation can amortize native-path construction.

Do not add an abstraction, allocator, normalization pass, or representation conversion merely because it is lower-level. Measure the complete path.

### R0e: native presentation and leaf readlink

Both R0e candidates matched the full R0a semantic fixture.

The narrow native Darwin presentation rewrite removed the final Foundation `standardizedFileURL` cost. Fixed-buffer `realpath` then beat Foundation on most rows, including regular files and the intermediate-directory-symlink case.

The leaf-first `lstat/readlink` hybrid was substantially faster on leaf symbolic links and failure paths:

- relative file link: about 2.98x Foundation;
- absolute file link: about 3.05x;
- directory link: about 2.77x;
- parent-relative target: about 3.66x;
- target containing `..`: about 2.26x;
- broken link: about 1.76x;
- missing leaf: about 2.31x;
- missing child through a directory link: about 2.75x;
- symbolic-link loop: about 3.89x.

The remaining losing rows exposed dispatch rather than syscall limitations:

- child through a directory link: the leaf hybrid first performs `lstat`, discovers the leaf is regular, then falls back to native `realpath`; the native-presentation `realpath` path itself already beats Foundation here;
- lexical `..`: both realpath-based candidates perform filesystem canonicalization for a path whose structure can potentially be handled more cheaply with component-aware lexical resolution.

### R0f: adaptive component resolution

R0f keeps the proven R0e fast paths and invokes a component-wise `lstat/readlink` resolver only when the input contains lexical `.` or `..` components.

The component walker processes symbolic-link targets and lexical components in resolution order, so `..` is applied after any preceding link target has been expanded. This avoids globally pre-normalizing `..`, which would be incorrect when the component being crossed is itself a symbolic link.

R0f matched the full semantic fixture.

Measured R0f medians showed that the adaptive pre-scan preserved large wins on most symbolic-link and failure rows, but three dispatch costs remained visible:

- regular file: approximately parity with Foundation (0.995x);
- child through directory link: about 0.881x Foundation;
- lexical `..`: about 0.904x Foundation.

The component walker itself still used `lstat` to classify each component before using `readlink` for a symbolic link, and the adaptive entry point scanned the complete pathname before beginning resolution.

### R0g: readlink-first dispatch

R0g removes both classification layers.

The candidate first calls `readlink` on the complete leaf:

- success means the leaf is a symbolic link and enters a direct `readlink` chain;
- `EINVAL` means the final object is not a symbolic link and enters a component walker;
- other failures preserve the established standardized-original fallback immediately.

The component walker uses `readlink` itself as the classifier. `EINVAL` means an ordinary component; successful `readlink` expands the symbolic-link target. It therefore does not need `lstat` before `readlink`.

The initial full-path `readlink` also proves an ordinary final leaf is not a symbolic link, allowing the component walker to skip re-probing that final component.

R0g remained experimental until R0h added adversarial semantic fixtures and completed the final selection.


### R0h: hardened readlink-first resolver selected

R0h extended the semantic fixture with adversarial symlink-target cases that require filesystem-order resolution rather than lexical collapse:

- a leaf symbolic link targeting a child through an intermediate directory symbolic link;
- a leaf reached through a directory symbolic link with a parent-relative target;
- a link target whose `..` crosses a symbolic link whose resolved parent differs from its lexical parent.

The hardened candidate matched Foundation across the expanded fixture.

The final heavy counterbalanced benchmark remained faster than Foundation on every characterized row. Representative median speedups included:

- regular file: 2.367x;
- relative file link: 1.769x;
- absolute file link: 1.697x;
- child through directory link: 2.115x;
- symbolic-link chain: 1.486x;
- leaf target through directory link: 2.265x;
- leaf under directory link with parent-relative target: 1.266x;
- target `..` crossing a symbolic link: 1.432x;
- broken link: 2.089x;
- missing leaf: 1.761x;
- missing child through directory link: 2.363x;
- symbolic-link loop: 4.517x;
- lexical `..`: 1.597x.

This closes R0. The readlink-first/component-walking implementation is the selected native production resolver. Foundation remains the semantic/performance reference backend rather than the implementation behind `.c.resolve`.

### R0 follow-up: recover leaf fast-path headroom

An earlier R0g heavy run produced materially larger speedups than the hardened production resolver on several simple leaf-symbolic-link rows. Representative R0g measurements included approximately 4.93x Foundation for an absolute file link, 3.51x for a parent-relative target, and 4.61x for a link target containing `..`.

R0h intentionally added a second component-resolution phase when a leaf chain reaches an ordinary object. That phase is required for the adversarial cases where an intermediate symbolic link changes the meaning of a later `..`. Production remains faster than Foundation across the characterized matrix, but some easy leaf cases now have visible optimization headroom.

The R0g and production figures came from separate heavy runs, so they should not be interpreted as a precise same-run regression measurement. Treat them as a future optimization lead: construct a controlled R0g-versus-production benchmark and look for a cheap discriminator or fast path that preserves the full R0h semantic contract before changing production.


## Filesystem mutation

### M4: native simple namespace mutation baseline

M4 promoted native `mkdir`, file/symlink removal, empty-directory removal, and same-filesystem no-replace rename behind `FileSystem.c`. The semantic suite passed 18/18 after matching Foundation's successful no-op behavior for an existing same-path move.

The first heavy benchmark showed that the native algorithms beat the wrapped `FileSystem.foundation` lane on several rows but had not yet beaten raw `FileManager.default` consistently:

- create empty directory: 0.849x raw FileManager and 0.996x wrapped Foundation;
- create deep intermediates: 0.961x raw FileManager and 1.069x wrapped Foundation;
- remove 4 KiB file: 0.839x raw FileManager and 1.250x wrapped Foundation;
- move 4 KiB file: 0.901x raw FileManager and 1.097x wrapped Foundation.

The dominant avoidable costs are visible in the implementation rather than the syscalls themselves: eager `standardizedFileURL` on every common-path mutation, `lstat` before `unlink` for regular files, and a Darwin destination preflight before `renamex_np(RENAME_EXCL)`.

M4b therefore bypasses Foundation file-path standardization on ordinary paths, but retains the exact `standardizedFileURL` compatibility path when a `.` / `..` component is present. On Apple platforms that standardization can consult the filesystem while resolving parent components across symbolic links; it must not be modeled as purely lexical normalization. M4b also makes regular file/symlink removal `unlink`-first and lets Darwin exclusive rename perform its own destination collision test.

The M4b heavy rebenchmark materially changed the picture:

- create empty directory: 0.952x raw FileManager, 1.208x wrapped Foundation;
- create deep intermediates: 1.013x raw FileManager, 1.107x wrapped Foundation;
- remove 4 KiB file: 1.120x raw FileManager, 1.359x wrapped Foundation;
- move 4 KiB file: 1.158x raw FileManager, 1.448x wrapped Foundation.

The common-path optimization therefore converged remove and move above raw FileManager and brought deep intermediate creation to slight parity/win. Empty-directory creation is the only remaining simple M4 row below the raw FileManager target, by roughly two microseconds per operation in this run.

M4c isolates that row before changing production again. It compares raw `mkdir` on prebuilt C bytes, one URL filesystem-representation borrow, one borrow plus the dot-component scan, the current two-borrow scan shape, full `FileSystem.c`, and raw FileManager. The purpose is to prove whether a fused one-borrow production path has enough headroom to cross FileManager.


### M4d/M4e: create strategy correction

The first `mkpath_np` production run appeared to regress deep creation, but that run came from the older cross-tree benchmark shape. M4e therefore restored the manual walker, removed its duplicate full-path failure probe, fused ordinary creation into one URL filesystem-representation borrow, and introduced a paired strategy benchmark with equal-length lane names under the same per-round parent and per-round lane rotation.

The paired M4e benchmark supersedes the earlier create-strategy conclusion.

For empty-directory creation:

- raw FileManager: 41.379 microseconds median;
- prebuilt C path + `mkdir`: 37.676 microseconds, 1.098x FileManager;
- prebuilt C path + `mkdirat(AT_FDCWD, ...)`: 41.019 microseconds, 1.009x;
- one URL borrow + lexical scan + `mkdir`: 41.960 microseconds, 0.986x;
- pre-opened parent fd + relative `mkdirat`: 39.369 microseconds, 1.051x;
- production `FileSystem.c`: 38.869 microseconds, 1.065x.

The paired result confirms that empty creation is converged above raw FileManager and that the earlier decomposition had enough filesystem/path-layout variance to reverse candidates separated by only a few microseconds.

For deep intermediate creation:

- raw FileManager: 267.842 microseconds median;
- production manual walker: 267.168 microseconds, 1.003x FileManager;
- `mkpath_np`: 266.820 microseconds, 1.004x;
- `mkpathat_np(AT_FDCWD, ...)`: 260.380 microseconds, 1.029x;
- pre-opened parent fd + relative `mkpathat_np`: 238.432 microseconds, 1.123x.

The corrected benchmark therefore does not show `mkpath_np` itself to be slower than FileManager; it shows the one-shot `mkpathat_np(AT_FDCWD, ...)` form as the best directly promotable public-URL strategy, while a retained parent directory descriptor exposes materially larger headroom for composed/native work.

M4f promotes `mkpathat_np(AT_FDCWD, ...)` for Darwin intermediate creation, retains the manual walker as the Glibc implementation, removes a double-close from the empty-create benchmark, and adds a known-parent end-to-end lane that times `open(parent) + relative mkpathat_np + close`. That lane tests how much of the retained-directory lower bound survives descriptor acquisition; it still assumes the existing parent and relative remainder are already known, so it is not yet a complete one-shot parent-discovery algorithm.


### M4f result and M4g production-path decomposition

The M4f paired benchmark strengthened the Darwin `mkpathat_np` result and clarified the directory-descriptor boundary.

For deep intermediate creation:

- raw FileManager: 228.416 microseconds median;
- production `FileSystem.c`: 227.504 microseconds, 1.004x FileManager;
- `mkpath_np`: 222.618 microseconds, 1.026x;
- `mkpathat_np(AT_FDCWD, ...)`: 206.183 microseconds, 1.108x;
- pre-opened parent fd + relative `mkpathat_np`: 203.272 microseconds, 1.124x;
- known-parent `open + mkpathat_np + close`: 240.682 microseconds, 0.949x.

Opening the parent directory solely for a one-shot create is therefore not worthwhile. The larger parent-fd win belongs to retained directory context and should inform composed/tree work rather than the public one-shot URL operation.

For empty creation, the same paired run measured prebuilt `mkdirat(AT_FDCWD, ...)` at 1.087x FileManager while production `FileSystem.c` was approximately parity. The create strategy is therefore no longer blocked on finding a native primitive; it is blocked on locating the remaining production-path overhead above the primitive.

M4g is measurement-only. It decomposes both empty and deep production paths with equal-length per-round lanes:

- prebuilt native path + selected native primitive;
- URL filesystem-representation borrow + primitive;
- URL borrow + the production-shaped forced-inline lexical dot-component scan + primitive;
- cached `FileSystem.Directory`;
- cached `FileSystem`;
- full `FileSystem.c.directory`.

The previous strategy benchmark's local dot-component helper was intentionally `@inline(never)`, so it was not a faithful measurement of the production scanner, which is `@inline(__always)`. M4g corrects that mismatch before any further production rewrite.


### M4 closeout and M5a native recursive remove

The M4g production-path decomposition showed that the remaining create-layer differences are below the stable filesystem/noise floor rather than a large deterministic `FileSystem` wrapper tax.

In the M4g heavy paired run, empty-directory creation measured:

- raw FileManager: 53.062 microseconds median;
- prebuilt `mkdirat(AT_FDCWD, ...)`: 46.451 microseconds, 1.142x FileManager;
- URL borrow + `mkdirat`: 48.661 microseconds, 1.090x;
- URL borrow + forced-inline lexical scan + `mkdirat`: 44.039 microseconds, 1.205x;
- cached `FileSystem.Directory`: 48.290 microseconds, 1.099x;
- cached `FileSystem`: 51.261 microseconds, 1.035x;
- full `FileSystem.c.directory`: 47.612 microseconds, 1.114x.

The scan lane cannot intrinsically make the syscall faster, so the inversions among these close candidates are evidence that run-to-run filesystem/cache/scheduling variance is larger than the remaining Swift-layer cost. Darwin one-level creation therefore closes on `mkdirat(AT_FDCWD, ...)`, which is also structurally aligned with the retained-directory direction.

For deep intermediate creation, M4g measured raw FileManager at 219.250 microseconds, direct URL + `mkpathat_np(AT_FDCWD, ...)` at 217.090 microseconds, cached `FileSystem.Directory` at 207.649 microseconds, and full `FileSystem.c.directory` at 222.620 microseconds. The same lane inversions show that further one-shot micro-decomposition is not justified. Darwin keeps `mkpathat_np(AT_FDCWD, ...)`; Glibc keeps the explicit native intermediate creator.

M4 is therefore closed. The durable composed-work finding is that a directory descriptor which is already retained can provide meaningful headroom, whereas opening that parent solely for one one-shot create loses.

M5a replaces the non-empty-directory Foundation fallback with an fd-relative native recursive remover. Its traversal is depth-first postorder in filesystem terms:

- the root directory is opened once with `openat(..., O_DIRECTORY | O_NOFOLLOW)`;
- each directory stream is enumerated with `fdopendir` / `readdir`;
- `unlinkat(parent_fd, name, 0)` is the classifier and fast path for regular files, symbolic links, and other non-directory entries;
- only `EISDIR` / `EPERM` enters a child directory with `openat`;
- child directories are removed after their contents with `unlinkat(..., AT_REMOVEDIR)`;
- child names remain native C filesystem bytes throughout; no per-entry URL or Swift String is required;
- `O_NOFOLLOW` prevents the recursive boundary from following a symbolic link substituted at the leaf.

This is deliberately an IO-specific native postorder walker rather than a materialized `Tree<Value>`. The semantic traversal policy matches depth-first postorder and can inform later convergence with the general tree primitives without adding allocation or materialization to this syscall-critical path.


### M5a result and M5b directory-hint optimization

The first heavy run with the fully native M5a recursive remover remained semantically green but did not yet beat raw FileManager on the mixed-tree row:

- raw FileManager: 16.535 milliseconds median;
- wrapped Foundation: 16.279 milliseconds;
- native `FileSystem.c`: 17.059 milliseconds;
- native versus raw FileManager: 0.969x.

The fixture contains 16 branch directories. Each branch contains 16 regular files plus one nested `leaf` directory containing one payload file. Excluding the root, the traversal therefore encounters 32 directories and 272 files.

M5a intentionally used `unlinkat(parent_fd, name, 0)` as both the fast non-directory operation and the directory classifier. On this fixture that means 32 guaranteed failed `unlinkat` calls before opening the 32 child directories. The root path also paid `unlink -> lstat -> rmdir` before entering recursive traversal.

M5b removes those avoidable classification costs without changing the fd-relative postorder architecture:

- when `readdir` supplies `DT_DIR`, enter the child directory directly with `openat(..., O_DIRECTORY | O_NOFOLLOW)`;
- `DT_UNKNOWN` and every known non-directory type retain the safe unlink-first path, so files and symbolic links remain one namespace syscall on the common path;
- a stale `DT_DIR` hint cannot cause symlink traversal because `O_NOFOLLOW` remains mandatory, with a leaf unlink retry if the entry changed to a non-directory;
- the root `lstat` is removed: failed `unlink` is followed directly by `rmdir`; `ENOTDIR` preserves the original unlink error, while `ENOTEMPTY` / `EEXIST` enter the recursive walker.

For the current heavy fixture this removes up to 32 guaranteed failed child-directory unlink syscalls plus one root `lstat`. The existing mixed-tree benchmark remains the performance gate.


### M5b result

M5b crossed the recursive-removal performance gate while preserving the semantic suite:

- raw FileManager mixed-tree removal: 14.639 milliseconds median;
- wrapped Foundation: 14.228 milliseconds;
- native `FileSystem.c`: 13.111 milliseconds;
- native versus raw FileManager: 1.117x;
- native versus wrapped Foundation: 1.085x.

Compared with the preceding M5a native median of 17.059 milliseconds, using `dirent.d_type` as the directory fast hint reduced the measured native mixed-tree time by roughly 23%. M5 recursive removal is therefore closed on the fd-relative postorder design.

### M6: replacement characterization and selected Darwin regular-file strategy

M6 characterized `FileManager.default.replaceItemAt` before changing production. For a regular-file replacement with deliberately distinct metadata, the resulting original path receives:

- content and inode from the replacement;
- POSIX mode from the original;
- modification time from the replacement;
- creation/birth time from the original;
- BSD flags from the replacement;
- FinderInfo from the replacement;
- Finder comment from the replacement;
- arbitrary tested custom xattrs from the replacement;
- extended ACL from the original;
- no remaining replacement path.

A blanket `COPYFILE_METADATA` candidate was both semantically too broad and slower than FileManager because it restored metadata, including modification time, that Foundation leaves on the replacement object.

The selective candidate therefore uses Darwin `RENAME_SWAP`, then reapplies only the original POSIX mode and creation time before deleting the swapped-out original. Before ACL preservation was added, this exact shape measured 139.994 microseconds median against 252.391 microseconds for raw FileManager, or 1.803x faster.

M6e promotes the characterized regular-file path behind `FileSystem.c` and adds preservation of the original extended ACL. Both files are classified with `lstat` before the native path is entered and both ACLs are captured before mutation so the replacement object's metadata can be restored if a post-swap metadata operation fails. A failed native attempt swaps the names back before the Foundation compatibility path is used. Non-regular files, missing inputs, unsupported ACL filesystems, and non-Darwin platforms remain on Foundation.
