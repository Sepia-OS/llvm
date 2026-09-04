# SepiaOS - llvm

This repository builds **LLVM for SepiaOS**: `clang` and `lld`, cross-built to
run *on* the Raspberry Pi and linked against musl, so that a SepiaOS device can
compile for itself. It is not a cross-compiler for the development host, and it
does not replace the GCC toolchain the [rootfs](https://github.com/Sepia-OS/rootfs)
repository uses to build the system.

The result is published as a release asset, which `rootfs` unpacks into the
root filesystem.

```sh
gmake help              # every target
gmake toolchain-check   # prove the cross-compiler builds C++ against musl
gmake sources           # download and verify the LLVM sources
gmake sysroot           # build the musl sysroot the target links against
gmake sysroot-check     # prove C++ links dynamically against it
gmake tablegen          # host tablegen tools the cross-build needs
gmake llvm              # cross-build clang and lld (the long one)
gmake runtimes          # compiler-rt, libunwind, libc++abi, libc++
gmake objc-runtime      # the GNUstep Objective-C runtime
gmake stage             # install, prune and strip what ships
gmake stage-check       # aarch64, musl loader, complete library closure
gmake dist              # pack it into dist/ as the release asset
```

**On macOS, run `gmake`, not `make`.** `/usr/bin/make` is GNU Make 3.81, which
compares file timestamps only to the whole second and will silently reuse a
stale output after a fast edit. The Makefile refuses to run on it.

## Build steps

### 1. Retrieve the cross-compiler

A musl-targeting aarch64 cross-toolchain is downloaded and verified against
upstream's own digest.

| Host | Vendor | Default | Tools named |
|---|---|---|---|
| macOS | [messense](https://github.com/messense/homebrew-macos-cross-toolchains) | `15.2.0` | `aarch64-unknown-linux-musl-*` |
| Linux x86_64 | [bootlin](https://toolchains.bootlin.com) (Buildroot) | `2025.08-1` | `aarch64-linux-*` |

On macOS this is the `aarch64-unknown-linux-musl` build from the same
`messense` release that `rootfs` takes its compiler from — the same vendor and
the same version, but the musl variant rather than the gnu one.

**Two vendors are needed because neither covers both hosts.** messense
publishes darwin-hosted builds only; bootlin publishes Linux-hosted builds
only, and only for an x86_64 host. So macOS is the development host and Linux
is the release host — the same split `rootfs` uses, for the same reason: the
compiler differs by build host, so the binaries do too, and a release should
be cut in one place.

The two disagree about the triple they report — `aarch64-unknown-linux-musl`
against bootlin's `aarch64-buildroot-linux-musl` — so the triple the *product*
reports is pinned separately as `LLVM_TRIPLE`. A `clang` whose default target
depended on which machine cut the release would be a confusing artifact.

`rootfs` chooses the gnu variant deliberately, because it builds musl from
source and a toolchain with musl baked in would make that step a no-op. That
choice does not survive contact with C++: GCC's libstdc++ is coupled to glibc
in its *headers*, so a gnu-targeting compiler cannot build C++ against a musl
sysroot at all, whatever linker flags are used. LLVM is C++, so this repository
takes the musl variant.

`gmake toolchain-check` is that claim, checked: it compiles and links a program
using `std::string`, `std::vector` and exceptions, both dynamically and
statically, and fails loudly if either does not work.

Set `CROSS_COMPILE` to use a musl cross-toolchain already installed, in which
case nothing is downloaded.

### 2. Retrieve the LLVM sources

The pinned upstream release tarball — `llvm-project-<version>.src.tar.xz` — is
downloaded, not cloned: it is the artifact upstream signs, it carries no git
history, and it is a fraction of the monorepo's size.

LLVM publishes a detached GPG signature but no checksum sidecar, so the digest
is recorded under `checksums/` on the first fetch of a version and checked on
every fetch after that. `checksums/` is committed, which is what makes the pin
mean anything to anyone else.

### 3. Build the target sysroot

The shipped tools are **dynamically linked**, so they have to run against the
musl that is actually on the device. musl is therefore built here, pinned to
the same version `rootfs` ships — `checksums/musl-*.sha256` is copied from
`rootfs`, so both repositories compile byte-identical source.

It is built here rather than read out of `../rootfs/build/sysroot` for the
reason given in step 7: sibling repositories consume each other's *published
releases*, never each other's build trees. That is what keeps each one
buildable on its own, and in CI.

The cross-toolchain carries its own musl (1.2.5) baked into its sysroot, which
is **not** what ships, so `--sysroot` points at this tree instead. C++ headers
and libstdc++ are found through the compiler's own search paths, outside any
sysroot, so redirecting the sysroot replaces the libc without disturbing C++.
`gmake sysroot-check` confirms that, and confirms the result points at the
device's `/lib/ld-musl-aarch64.so.1`.

musl installs libc headers and nothing else, so the Linux UAPI headers are
copied in from the cross-toolchain's own sysroot — the same approach `rootfs`
takes, and one that cannot drift from the compiler.

> `rootfs` resolves musl as *latest* by default, so it can move out from under
> this pin. When it does, `MUSL_VERSION` and the copied checksum here have to
> move with it.

### 4. Build the native tablegen tools

LLVM generates a large amount of its own source with `llvm-tblgen` and
`clang-tblgen`, which run on the **build host** during the build. A
cross-build cannot produce them for itself, so they are built first in a
separate host tree — with the *host's* compiler, not the cross-compiler — and
handed to the target configuration.

That tree is configured as small as it can be: no tests, examples or
benchmarks, and none of the optional host libraries, so the build needs
nothing beyond a C++ compiler, CMake and Ninja.

Both binaries are executed as part of the step. A tablegen built for the wrong
machine is exactly the failure this step exists to prevent, and it stays
invisible until the target build tries to run it.

The sibling `rootfs` repository has the same shape in its `e2fsprogs` step,
which builds `mke2fs` and `debugfs` for the host and `resize2fs` for the target.

### 5. Cross-build clang and lld

The target build is configured for `aarch64-unknown-linux-musl` against the
sysroot from step 3, with `LLVM_DEFAULT_TARGET_TRIPLE` set to the same, so the
on-device `clang` needs no `--target` argument to build SepiaOS binaries.

The host tools from step 4 are handed over as `LLVM_NATIVE_TOOL_DIR` — "any
tool you need to *run* during this build, take it from here" — rather than by
naming `LLVM_TABLEGEN` and `CLANG_TABLEGEN` alone. Naming only those two
covers the obvious cases and leaves any other native helper to be built for the
target and then fail to execute.

Three things keep the result small, which matters because it lands on an SD
card next to a userland measured in megabytes:

- Only the **AArch64** backend is enabled. The device compiles for itself; it
  is not a build farm, and every extra backend costs tens of megabytes.
- LLVM and clang are each built as **one shared library** that every tool links
  against, rather than statically linking a copy into each binary.
- Only the toolchain is installed — not the internal headers, static archives
  and build-time utilities that exist to build LLVM rather than to use it.

The linker and runtime defaults are deliberately left at `libgcc` and
`libstdc++`, because those are precisely the runtime libraries this build
already ships, so the on-device `clang` defaults to what is actually present.

The built binaries are read back and checked: aarch64, and pointing at the
musl loader the device has. A cross-build succeeds just as happily when it has
produced binaries for the wrong machine.

### 5b. Build the LLVM runtimes

Step 5 produces a compiler. This produces the libraries that compiler emits
calls into, without which the shipped `clang` parses a program, generates code
for it, and then cannot link it: the driver asks for a builtins library, and for
C++ a standard library, and neither would be on the card.

| | |
|---|---|
| `compiler-rt` | the builtins — `__udivti3` and friends. Replaces `libgcc.a`. |
| `libunwind` | the unwinder. Replaces the one inside `libgcc_s`. |
| `libcxxabi` | the Itanium C++ ABI: exceptions, RTTI, vtable layout. |
| `libcxx` | the C++ standard library, headers included. |

They are built with a **host clang cross-targeting the device**, not with the
cross GCC that builds everything else here. The first version of this step did
use the cross GCC, and CI refuted it: LLVM 23's libc++ headers are written
against clang builtins GCC 14 does not have — `__is_unbounded_array`,
`__is_pointer`, `__builtin_operator_new`, `__decay`, `__add_lvalue_reference` —
so libc++abi died about 1700 ninja steps in, with the errors *inside the libc++
headers*. compiler-rt and libunwind build fine under GCC; libc++ is the one that
cannot.

The chicken-and-egg that made GCC attractive — CMake's compiler check links a
test program, which wants builtins this build has not produced yet — is handled
by pointing clang at the cross toolchain's own GCC installation: `--ld-path`,
`-L`, and `--gcc-install-dir` so that clang can find `crtbegin`/`crtend`, which
it otherwise looks for by triple, fails to locate, and passes to the linker as
bare filenames it cannot resolve. The runtimes therefore link against libgcc for their own needs, while
the *shipped clang* defaults to compiler-rt for user code. That default is set
in step 5 — `CLANG_RTLIB`, `CLANG_CXX_STDLIB` and `CLANG_UNWINDLIB`, which can
be set back to GCC's.

**The host clang has to be about as new as the LLVM being built**, because this
step compiles libc++'s own headers. Measured: Debian trixie's clang 19 fails on
`#pragma clang attribute` with `__visibility__`; Apple clang 21 builds these
sources cleanly. CI installs `clang-23` from apt.llvm.org for an exact match.

`LLVM_ENABLE_PER_TARGET_RUNTIME_DIR` is off. On, libc++ installs into
`lib/<triple>/`, which clang would find but the *loader* would not — it is not
on musl's default search path, so every program linked against libc++ would fail
to start. The device hosts one target, so the flat layout is both simpler and
correct.

### 5c. Build the Objective-C runtime

Objective-C and Objective-C++ are frontends `clang` already has. What it does
not have is a runtime to emit calls into, and that runtime is not an LLVM
component at all — LLVM ships the compiler and nothing else. It comes from
[GNUstep's libobjc2](https://github.com/gnustep/libobjc2), the modern
non-fragile-ABI runtime, with ARC.

Three things about it shape this step:

- **It can only be built by clang.** Its `CMakeLists.txt` refuses any other
  compiler outright, because the ABI it implements is one only clang emits. So
  this is the one step that needs a clang on the build host — `HOST_CLANG`,
  which is checked before it is used: it must exist and must actually emit
  aarch64 ELF, which is asserted by compiling a probe and reading the result
  back rather than assumed.
- **It carries its own blocks runtime**, so `-fblocks` needs nothing further.
- **It links against libgcc**, unlike everything the shipped clang will emit. A
  host clang looks for compiler-rt in *its own* resource directory rather than
  in the sysroot, so using the builtins from step 5b would mean overriding
  `-resource-dir` and dragging that clang's builtin headers along with it.
  `libgcc_s.so.1` is on the card regardless — the toolchain binaries need it —
  and both unwinders implement the same ABI, so this is a wart rather than a
  defect. It is written down here rather than hidden.

The ABI the on-device clang defaults to is `gnustep-2.2`, and it reaches the
driver through a **clang configuration file** staged at
`/usr/lib/clang-config/<triple>.cfg`: there is no `CLANG_DEFAULT_OBJC_RUNTIME`
to build it in. Clang is built with `CLANG_CONFIG_FILE_SYSTEM_DIR` set to a path
relative to its own binary, so the staged tree stays relocatable, and nobody has
to pass a flag to compile Objective-C on the device.

### 6. Stage the install tree

Three build trees install into one staging tree — the compiler from step 5, the
runtimes from 5b and the Objective-C runtime from 5c — which is then stripped
and reduced to what is actually useful on a device: no static archives, no test
binaries, no documentation. The clang configuration file that gives the driver
its Objective-C ABI is written here too.

Because the linkage is dynamic, `libstdc++.so.6` and `libgcc_s.so.1` are part
of the product. They ship even though user code now defaults to compiler-rt and
libc++: the `clang` binary was itself built by GCC and will not start without
them. They come from the cross-toolchain, they are not in the
sysroot, and nothing in `rootfs` provides them — so they travel inside this
repository's release asset rather than becoming something `rootfs` has to know
to install. `gmake runtime-libs` lists them.

`LLVM_INSTALL_TOOLCHAIN_ONLY` still installs 42 binaries, most of which cannot
do anything on this device: `clang-cl`, `lld-link`, `llvm-lib`, `llvm-dlltool`,
`llvm-rc`, `llvm-ml` and `llvm-pdbutil` are Windows tooling, `ld64.lld` is
Mach-O, `wasm-ld` is WebAssembly, the `*-arch` and offload wrappers are for
GPUs, and the `scan-build` family are Python scripts — SepiaOS has musl and
busybox, and no interpreter to run them. `libclang.so` is another 41 MiB of C
API that exists for editors rather than for compiling.

`SHIP_BINARIES` is therefore an **allowlist**, not a blocklist: a new LLVM
release adds binaries, and a blocklist would start shipping them without
anyone deciding to. `WITH_LIBCLANG=1` puts the C API back.

What is emphatically *not* pruned is `usr/lib/clang/<major>/include` — clang's
own builtin headers, 253 of them, without which it cannot compile anything.

`gmake stage-check` reads the result back and asserts that every staged binary
is aarch64, uses the musl loader, and has a complete shared-library closure —
every `NEEDED` entry either staged here or supplied by `rootfs`'s musl, which
is the only thing allowed to be missing. The closure is walked over the staged
**libraries** as well as the binaries, and that is deliberate: a library's
`NEEDED` entry is resolved just as eagerly as a binary's, so one that nothing
provides kills every program linked against it. Checking only `clang` and `lld`
once let a `libc++.so.1` that wanted a `libatomic.so.1` out of this repository
entirely, to be caught downstream in `rootfs`. It then checks that each language has
what it needs on the card: clang's builtin headers for C, libc++'s headers and
libraries for C++, the objc headers and `libobjc.so` for Objective-C, the
builtins archive for linking anything at all, and the config file that sets the
Objective-C ABI. That is a **layout** check — it says the pieces are where the
driver looks, not that a program built with them runs. Only the device, or an
emulator, can say that.

Size is a product constraint here rather than a build convenience. The SepiaOS
userland today is musl plus busybox — a few megabytes — and the image is
deliberately sized to its contents so that first boot can grow it to fill the
card. A clang install is larger than everything else on the card put together.

### 7. Publish

`gmake dist` tars the staged `usr/` tree, compresses it with `xz -9` and writes
its digest to `dist/SHA256SUMS` — the way the `boot` repository publishes its
card image. `rootfs` then consumes that release over the GitHub API and unpacks
it into the root filesystem.

**What ships is LLVM and nothing else.** `libstdc++.so.6` and `libgcc_s.so.1`
are in the asset because the linkage is dynamic, `clang` cannot start without
them and nothing else on the device provides them. musl is not, and `dist`
refuses to pack a tree that contains a `libc.so` or a loader: the device's libc
comes from `rootfs`, and a second copy on the card is how two libcs end up
disagreeing with each other.

`DIST_TAG` names the file after the release it came from — the workflow passes
the tag, so a local `gmake dist` produces
`sepiaos-llvm-23.1.0-aarch64-musl.tar.xz` and a release produces
`sepiaos-llvm-23.1.0-aarch64-musl-v1.0.0.tar.xz`.

Reaching across the filesystem into `../llvm/build/` is deliberately not how
this works: consuming a published release is what makes the sibling builds
independently reproducible, and it is what allows them to run in CI.

## Continuous integration

Two workflows, both of which only call the `make` targets documented above, so
any failure reproduces locally verbatim.

| | |
|---|---|
| [`ci.yml`](.github/workflows/ci.yml) | every commit on every branch, and every pull request against `main` |
| [`release.yml`](.github/workflows/release.yml) | manual, takes the version to release |

**CI runs the whole build** — toolchain, sources, sysroot, host tablegen,
cross-build, stage, `stage-check` and `dist` — on every commit. That is hours
of runner time per push rather than the seconds the sibling repositories take,
so a superseded run for the same branch is cancelled, and the job stops just
short of the six-hour ceiling a hosted runner imposes so the build logs are
still uploaded on the way out. It builds in `debian:trixie-slim` on Linux
because the toolchain vendor, and therefore the binaries, differ by build host.

**Releases are never automatic.** A manual dispatch takes the version; a gate
job validates it, resolves `main`'s head and refuses a commit with no green CI
run; `main` is branched to `rel-<version>` and the build runs *on that branch*,
so the released commit still exists once `main` moves on. If the build fails,
the branch is deleted again and the same version can be retried.

**Only the newest release is kept.** Publishing deletes every release that came
before it, and their tags with them — this repository ships one product, the
current toolchain, and each asset is tens of megabytes. Nothing is deleted
until there is a built asset to put in its place, and the commit each old
release was built from stays reachable through its `rel-<version>` branch,
which is never deleted.

## Status

**All seven steps are implemented and green in CI**, in 2 h 06 m on a hosted
runner. The build produces a 186 MiB staged tree — 9.4 MiB of binaries, 159 MiB
of libraries, 17 MiB of headers — which packs to a **41 MiB** release asset:

| | |
|---|---|
| `clang`, `lld`, 12 binutils equivalents | `usr/bin` |
| `libc++.so.1` 1.5 MB, `libc++abi.so.1` 475 KB, `libunwind.so.1` 83 KB | `usr/lib` |
| `libobjc.so.4.6` 256 KB | `usr/lib` |
| compiler-rt builtins | `usr/lib/clang/23/lib/linux` |
| 1689 libc++ headers, 22 objc headers | `usr/include` |

`gmake stage-check` passes every assertion, ending with *"C, C++, Objective-C
and Objective-C++ have their headers and runtimes"*.

**That is a layout proof, not a behavioural one.** Nothing has yet compiled a
program *with* the shipped toolchain — `stage-check` says the pieces are where
the driver looks, not that a program built with them runs. That needs a
Raspberry Pi or an emulator, and until then "the four languages work" is a
claim rather than a result.

## Repository layout

| | |
|---|---|
| `Makefile` | the entire build |
| `.github/workflows/` | `ci.yml` (build on every commit) and `release.yml` (manual publish) |
| `checksums/` | committed digests for the pinned upstream sources |
| `downloads/` | fetched upstream artifacts; survive `gmake clean` |
| `build/` | everything generated |
| `dist/` | release artifacts |

## Prerequisites

| Tool | Why |
|---|---|
| GNU Make ≥ 4.0 | build driver (`gmake` on macOS) |
| `curl` | fetches the toolchain and the sources |
| `tar`, `xz` | unpacks them |
| `cmake` ≥ 3.20, `ninja` | LLVM's build system |
| a host C/C++ compiler | step 4 builds the tablegen tools with it, not with the cross-compiler |
| a host `clang`, ≈ as new as `LLVM_VERSION` | steps 5b and 5c: libc++'s headers and libobjc2 can only be built by clang |

```sh
# macOS
brew install make cmake ninja xz

# Debian / Ubuntu
sudo apt install make cmake ninja-build gcc g++ python3 curl ca-certificates xz-utils
# plus a current clang from apt.llvm.org, then: gmake HOST_CLANG=clang-23 …
```

macOS needs nothing extra: Apple clang 21 compiles for
`aarch64-unknown-linux-musl` and builds libc++ 23.1.0 — both verified. The
distribution clang is the one to watch: **trixie's clang 19 is too old** and
fails inside libc++'s headers, so CI takes `clang-23` from apt.llvm.org. If
yours is too old, `brew install llvm` or apt.llvm.org, then set `HOST_CLANG`;
`gmake runtimes` compiles *and links* a probe for the target before it uses the
compiler, so a wrong one is reported in a line rather than 200 lines into a
CMake log. `HOST_CLANGXX` is derived from it (`clang-23` → `clang++-23`).

The host compiler is easy to overlook, because steps 1 to 3 use only the
downloaded cross-toolchain and pass without one; step 4 is the first thing that
needs it, and CMake reports it as `No CMAKE_C_COMPILER could be found`. macOS
always has Apple clang, so this only bites on a slim Linux image.

Neither sibling repository needs CMake or Ninja, so these are new to SepiaOS;
CI installs them too.

## Related repositories

- [boot](https://github.com/Sepia-OS/boot) — the FAT boot partition
- [rootfs](https://github.com/Sepia-OS/rootfs) — the root filesystem, and the consumer of this repository's releases
