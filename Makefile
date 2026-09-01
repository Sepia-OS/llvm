# SepiaOS - LLVM for the target
#
# Downloads the LLVM sources and cross-builds clang/lld to run *on* the Pi,
# linked against musl, for installation into the SepiaOS root filesystem.
#
#   make toolchain-check    prove the cross-compiler can build C++ for musl
#   make sources            download and verify the LLVM sources
#   make help               every target
#
# No root, no containers: everything is a download plus a cross-build, so the
# same recipes work on macOS and Linux.

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Make 3.81 (still /usr/bin/make on macOS) compares timestamps only to the
# second and silently reuses stale outputs after a fast edit.
ifeq ($(filter 4.% 5.%,$(MAKE_VERSION)),)
$(error GNU Make >= 4.0 required, found $(MAKE_VERSION). On macOS: brew install make, then run gmake)
endif

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

# --retry-all-errors is not belt-and-braces here, it is load-bearing.
# musl.libc.org is unreliable from a CI container: measured from
# debian:trixie-slim, four consecutive single-shot fetches all failed, two with
#
#   curl: (35) TLS connect error: error:0A000126:SSL routines::unexpected eof
#
# and two with connection timeouts. Plain --retry does not help, because curl
# only retries what it classes as transient - a TLS handshake failure is not on
# that list. With --retry-all-errors the same fetch succeeds first time.
CURL   := curl --fail --silent --show-error --location \
                --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

DL_DIR    := downloads
BUILD_DIR := build
DIST_DIR  := dist
CHECKSUMS := checksums

HOST_OS   := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

# Overriding a variable on the command line changes what gets built but touches
# no file, so Make cannot see it: `gmake MUSL_VERSION=1.2.5 sysroot` would
# report "Nothing to be done" and leave 1.2.6 in place. Each expensive tree
# therefore carries a signature of the settings that determine its contents,
# rewritten only when it actually changes so it works as an ordinary
# prerequisite. Same idiom as ../boot's CONFIG_SIG.
.PHONY: FORCE
FORCE:

# $(1) stamp path, $(2) signature
define config_stamp_rule
$(1): FORCE
	@mkdir -p $$(@D)
	@printf '%s\n' '$(2)' | cmp -s - $$@ || printf '%s\n' '$(2)' > $$@
endef

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Pinned upstream release. Newer: https://github.com/llvm/llvm-project/releases
LLVM_VERSION ?= 23.1.0

# What the on-device toolchain consists of. Kept deliberately short: this
# lands on an SD card next to a musl+busybox userland, so every project added
# here is paid for in card space forever.
LLVM_PROJECTS ?= clang;lld

# AArch64 alone. The device compiles for itself; it is not a build farm, and
# every extra backend is tens of MiB of card space.
LLVM_TARGETS ?= AArch64

# ---------------------------------------------------------------------------
# Cross-toolchain
#
# A musl-*targeting* toolchain, which is the one thing that matters here.
# On macOS that is the musl variant of the same messense release the rootfs
# repository already uses; rootfs deliberately takes the *gnu* variant,
# because it builds musl from source and a baked-in musl would make that step
# a no-op - but that choice does not survive contact with C++.
#
# Established by running it, not from documentation: the gnu toolchain cannot
# compile C++ against a musl sysroot at all. libstdc++ is coupled to glibc in
# its *headers*, so it fails before the linker is ever reached:
#
#   bits/os_defines.h:44:19: error: missing binary operator before token '('
#      44 | #if __GLIBC_PREREQ(2,15) && defined(_GNU_SOURCE)
#   bits/c++locale.h:62:11: error: '__locale_t' does not name a type
#
# -static-libstdc++ and -static do not help; the failure is in the headers.
# LLVM is C++, so the musl-targeting toolchain, whose libstdc++ was built
# against musl, is the one that can build it. `make toolchain-check` is that
# claim, checked.
# ---------------------------------------------------------------------------

# The triple the *product* reports and defaults to. Deliberately fixed rather
# than taken from whichever compiler built it: the two vendors below disagree
# (messense says aarch64-unknown-linux-musl, bootlin says
# aarch64-buildroot-linux-musl), and a clang whose default target depends on
# which machine cut the release would be a genuinely confusing artifact.
LLVM_TRIPLE := aarch64-unknown-linux-musl

# Two vendors, because no single one publishes a musl-targeting aarch64
# toolchain for both hosts - checked, not assumed:
#
#   messense publishes darwin-hosted builds only; there is no Linux-hosted
#   asset in its releases at all.
#
#   bootlin publishes Linux-hosted builds only, x86_64 host only.
#
# So macOS is the development host and Linux is the release host, matching the
# rootfs repository's arrangement and the same reasoning: the compiler differs
# by build host, so the binaries do too, and releases should be cut in one
# place. LLVM_TRIPLE above is what keeps the *product* identical either way.
ifeq ($(HOST_OS),Darwin)
  TC_VENDOR      := messense
  TC_VERSION_DEF := 15.2.0
  TC_PREFIX      := aarch64-unknown-linux-musl-
  ifeq ($(HOST_ARCH),arm64)
    TC_HOST := aarch64-darwin
  else ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64-darwin
  endif
  TC_ARCHIVE  = aarch64-unknown-linux-musl-$(TC_HOST).tar.gz
  TC_BASE    := https://github.com/messense/homebrew-macos-cross-toolchains/releases/download
  TC_URL      = $(TC_BASE)/v$(TC_VERSION)/$(TC_ARCHIVE)
  TC_SUMS     = $(TC_ARCHIVE).sha256
  TC_SUMS_URL = $(TC_URL).sha256
else ifeq ($(HOST_OS),Linux)
  # Buildroot's prebuilt toolchains. Linux-hosted, musl-targeting, and each
  # tarball has a published sha256 next to it - the same shape as messense,
  # so the fetch/verify/unpack recipe is shared.
  TC_VENDOR      := bootlin
  TC_VERSION_DEF := 2025.08-1
  # bootlin names its tools aarch64-linux-*, not after the full triple; the
  # compiler itself reports aarch64-buildroot-linux-musl.
  TC_PREFIX      := aarch64-linux-
  ifeq ($(HOST_ARCH),x86_64)
    TC_HOST := x86_64
  endif
  TC_ARCHIVE  = aarch64--musl--stable-$(TC_VERSION).tar.xz
  TC_BASE    := https://toolchains.bootlin.com/downloads/releases/toolchains/aarch64/tarballs
  TC_URL      = $(TC_BASE)/$(TC_ARCHIVE)
  TC_SUMS     = aarch64--musl--stable-$(TC_VERSION).sha256
  TC_SUMS_URL = $(TC_BASE)/$(TC_SUMS)
endif

TC_VERSION ?= $(TC_VERSION_DEF)

# Set this to a musl cross-toolchain you already have and nothing is
# downloaded - the escape hatch for a host neither vendor covers, such as a
# Linux/aarch64 machine (which would more sensibly build natively anyway).
CROSS_COMPILE ?=

DL_TC     := $(DL_DIR)/toolchain
TC_DIR     = $(DL_TC)/$(TC_VENDOR)-$(TC_VERSION)-$(TC_HOST)
TC_STAMP   = $(TC_DIR)/.extracted
CROSS      = $(or $(CROSS_COMPILE),$(abspath $(TC_DIR))/bin/$(TC_PREFIX))
TOOLCHAIN_DEP = $(if $(CROSS_COMPILE),,$(TC_STAMP))

TC_GOALS := toolchain toolchain-info toolchain-check llvm \
            sysroot sysroot-info sysroot-check runtime-libs
ifneq ($(filter $(TC_GOALS),$(MAKECMDGOALS)),)
  ifeq ($(CROSS_COMPILE),)
    ifeq ($(TC_HOST),)
      $(error No prebuilt musl-targeting aarch64 toolchain is published for $(HOST_OS)/$(HOST_ARCH) (macOS: messense, Linux/x86_64: bootlin). Set CROSS_COMPILE to one you have)
    endif
  endif
endif

# ---------------------------------------------------------------------------
# LLVM sources
#
# The release tarball, not a clone: it is the artifact upstream signs, it
# needs no git history, and it is a fraction of the monorepo's size.
#
# LLVM publishes a detached GPG signature but no sha256 sidecar, so - as the
# rootfs repository does for musl - the digest is recorded here on first fetch
# and checked on every fetch after that. Commit checksums/ to make the pin
# mean something to anyone else.
# ---------------------------------------------------------------------------

LLVM_TAG     := llvmorg-$(LLVM_VERSION)
LLVM_ARCHIVE := llvm-project-$(LLVM_VERSION).src.tar.xz
LLVM_URL     := https://github.com/llvm/llvm-project/releases/download/$(LLVM_TAG)/$(LLVM_ARCHIVE)
LLVM_SUMS     = $(CHECKSUMS)/llvm-$(LLVM_VERSION).sha256

DL_LLVM   := $(DL_DIR)/llvm
LLVM_SRC   = $(DL_LLVM)/llvm-project-$(LLVM_VERSION)
LLVM_STAMP = $(LLVM_SRC)/.unpacked

# ---------------------------------------------------------------------------
# Step 1 - the cross-toolchain
# ---------------------------------------------------------------------------

.PHONY: toolchain
toolchain: $(TOOLCHAIN_DEP) ## Fetch the musl-targeting aarch64 cross-compiler
	@$(call assert_cross_compiler)
	@echo "  READY    $(if $(CROSS_COMPILE),CROSS_COMPILE -> $(CROSS)g++,$(TC_VENDOR) $(TC_VERSION) -> $(TC_DIR))"

# Nothing under $(TC_DIR) is a prerequisite: release archives are immutable, so
# once a version is unpacked it is never unpacked again. Change TC_VERSION and
# the path changes with it.
$(TC_STAMP):
	@command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
	@mkdir -p $(DL_TC)
	@if [ ! -f $(DL_TC)/$(TC_ARCHIVE) ]; then \
	   echo "  FETCH    $(TC_ARCHIVE) (a few hundred MiB)"; \
	   $(CURL) -o $(DL_TC)/$(TC_ARCHIVE).part "$(TC_URL)"; \
	   mv -f $(DL_TC)/$(TC_ARCHIVE).part $(DL_TC)/$(TC_ARCHIVE); \
	 fi
	@if [ ! -f $(DL_TC)/$(TC_SUMS) ]; then \
	   $(CURL) -o $(DL_TC)/$(TC_SUMS).part "$(TC_SUMS_URL)"; \
	   mv -f $(DL_TC)/$(TC_SUMS).part $(DL_TC)/$(TC_SUMS); \
	 fi
	@echo "  VERIFY   $(TC_ARCHIVE)"
	@( cd $(DL_TC) && $(SHA256) --check --quiet $(TC_SUMS) ) || { \
	   echo "  FAIL     $(TC_ARCHIVE) does not match upstream's digest; delete $(DL_TC) and retry" >&2; \
	   exit 1; }
	@echo "  UNPACK   $(TC_ARCHIVE) -> $(TC_DIR)"
	@rm -rf $(TC_DIR)
	@mkdir -p $(TC_DIR)
	@tar -xf $(DL_TC)/$(TC_ARCHIVE) -C $(TC_DIR) --strip-components=1
	@touch $@
	@$(call assert_cross_compiler)

# A cross-compiler for the wrong host arch extracts happily and then fails to
# exec; one for the wrong target compiles happily and produces the wrong
# binaries. -dumpmachine catches both in one cheap call - and here it must say
# musl, because the whole point of this toolchain is that it is not the gnu one.
define assert_cross_compiler
	command -v $(CROSS)g++ >/dev/null 2>&1 || { \
	  echo "  FAIL     no $(CROSS)g++" >&2; exit 1; }; \
	m=$$($(CROSS)g++ -dumpmachine) || { \
	  echo "  FAIL     $(CROSS)g++ will not run on $(HOST_OS)/$(HOST_ARCH)" >&2; exit 1; }; \
	case "$$m" in \
	  aarch64-*linux-musl*) ;; \
	  aarch64-*linux*) echo "  FAIL     $(CROSS)g++ targets $$m - a gnu toolchain cannot build C++ against musl (see the Makefile header)" >&2; exit 1;; \
	  *) echo "  FAIL     $(CROSS)g++ targets $$m, not aarch64 linux musl" >&2; exit 1;; \
	esac
endef

.PHONY: toolchain-info
toolchain-info: $(TOOLCHAIN_DEP) ## Show the cross-compiler in use
	@echo "  host     $(HOST_OS) $(HOST_ARCH)"
	@echo "  source   $(if $(CROSS_COMPILE),CROSS_COMPILE override,$(TC_VENDOR) $(TC_VERSION))"
	@echo "  prefix   $(CROSS)"
	@echo "  target   $$($(CROSS)g++ -dumpmachine)"
	@$(CROSS)g++ --version | sed -n '1s/^/  g++      /p'
	@$(CROSS)ld --version | sed -n '1s/^/  ld       /p'
	@echo "  sysroot  $$($(CROSS)g++ -print-sysroot)"

# The gate the whole design rests on. LLVM is C++, so "the toolchain works"
# means the standard library, exceptions and the locale machinery all compile
# and link against musl - not merely that a C hello-world builds.
TC_CHECK_DIR := $(BUILD_DIR)/toolchain-check

.PHONY: toolchain-check
toolchain-check: $(TOOLCHAIN_DEP) ## Prove the cross-compiler builds C++ against musl
	@$(call assert_cross_compiler)
	@mkdir -p $(TC_CHECK_DIR)
	@printf '%s\n' \
	  '#include <string>' \
	  '#include <vector>' \
	  '#include <stdexcept>' \
	  '#include <cstdio>' \
	  'int main() {' \
	  '  std::vector<std::string> v{"sepia", "os"};' \
	  '  try { throw std::runtime_error(v[0] + v[1]); }' \
	  '  catch (const std::exception& e) { std::printf("%s\n", e.what()); }' \
	  '  return 0;' \
	  '}' > $(TC_CHECK_DIR)/t.cpp
	@$(CROSS)g++ -O2 -o $(TC_CHECK_DIR)/t.dyn $(TC_CHECK_DIR)/t.cpp \
	  || { echo "  FAIL     C++ does not compile for musl dynamically" >&2; exit 1; }
	@echo "  OK       dynamic  $$($(CROSS)readelf -d $(TC_CHECK_DIR)/t.dyn | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
	@$(CROSS)g++ -O2 -static -o $(TC_CHECK_DIR)/t.static $(TC_CHECK_DIR)/t.cpp \
	  || { echo "  FAIL     C++ does not link statically against musl" >&2; exit 1; }
	@echo "  OK       static   $$(wc -c < $(TC_CHECK_DIR)/t.static | tr -d ' ') bytes"
	@echo "  READY    $(TC_VENDOR) $(TC_VERSION) builds C++ against musl"

# ---------------------------------------------------------------------------
# Step 2 - the LLVM sources
# ---------------------------------------------------------------------------

.PHONY: sources
sources: $(LLVM_STAMP) ## Download, verify and unpack the LLVM sources
	@echo "  READY    llvm-project $(LLVM_VERSION) -> $(LLVM_SRC)"

$(LLVM_STAMP):
	@command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
	@mkdir -p $(DL_LLVM) $(CHECKSUMS)
	@if [ ! -f $(DL_LLVM)/$(LLVM_ARCHIVE) ]; then \
	   echo "  FETCH    $(LLVM_ARCHIVE)"; \
	   $(CURL) -o $(DL_LLVM)/$(LLVM_ARCHIVE).part "$(LLVM_URL)"; \
	   mv -f $(DL_LLVM)/$(LLVM_ARCHIVE).part $(DL_LLVM)/$(LLVM_ARCHIVE); \
	 fi
	@if [ -f $(LLVM_SUMS) ]; then \
	   echo "  VERIFY   $(LLVM_ARCHIVE)"; \
	   ( cd $(DL_LLVM) && $(SHA256) --check --quiet $(abspath $(LLVM_SUMS)) ) || { \
	     echo "  FAIL     $(LLVM_ARCHIVE) does not match $(LLVM_SUMS)" >&2; exit 1; }; \
	 else \
	   ( cd $(DL_LLVM) && $(SHA256) $(LLVM_ARCHIVE) ) > $(LLVM_SUMS); \
	   echo "  RECORD   $(LLVM_SUMS) - first fetch of this version, commit it"; \
	 fi
	@echo "  UNPACK   $(LLVM_ARCHIVE) -> $(LLVM_SRC)"
	@rm -rf $(LLVM_SRC)
	@mkdir -p $(LLVM_SRC)
	@tar -xf $(DL_LLVM)/$(LLVM_ARCHIVE) -C $(LLVM_SRC) --strip-components=1
	@touch $@

.PHONY: sources-info
sources-info: $(LLVM_STAMP) ## Show the LLVM version and what will be built
	@echo "  version  $(LLVM_VERSION) ($(LLVM_TAG))"
	@echo "  source   $(LLVM_SRC)"
	@echo "  size     $$(du -sh $(LLVM_SRC) | cut -f1)"
	@echo "  projects $(LLVM_PROJECTS)"
	@echo "  targets  $(LLVM_TARGETS)"
	@$(call assert_source_version)

# The unpacked tree has to be the version that was pinned. A mismatch means the
# tarball, the digest or LLVM_VERSION disagree, and every step after this one
# would build something other than what the manifest claims - so it is an error
# rather than a note, even in an -info target.
define assert_source_version
	f=$(LLVM_SRC)/cmake/Modules/LLVMVersion.cmake; \
	field() { sed -n "s/^ *set(LLVM_VERSION_$$1 \([0-9][0-9]*\)).*/\1/p" "$$f" | head -1; }; \
	v="$$(field MAJOR).$$(field MINOR).$$(field PATCH)"; \
	[ "$$v" = "$(LLVM_VERSION)" ] || { \
	  echo "  FAIL     the tree declares $$v but LLVM_VERSION is $(LLVM_VERSION)" >&2; exit 1; }; \
	echo "  declared $$v (matches the pin)"
endef

.PHONY: verify-downloads
verify-downloads: ## Check the LLVM tarball against the recorded digest
	@test -f $(LLVM_SUMS) || { echo "No $(LLVM_SUMS); run 'make sources' first." >&2; exit 1; }
	@( cd $(DL_LLVM) && $(SHA256) --check --quiet $(abspath $(LLVM_SUMS)) )
	@echo "  OK       $(LLVM_SUMS)"

# ---------------------------------------------------------------------------
# Step 3 - the target sysroot
#
# musl is built here rather than read out of ../rootfs/build/sysroot: sibling
# repositories consume each other's *published releases*, never each other's
# build trees, which is what keeps each of them buildable alone and in CI.
#
# The version is pinned rather than resolved to "latest", and it is pinned to
# whatever rootfs ships: the clang built here is dynamically linked, so it has
# to run against the musl that is actually on the device.
#
#   CAUTION: rootfs resolves musl as "latest" by default, so it can move out
#   from under this pin. checksums/musl-*.sha256 is copied from rootfs so that
#   both builds compile byte-identical source; when rootfs moves, move this to
#   match and rebuild. `make sysroot-info` prints what this tree actually has.
#
# The cross-toolchain has musl 1.2.5 baked into its own sysroot, which is not
# what ships, so --sysroot points at this tree instead. C++ headers and
# libstdc++ are found through the compiler's own paths, *outside* any sysroot,
# so redirecting the sysroot replaces the libc without disturbing C++ -
# checked by sysroot-check, not assumed.
# ---------------------------------------------------------------------------

MUSL_VERSION ?= 1.2.6
MUSL_BASE    := https://musl.libc.org/releases
MUSL_ARCHIVE  = musl-$(MUSL_VERSION).tar.gz
MUSL_URL      = $(MUSL_BASE)/$(MUSL_ARCHIVE)
MUSL_SUMS     = $(CHECKSUMS)/musl-$(MUSL_VERSION).sha256

DL_MUSL    := $(DL_DIR)/musl
MUSL_DIR   := $(BUILD_DIR)/musl
MUSL_SRC    = $(MUSL_DIR)/musl-$(MUSL_VERSION)
MUSL_STAMP  = $(MUSL_DIR)/.installed
SYSROOT    := $(BUILD_DIR)/sysroot

JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

MUSL_CFG := $(MUSL_DIR)/.config
MUSL_SIG  = $(MUSL_VERSION)|$(TC_VENDOR)|$(TC_VERSION)|$(CROSS_COMPILE)
$(eval $(call config_stamp_rule,$(MUSL_CFG),$(MUSL_SIG)))

.PHONY: sysroot
sysroot: $(MUSL_STAMP) ## Build the musl sysroot the target binaries link against
	@echo "  READY    musl $(MUSL_VERSION) -> $(SYSROOT)"

# configure and make are noisy and only interesting when they fail, so the
# output goes to a log and the tail of it is what surfaces on an error.
$(MUSL_STAMP): $(TOOLCHAIN_DEP) $(MUSL_CFG) Makefile
	@$(call assert_cross_compiler)
	@mkdir -p $(DL_MUSL) $(MUSL_DIR) $(CHECKSUMS)
	@if [ ! -f $(DL_MUSL)/$(MUSL_ARCHIVE) ]; then \
	   echo "  FETCH    $(MUSL_ARCHIVE)"; \
	   $(CURL) -o $(DL_MUSL)/$(MUSL_ARCHIVE).part "$(MUSL_URL)"; \
	   mv -f $(DL_MUSL)/$(MUSL_ARCHIVE).part $(DL_MUSL)/$(MUSL_ARCHIVE); \
	 fi
	@if [ -f $(MUSL_SUMS) ]; then \
	   echo "  VERIFY   $(MUSL_ARCHIVE)"; \
	   ( cd $(DL_MUSL) && $(SHA256) --check --quiet $(abspath $(MUSL_SUMS)) ) || { \
	     echo "  FAIL     $(MUSL_ARCHIVE) does not match $(MUSL_SUMS)" >&2; exit 1; }; \
	 else \
	   ( cd $(DL_MUSL) && $(SHA256) $(MUSL_ARCHIVE) ) > $(MUSL_SUMS); \
	   echo "  RECORD   $(MUSL_SUMS) - first fetch of this version, commit it"; \
	 fi
	@echo "  UNPACK   $(MUSL_ARCHIVE)"
	@rm -rf $(MUSL_SRC)
	@tar -xf $(DL_MUSL)/$(MUSL_ARCHIVE) -C $(MUSL_DIR)
	@echo "  CONFIG   musl $(MUSL_VERSION) (static + shared)"
	@( cd $(MUSL_SRC) && ./configure --prefix=/usr --syslibdir=/lib \
	       --enable-static --enable-shared --disable-wrapper \
	       CROSS_COMPILE=$(CROSS) ) > $(MUSL_SRC)/configure.log 2>&1 || { \
	   tail -20 $(MUSL_SRC)/configure.log >&2; \
	   echo "  FAIL     configure (full log: $(MUSL_SRC)/configure.log)" >&2; exit 1; }
	@echo "  BUILD    musl $(MUSL_VERSION) (-j$(JOBS))"
	@$(MAKE) --no-print-directory -C $(MUSL_SRC) -j$(JOBS) > $(MUSL_SRC)/build.log 2>&1 || { \
	   tail -30 $(MUSL_SRC)/build.log >&2; \
	   echo "  FAIL     build (full log: $(MUSL_SRC)/build.log)" >&2; exit 1; }
	@echo "  INSTALL  -> $(SYSROOT)"
	@rm -rf $(SYSROOT)/usr/include $(SYSROOT)/usr/lib $(SYSROOT)/lib/ld-musl-*
	@mkdir -p $(SYSROOT)
	@$(MAKE) --no-print-directory -C $(MUSL_SRC) install DESTDIR=$(abspath $(SYSROOT)) \
	   >> $(MUSL_SRC)/build.log 2>&1 || { \
	   tail -30 $(MUSL_SRC)/build.log >&2; \
	   echo "  FAIL     install (full log: $(MUSL_SRC)/build.log)" >&2; exit 1; }
	@$(call install_uapi_headers)
	@touch $@

# musl installs libc headers and nothing else, which is not a usable sysroot:
# anything that talks to the kernel needs the Linux UAPI headers too. They come
# from the cross-toolchain's own sysroot - the same toolchain that supplies
# libgcc - rather than being downloaded, so this costs nothing and cannot drift
# from the compiler. Same approach as ../rootfs.
define install_uapi_headers
	set -e; \
	k=$$($(CROSS)gcc -print-sysroot)/usr/include; \
	[ -d "$$k" ] || { echo "  FAIL     $(CROSS)gcc has no sysroot to take UAPI headers from" >&2; exit 1; }; \
	i=$(abspath $(SYSROOT))/usr/include; mkdir -p "$$i"; \
	for d in linux asm asm-generic mtd rdma sound video drm misc scsi xen; do \
	  if [ -d "$$k/$$d" ]; then rm -rf "$$i/$$d"; cp -R "$$k/$$d" "$$i/$$d"; fi; \
	done; \
	[ -f $(abspath $(SYSROOT))/usr/include/linux/kd.h ] \
	  || { echo "  FAIL     no Linux UAPI headers landed in $(SYSROOT)" >&2; exit 1; }
endef

# musl stamps its version into libc.so as a bare "1.2.6" line. Read in two
# steps rather than one pipeline: under `set -o pipefail`, a `grep -m1` exits
# early, SIGPIPEs strings, and fails the whole pipeline *after* printing the
# answer - so a trailing `|| echo unknown` fires as well and both lines appear.
# sed -n '1p' consumes its input instead of closing the pipe.
# Two portability traps, both hit for real:
#
#   `strings` lives in binutils, which a slim CI image does not install -
#   debian:trixie-slim has none, and the probe silently returned nothing.
#
#   `tr -c '[:print:]'` was the obvious replacement and is worse: BSD tr cannot
#   read NUL bytes, so on macOS it yields nothing at all.
#
# grep -a is in both BSD and GNU grep and reads binary happily. The pattern is
# anchored on musl's 1.x series deliberately: a looser one matches half the
# version strings in the file. If musl ever goes 2.x this reports "unknown",
# which is a warning rather than a false mismatch.
define musl_version_of
$(shell LC_ALL=C grep -a -o -E '1\.[0-9]+\.[0-9]+' $(1) 2>/dev/null | sed -n '1p')
endef

.PHONY: sysroot-info
sysroot-info: $(MUSL_STAMP) ## Show the sysroot's musl version and layout
	@echo "  sysroot  $(SYSROOT)"
	@echo "  pinned   $(MUSL_VERSION)"
	@v='$(call musl_version_of,$(SYSROOT)/usr/lib/libc.so)'; \
	 if [ -z "$$v" ]; then \
	   echo "  built    unknown - could not read a version out of libc.so"; \
	 elif [ "$$v" != "$(MUSL_VERSION)" ]; then \
	   echo "  FAIL     the sysroot holds $$v, not the pinned $(MUSL_VERSION)" >&2; exit 1; \
	 else \
	   echo "  built    $$v"; \
	 fi
	@ls -l $(SYSROOT)/lib/ld-musl-aarch64.so.1 | sed 's/^/  loader   /'
	@t='$(call musl_version_of,$(shell $(CROSS)gcc -print-sysroot)/usr/lib/libc.so)'; \
	 echo "  tc musl  $${t:-unknown} (baked into the toolchain, deliberately not used)"

# The claim this repository rests on: C++ compiles and links against *this*
# sysroot, dynamically, and comes out pointing at the musl loader the device
# actually has. Dynamic is the shipped linkage, so dynamic is what is checked.
.PHONY: sysroot-check
sysroot-check: $(MUSL_STAMP) ## Prove C++ links dynamically against this sysroot
	@mkdir -p $(TC_CHECK_DIR)
	@printf '%s\n' \
	  '#include <string>' '#include <vector>' '#include <stdexcept>' '#include <cstdio>' \
	  'int main() {' \
	  '  std::vector<std::string> v{"sepia", "os"};' \
	  '  try { throw std::runtime_error(v[0] + v[1]); }' \
	  '  catch (const std::exception& e) { std::printf("%s\n", e.what()); }' \
	  '  return 0;' '}' > $(TC_CHECK_DIR)/s.cpp
	@$(CROSS)g++ --sysroot=$(abspath $(SYSROOT)) -O2 -o $(TC_CHECK_DIR)/s.dyn $(TC_CHECK_DIR)/s.cpp \
	  || { echo "  FAIL     C++ does not link dynamically against $(SYSROOT)" >&2; exit 1; }
	@$(CROSS)readelf -l $(TC_CHECK_DIR)/s.dyn | grep -q 'ld-musl-aarch64.so.1' \
	  || { echo "  FAIL     the test binary does not use the musl loader" >&2; exit 1; }
	@$(CROSS)readelf -h $(TC_CHECK_DIR)/s.dyn | grep -q AArch64 \
	  || { echo "  FAIL     the test binary is not aarch64" >&2; exit 1; }
	@echo "  OK       needs $$($(CROSS)readelf -d $(TC_CHECK_DIR)/s.dyn | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
	@echo "  READY    C++ links dynamically against musl $(MUSL_VERSION)"

# Dynamic linking is the shipped choice, so libstdc++ and libgcc_s are part of
# the product: they come from the cross-toolchain, they are not in the sysroot,
# and nothing in ../rootfs provides them. They therefore travel in this
# repository's release asset - step 6 - rather than becoming something rootfs
# has to know to install.
CXX_RUNTIME_LIBS := libstdc++.so.6 libgcc_s.so.1

.PHONY: runtime-libs
runtime-libs: $(TOOLCHAIN_DEP) ## Show the C++ runtime libraries that must ship
	@for l in $(CXX_RUNTIME_LIBS); do \
	   p=$$($(CROSS)gcc -print-file-name=$$l); \
	   case "$$p" in /*) printf '  %-16s %s (%s bytes)\n' "$$l" "$$p" "$$(wc -c < "$$p" | tr -d ' ')";; \
	                 *) echo "  FAIL     $$l not found in the toolchain" >&2; exit 1;; esac; \
	 done

# ---------------------------------------------------------------------------
# Step 4 - the native tablegen tools
#
# LLVM generates a great deal of its own source with llvm-tblgen and
# clang-tblgen, which run on the *build* host during the build. A cross-build
# therefore cannot produce them for itself: they have to exist as host binaries
# before the target tree is configured, and be handed to it explicitly.
#
# This is a second, throwaway build tree that exists only to produce two
# executables, so it is configured as small as it can be: no tests, no
# examples, no benchmarks, and none of the optional host libraries, which keeps
# the dependency surface down to a C++ compiler, cmake and ninja.
#
# The compiler here is the *host's* - Apple clang on macOS - and deliberately
# not the cross-compiler: these binaries have to run on the machine doing the
# build.
# ---------------------------------------------------------------------------

HOST_BUILD   := $(BUILD_DIR)/host
HOST_LOG      = $(HOST_BUILD)/build.log
LLVM_TBLGEN   = $(abspath $(HOST_BUILD))/bin/llvm-tblgen
CLANG_TBLGEN  = $(abspath $(HOST_BUILD))/bin/clang-tblgen
TBLGEN_STAMP  = $(HOST_BUILD)/.built

# llvm-min-tblgen is easy to miss: it is a separate binary from llvm-tblgen,
# LLVM uses it to generate its earliest headers, and if it is absent from
# LLVM_NATIVE_TOOL_DIR the cross-build quietly builds it *for the target* and
# then cannot execute it. Checked against build.ninja rather than assumed.
HOST_TBLGENS := llvm-tblgen llvm-min-tblgen clang-tblgen

HOST_CFG := $(HOST_BUILD)/.config
HOST_SIG  = $(LLVM_VERSION)|$(LLVM_TARGETS)|$(HOST_OS)|$(HOST_ARCH)
$(eval $(call config_stamp_rule,$(HOST_CFG),$(HOST_SIG)))

# Nothing about the target belongs in this configuration; it is a host build
# that happens to live in the same source tree.
HOST_CMAKE_FLAGS := \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_PROJECTS=clang \
  -DLLVM_TARGETS_TO_BUILD=$(LLVM_TARGETS) \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF

define require_build_tools
	for t in cmake ninja; do \
	  command -v $$t >/dev/null 2>&1 || { \
	    echo "  FAIL     $$t is required (brew install cmake ninja)" >&2; exit 1; }; \
	done
endef

.PHONY: tablegen
tablegen: $(TBLGEN_STAMP) ## Build llvm-tblgen and clang-tblgen for the build host
	@echo "  READY    host tablegen -> $(HOST_BUILD)/bin"

$(TBLGEN_STAMP): $(LLVM_STAMP) $(HOST_CFG) Makefile
	@$(call require_build_tools)
	@mkdir -p $(HOST_BUILD)
	@echo "  CONFIG   host tablegen (log: $(HOST_LOG))"
	@$(SCRUB_ENV) cmake -G Ninja -S $(LLVM_SRC)/llvm -B $(HOST_BUILD) $(HOST_CMAKE_FLAGS) \
	   > $(HOST_LOG) 2>&1 || { \
	   tail -30 $(HOST_LOG) >&2; \
	   echo "  FAIL     configure (full log: $(HOST_LOG))" >&2; exit 1; }
	@echo "  BUILD    $(HOST_TBLGENS) (-j$(JOBS)); this takes a while"
	@$(SCRUB_ENV) cmake --build $(HOST_BUILD) --parallel $(JOBS) \
	       --target $(HOST_TBLGENS) >> $(HOST_LOG) 2>&1 || { \
	   tail -40 $(HOST_LOG) >&2; \
	   echo "  FAIL     build (full log: $(HOST_LOG))" >&2; exit 1; }
	@$(call assert_tablegen)
	@touch $@

# A tablegen built for the wrong machine is the failure this step exists to
# prevent, and it is invisible until the target build tries to run it. Both
# binaries are therefore actually executed here.
define assert_tablegen
	set -e; \
	for t in $(HOST_TBLGENS); do \
	  p=$(abspath $(HOST_BUILD))/bin/$$t; \
	  [ -x "$$p" ] || { echo "  FAIL     $$t was not built" >&2; exit 1; }; \
	  "$$p" --version >/dev/null 2>&1 || { \
	    echo "  FAIL     $$t does not run on this host" >&2; exit 1; }; \
	done
endef

.PHONY: tablegen-info
tablegen-info: $(TBLGEN_STAMP) ## Show the host tablegen binaries
	@echo "  host     $(HOST_OS) $(HOST_ARCH)"
	@echo "  tree     $(HOST_BUILD)"
	@for t in $(HOST_TBLGENS); do \
	   p=$(abspath $(HOST_BUILD))/bin/$$t; \
	   printf '  %-16s %s\n' "$$t" \
	     "$$($$p --version | sed -n 's/.*LLVM version \([0-9.]*\).*/LLVM \1/p' | sed -n '1p')"; \
	 done

# ---------------------------------------------------------------------------
# Step 5 - cross-build clang and lld
#
# The target tree. CMAKE_SYSROOT points at step 3's musl rather than at the
# toolchain's own, because that is the libc the device actually runs.
#
# LLVM_NATIVE_TOOL_DIR hands the whole host bin/ from step 4 to the target
# build, which is how a modern LLVM is told "any tool you need to *run* during
# this build, take from here". Naming only LLVM_TABLEGEN and CLANG_TABLEGEN
# covers the two obvious ones and leaves any other native helper to be built
# for the target and then fail to exec.
#
# Two size decisions, both of which matter because this lands on an SD card:
#
#   LLVM_BUILD_LLVM_DYLIB + LLVM_LINK_LLVM_DYLIB put LLVM in one shared
#   library that every tool links against, instead of statically linking a
#   copy into each. CLANG_LINK_CLANG_DYLIB does the same for clang.
#
#   LLVM_INSTALL_TOOLCHAIN_ONLY drops the development-only material - the
#   internal headers, the static archives, the utilities that exist to build
#   LLVM rather than to use it.
#
# The linker and runtime defaults are left at libgcc and libstdc++ on purpose:
# those are exactly the runtime libraries this build already ships (see
# runtime-libs), so the on-device clang defaults to what is on the device.
# ---------------------------------------------------------------------------

TARGET_BUILD := $(BUILD_DIR)/target
TARGET_LOG    = $(TARGET_BUILD)/build.log
TARGET_STAMP  = $(TARGET_BUILD)/.built

# libstdc++.so.6 lives in the toolchain, not in the sysroot. Most of LLVM is
# C++ and links with the g++ driver, which knows where its own C++ library is -
# but a handful of targets are built from .c sources and link with the *gcc*
# driver, which does not. Linking one of those against libLLVM.so then fails to
# resolve libLLVM's libstdc++ dependency, several thousand targets into the
# build:
#
#   lib/libLLVM.so.23.1: undefined reference to `std::ostream::tellp()@GLIBCXX_3.4'
#
# libLLVM.so itself is fine and does record NEEDED libstdc++.so.6; it is the
# executable link that cannot find the library to resolve against. Handing the
# directory to every link settles it once instead of per-target. Computed
# lazily - the toolchain does not exist when the Makefile is first read.
TC_CXX_LIBDIR = $(abspath $(dir $(shell $(CROSS)gcc -print-file-name=libstdc++.so.6)))
CROSS_LDFLAGS = -L$(TC_CXX_LIBDIR) -Wl,-rpath-link,$(TC_CXX_LIBDIR)

# Homebrew sets CPPFLAGS and LDFLAGS in the developer's shell on macOS, and
# CMake reads them straight into CMAKE_*_FLAGS, where they reach *cross*-compile
# command lines: -I/opt/homebrew/opt/include and -L/opt/homebrew/opt/lib were
# both observed in a target link. A host header or library found through those
# would end up in a target binary with nothing to say it had happened, so the
# environment is scrubbed for every cmake invocation rather than trusted.
SCRUB_ENV := env -u CPPFLAGS -u LDFLAGS -u CFLAGS -u CXXFLAGS \
                 -u LIBRARY_PATH -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH

TARGET_CFG := $(TARGET_BUILD)/.config
TARGET_SIG  = $(LLVM_VERSION)|$(LLVM_PROJECTS)|$(LLVM_TARGETS)|$(LLVM_TRIPLE)|$(TC_VENDOR)|$(TC_VERSION)|$(MUSL_VERSION)|$(CROSS_COMPILE)
$(eval $(call config_stamp_rule,$(TARGET_CFG),$(TARGET_SIG)))

TARGET_CMAKE_FLAGS = \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_SYSROOT=$(abspath $(SYSROOT)) \
  -DCMAKE_C_COMPILER=$(CROSS)gcc \
  -DCMAKE_CXX_COMPILER=$(CROSS)g++ \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_INSTALL_PREFIX=/usr \
  "-DCMAKE_EXE_LINKER_FLAGS=$(CROSS_LDFLAGS)" \
  "-DCMAKE_SHARED_LINKER_FLAGS=$(CROSS_LDFLAGS)" \
  "-DCMAKE_MODULE_LINKER_FLAGS=$(CROSS_LDFLAGS)" \
  -DLLVM_NATIVE_TOOL_DIR=$(abspath $(HOST_BUILD))/bin \
  -DLLVM_TABLEGEN=$(LLVM_TBLGEN) \
  -DCLANG_TABLEGEN=$(CLANG_TBLGEN) \
  -DLLVM_HOST_TRIPLE=$(LLVM_TRIPLE) \
  -DLLVM_DEFAULT_TARGET_TRIPLE=$(LLVM_TRIPLE) \
  -DLLVM_TARGETS_TO_BUILD=$(LLVM_TARGETS) \
  -DLLVM_ENABLE_PROJECTS="$(LLVM_PROJECTS)" \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DCLANG_LINK_CLANG_DYLIB=ON \
  -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
  -DLLVM_ENABLE_ASSERTIONS=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_ENABLE_LIBXML2=OFF \
  -DLLVM_ENABLE_TERMINFO=OFF \
  -DLLVM_ENABLE_LIBEDIT=OFF

.PHONY: llvm
llvm: $(TARGET_STAMP) ## Cross-build clang and lld for the target
	@echo "  READY    llvm $(LLVM_VERSION) for $(LLVM_TRIPLE) -> $(TARGET_BUILD)/bin"

$(TARGET_STAMP): $(TBLGEN_STAMP) $(MUSL_STAMP) $(TARGET_CFG) Makefile
	@$(call require_build_tools)
	@$(call assert_cross_compiler)
	@mkdir -p $(TARGET_BUILD)
	@echo "  CONFIG   $(LLVM_TRIPLE) (log: $(TARGET_LOG))"
	@$(SCRUB_ENV) cmake -G Ninja -S $(LLVM_SRC)/llvm -B $(TARGET_BUILD) $(TARGET_CMAKE_FLAGS) \
	   > $(TARGET_LOG) 2>&1 || { \
	   tail -40 $(TARGET_LOG) >&2; \
	   echo "  FAIL     configure (full log: $(TARGET_LOG))" >&2; exit 1; }
	@echo "  BUILD    $(LLVM_PROJECTS) (-j$(JOBS)); this is the long one"
	@$(SCRUB_ENV) cmake --build $(TARGET_BUILD) --parallel $(JOBS) >> $(TARGET_LOG) 2>&1 || { \
	   tail -40 $(TARGET_LOG) >&2; \
	   echo "  FAIL     build (full log: $(TARGET_LOG))" >&2; exit 1; }
	@$(call assert_target_binaries)
	@touch $@

# The whole point of the exercise is binaries that run on the Pi, and nothing
# in a cross-build notices if they came out for the wrong machine - the build
# succeeds either way. So the products are read back: aarch64, and pointing at
# the musl loader the device has.
define assert_target_binaries
	set -e; \
	for b in clang lld; do \
	  p=$(TARGET_BUILD)/bin/$$b; \
	  [ -x "$$p" ] || { echo "  FAIL     $$b was not built" >&2; exit 1; }; \
	  $(CROSS)readelf -h "$$p" | grep -q AArch64 \
	    || { echo "  FAIL     $$b is not an aarch64 binary" >&2; exit 1; }; \
	  $(CROSS)readelf -l "$$p" | grep -q 'ld-musl-aarch64.so.1' \
	    || { echo "  FAIL     $$b does not use the musl loader" >&2; exit 1; }; \
	done
endef

.PHONY: llvm-info
llvm-info: $(TARGET_STAMP) ## Show the cross-built binaries and what they need
	@echo "  version  $(LLVM_VERSION)"
	@echo "  triple   $(LLVM_TRIPLE)"
	@echo "  tree     $(TARGET_BUILD)"
	@for b in clang lld; do \
	   p=$(TARGET_BUILD)/bin/$$b; \
	   printf '  %-8s %s bytes\n' "$$b" "$$(wc -c < $$p | tr -d ' ')"; \
	 done
	@echo "  needs    $$($(CROSS)readelf -d $(TARGET_BUILD)/bin/clang \
	   | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | tr '\n' ' ')"
	@du -sh $(TARGET_BUILD)/bin $(TARGET_BUILD)/lib 2>/dev/null | sed 's/^/  /' || true

# ---------------------------------------------------------------------------
# Step 6 - stage the install tree
#
# `cmake --install` under DESTDIR, so the tree is laid out exactly as it will
# sit on the device (prefix /usr) without anything being written outside
# build/. LLVM_INSTALL_TOOLCHAIN_ONLY already keeps the development-only
# material out; what remains is stripping, and adding the two C++ runtime
# libraries that the toolchain owns and the sysroot does not.
#
# libc.so is deliberately *not* staged: musl is the device's, from rootfs, and
# shipping a second copy is how two musls end up on one card.
# ---------------------------------------------------------------------------

STAGE_DIR   := $(BUILD_DIR)/stage
STAGE_LOG    = $(BUILD_DIR)/stage.log
STAGE_STAMP  = $(STAGE_DIR)/.staged

LLVM_MAJOR := $(firstword $(subst ., ,$(LLVM_VERSION)))

# What actually ships in usr/bin, as an allowlist rather than a blocklist: a
# new LLVM release adds binaries, and a blocklist would start shipping them
# without anyone deciding to.
#
# LLVM_INSTALL_TOOLCHAIN_ONLY still installs 42 binaries, and most of them
# cannot do anything useful on this device: clang-cl, lld-link, llvm-lib,
# llvm-dlltool, llvm-rc, llvm-ml and llvm-pdbutil are Windows tooling, ld64.lld
# is Mach-O, wasm-ld is WebAssembly, amdgpu-arch / nvptx-arch / offload-arch /
# clang-nvlink-wrapper / clang-sycl-linker are GPU offload, and the scan-build
# family are Python scripts - SepiaOS's userland is musl and busybox, with no
# interpreter for them to run under.
SHIP_BINARIES ?= \
  clang clang++ clang-cpp clang-$(LLVM_MAJOR) \
  lld ld.lld \
  llvm-ar llvm-ranlib llvm-nm llvm-objcopy llvm-strip \
  llvm-objdump llvm-readobj llvm-size llvm-strings llvm-cxxfilt \
  llvm-symbolizer clang-format

# libclang.so is the C API, which exists for editors and external tooling
# rather than for compiling on the device - and it is 41 MiB of the install.
WITH_LIBCLANG ?= 0

.PHONY: stage
stage: $(STAGE_STAMP) ## Install, strip and stage the toolchain for the device
	@echo "  READY    staged $$(du -sh $(STAGE_DIR) | cut -f1) -> $(STAGE_DIR)"

STAGE_CFG := $(BUILD_DIR)/.stage-config
STAGE_SIG  = $(LLVM_VERSION)|$(SHIP_BINARIES)|$(WITH_LIBCLANG)|$(CXX_RUNTIME_LIBS)
$(eval $(call config_stamp_rule,$(STAGE_CFG),$(STAGE_SIG)))

$(STAGE_STAMP): $(TARGET_STAMP) $(STAGE_CFG) Makefile
	@$(call require_build_tools)
	@rm -rf $(STAGE_DIR)
	@mkdir -p $(STAGE_DIR)/usr/lib
	@echo "  INSTALL  -> $(STAGE_DIR) (log: $(STAGE_LOG))"
	@DESTDIR=$(abspath $(STAGE_DIR)) $(SCRUB_ENV) cmake --install $(TARGET_BUILD) \
	   > $(STAGE_LOG) 2>&1 || { \
	   tail -30 $(STAGE_LOG) >&2; \
	   echo "  FAIL     install (full log: $(STAGE_LOG))" >&2; exit 1; }
	@echo "  RUNTIME  $(CXX_RUNTIME_LIBS)"
	@for l in $(CXX_RUNTIME_LIBS); do \
	   p=$$($(CROSS)gcc -print-file-name=$$l); \
	   case "$$p" in /*) ;; *) echo "  FAIL     $$l not found in the toolchain" >&2; exit 1;; esac; \
	   cp -L "$$p" $(STAGE_DIR)/usr/lib/$$l; \
	 done
	@$(call prune_stage)
	@$(call strip_stage)
	@touch $@

# Pruned before stripping, so nothing is spent stripping what is about to be
# deleted. usr/lib/clang/ is deliberately untouched - those are clang's own
# builtin headers, without which it cannot compile anything.
define prune_stage
	set -e; kept=0; dropped=0; \
	for f in $(STAGE_DIR)/usr/bin/*; do \
	  if [ ! -e "$$f" ] && [ ! -L "$$f" ]; then continue; fi; \
	  b=$$(basename "$$f"); \
	  case " $(SHIP_BINARIES) " in \
	    *" $$b "*) kept=$$((kept+1));; \
	    *) rm -f "$$f"; dropped=$$((dropped+1));; \
	  esac; \
	done; \
	if [ "$(WITH_LIBCLANG)" != "1" ]; then rm -f $(STAGE_DIR)/usr/lib/libclang.so*; fi; \
	rm -rf $(STAGE_DIR)/usr/lib/libscanbuild $(STAGE_DIR)/usr/lib/libear \
	       $(STAGE_DIR)/usr/share/scan-build $(STAGE_DIR)/usr/share/scan-view; \
	echo "  PRUNE    kept $$kept binaries, dropped $$dropped"
endef

# strip refuses on anything that is not an object file, and the tree holds
# scripts, headers and symlinks as well. The ELF magic is checked per file
# rather than letting strip fail and swallowing the error, so a genuine strip
# failure still surfaces.
define strip_stage
	set -e; n=0; \
	while IFS= read -r f; do \
	  if [ -L "$$f" ] || [ ! -f "$$f" ]; then continue; fi; \
	  if [ "$$(od -An -tx1 -N4 "$$f" | tr -d ' \n')" != "7f454c46" ]; then continue; fi; \
	  $(CROSS)strip --strip-unneeded "$$f" || { \
	    echo "  FAIL     strip $$f" >&2; exit 1; }; \
	  n=$$((n+1)); \
	done < <(find $(STAGE_DIR) -type f); \
	echo "  STRIP    $$n ELF files"
endef

.PHONY: stage-info
stage-info: $(STAGE_STAMP) ## Show what the staged tree contains and its size
	@echo "  stage    $(STAGE_DIR)"
	@du -sh $(STAGE_DIR) | sed 's/^/  total    /'
	@for d in usr/bin usr/lib usr/include usr/share usr/libexec; do \
	   [ -d $(STAGE_DIR)/$$d ] && du -sh $(STAGE_DIR)/$$d | sed 's/^/  /' || true; \
	 done
	@printf '  %s binaries, %s libraries\n' \
	   "$$(find $(STAGE_DIR)/usr/bin -type f 2>/dev/null | wc -l | tr -d ' ')" \
	   "$$(find $(STAGE_DIR)/usr/lib -name '*.so*' -type f 2>/dev/null | wc -l | tr -d ' ')"

# The staged tree is what reaches the device, so it is the tree whose shared
# library closure has to be complete. Anything a staged binary needs must be
# either in the stage or supplied by rootfs's musl - and libc.so is the only
# thing in that second category.
.PHONY: stage-check
stage-check: $(STAGE_STAMP) ## Verify the staged tree is aarch64 and self-contained
	@set -e; \
	 for b in clang lld; do \
	   p=$(STAGE_DIR)/usr/bin/$$b; \
	   [ -e "$$p" ] || { echo "  FAIL     $$b is not in the staged tree" >&2; exit 1; }; \
	   $(CROSS)readelf -h "$$p" | grep -q AArch64 \
	     || { echo "  FAIL     staged $$b is not aarch64" >&2; exit 1; }; \
	   $(CROSS)readelf -l "$$p" | grep -q 'ld-musl-aarch64.so.1' \
	     || { echo "  FAIL     staged $$b does not use the musl loader" >&2; exit 1; }; \
	   for n in $$($(CROSS)readelf -d "$$p" \
	                | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do \
	     [ "$$n" = "libc.so" ] && continue; \
	     [ -e $(STAGE_DIR)/usr/lib/$$n ] \
	       || { echo "  FAIL     $$b needs $$n, which is not staged and is not musl" >&2; exit 1; }; \
	   done; \
	   echo "  OK       $$b aarch64, musl loader, closure complete"; \
	 done
	@echo "  READY    staged tree is self-contained apart from musl"

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build output (keeps downloads)
	rm -rf $(BUILD_DIR)

.PHONY: distclean
distclean: clean ## Also remove downloaded sources and the toolchain
	rm -rf $(DL_DIR) $(DIST_DIR)

# Read one variable's value, for scripts and CI: make -s print-LLVM_VERSION
print-%:
	@echo '$($*)'

.PHONY: help
help: ## Show this help
	@echo "SepiaOS LLVM build"
	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z_-]+([ ]+[a-zA-Z_-]+)*:.*?## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /|/' \
	  | awk -F'|' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:"
	@printf "  %-18s %s\n" \
	  "LLVM_VERSION"  "upstream LLVM release (default $(LLVM_VERSION))" \
	  "LLVM_PROJECTS" "what to build (default $(LLVM_PROJECTS))" \
	  "LLVM_TARGETS"  "backends to enable (default $(LLVM_TARGETS))" \
	  "MUSL_VERSION"  "target musl - must match what rootfs ships (default $(MUSL_VERSION))" \
	  "SHIP_BINARIES" "allowlist of what lands in usr/bin" \
	  "WITH_LIBCLANG" "also ship libclang.so, the 41 MiB C API (default $(WITH_LIBCLANG))" \
	  "TC_VERSION"    "cross-toolchain release (default $(TC_VERSION))" \
	  "CROSS_COMPILE" "use a musl cross-toolchain you already have" \
	  "JOBS"          "parallelism for the target builds (default $(JOBS))"
