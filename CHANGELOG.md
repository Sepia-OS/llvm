# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are named after the **upstream LLVM version** they package: `v23.1.0`
is LLVM 23.1.0, cross-built to run on the Raspberry Pi.

> This repository keeps **one release at a time**: publishing deletes every
> earlier release and its tag. Old commits stay reachable through their
> never-deleted `rel-<version>` branches, so an old toolchain can be rebuilt
> from source even after its tag is gone.

## [Unreleased]

### Fixed

- libc++'s unsatisfied `libatomic.so.1` dependency. The shipped libc++ recorded
  a `DT_NEEDED` for a library nothing on the card provides — and not one symbol
  was referenced through it — which killed every program at exec on a card that
  did not have it. This is the failure that the closure checks in every sibling
  repository were written because of.

### Added

- Per-runtime log output, so a failure names which runtime was being built.

## [23.1.0] - 2026-09-02

### Added

- The whole build: fetch the LLVM sources, cross-build clang, lld and the LLVM
  binutils equivalents for `aarch64-unknown-linux-musl`, and publish the result
  as one `usr/` tree — 2,361 entries, ~180 MiB — that `rootfs` unpacks onto the
  card.
- The runtimes beside the compiler: libc++, libc++abi, libunwind, compiler-rt's
  builtins and the GNUstep Objective-C runtime, so the card compiles C, C++ and
  Objective-C.
- CI on every commit and branch, and a manual release workflow.

### Fixed

- Two CI pipeline failures found on the first runs.

[Unreleased]: https://github.com/Sepia-OS/llvm/compare/v23.1.0...HEAD
[23.1.0]: https://github.com/Sepia-OS/llvm/releases/tag/v23.1.0
