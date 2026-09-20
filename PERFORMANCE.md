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

R0g remains experimental until it matches the full semantic fixture and its counterbalanced benchmark justifies promotion.
