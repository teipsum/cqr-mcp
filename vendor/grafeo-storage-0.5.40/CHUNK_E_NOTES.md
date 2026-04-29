# CHUNK E — vendored hot-fix for grafeo-storage 0.5.40

**Date:** 2026-04-29
**Author:** Michael Lewis Cram (cramml@gmail.com)
**Branch:** feature/grafeo-storage-v2-readpatch
**Upstream status:** not yet PR'd; planned as Chunk F

## Why

`grafeo-storage::file::manager::GrafeoFileManager::read_snapshot` is
unconditionally a v1 reader. It reads `snapshot_length` bytes at
`DATA_OFFSET`, computes their CRC32, and compares to the active header's
`checksum` field.

The same crate writes a second on-disk format ("v2") via the section
directory path (see `flush.rs` and `section_consumer.rs`). v2 files set
`snapshot_length = 0` and reuse the `checksum` field to hold the section
directory's CRC. When `read_snapshot` is invoked on a v2 file, it reads
0 bytes, hashes to `0x00000000`, and fails:

    GRAFEO-X001: snapshot checksum mismatch:
    expected 0xXXXXXXXX, got 0x00000000

`grafeo-engine` does have a correct dispatch — it tries
`read_section_directory` first and only falls back to `read_snapshot`
when that returns `None`. But `read_section_directory` returns `None`
silently on parse failures, and in our build configuration the engine's
v2 path lands in the v1 fallback for our existing
`~/.cqr/grafeo.grafeo` file, surfacing GRAFEO-X001.

## What

In `src/file/manager.rs`, immediately after the existing
`active_header.is_empty()` guard in `read_snapshot`, return
`Ok(Vec::new())` when `snapshot_length == 0`.

Diff is 13 lines added, 0 deletions, scoped entirely to that function.

## Why this is safe

- Legitimate v1 files always have `snapshot_length > 0`
  (`write_snapshot` at line ~279 sets `snapshot_length: data.len() as u64`,
  and an empty `data` is already caught by the preceding `is_empty()`
  guard which checks `iteration == 0`).
- For v2 files, returning an empty `Vec` lets the engine's open path skip
  `apply_snapshot_data` and proceed cleanly (sections are loaded by the
  v2 path or the in-memory store starts empty).
- For genuinely uninitialised files, the existing `is_empty()` guard
  fires first; this new branch is unreachable for them.

## Where applied

- `vendor/grafeo-storage-0.5.40/src/file/manager.rs`, function
  `pub fn read_snapshot(&self) -> Result<Vec<u8>>`, marked with
  `// PATCH(cqr-mcp): see CHUNK_E_NOTES.md`.

No other vendored file is modified.

## Wiring

`native/cqr_grafeo/Cargo.toml` declares:

    [patch.crates-io]
    grafeo-storage = { path = "../../vendor/grafeo-storage-0.5.40" }

so the redirect is local to the NIF crate's resolver. The vendored
`Cargo.toml` keeps `version = "0.5.40"` as required for
`[patch.crates-io]` to apply.

A source build of the NIF is required for the patch to take effect; the
default precompiled binary still contains the unpatched code. Set
`CQR_BUILD_NIF=true` (already set in `~/bin/cqr`) before
`mix deps.compile cqr_grafeo --force` or `mix compile --force`.

## Removal plan

When upstream lands a fix (planned Chunk F: file an issue / PR against
`GrafeoDB/grafeo`), bump the `grafeo-storage` constraint in
`native/cqr_grafeo/Cargo.toml` to the fixed version, delete the
`[patch.crates-io]` section, and remove this `vendor/` directory.
