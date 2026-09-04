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
# The linker and runtime defaults point at LLVM's own runtimes, which step 5b
# cross-builds and step 6 stages. They are variables rather than literals so a
# card can be built the other way - CLANG_RTLIB=libgcc CLANG_CXX_STDLIB=libstdc++
# reverts to GCC's runtime, which is what the toolchain itself is linked against.
# ---------------------------------------------------------------------------

# What the on-device clang reaches for when it is given no flags. compiler-rt
# and libc++ are what step 5b builds and step 6 ships; leaving these at their
# upstream defaults would make the shipped clang default to a libgcc and a
# libstdc++ that are not on the card.
CLANG_RTLIB      ?= compiler-rt
CLANG_CXX_STDLIB ?= libc++
CLANG_UNWINDLIB  ?= libunwind

# Where the shipped clang looks for its own configuration file. Relative paths
# are resolved against the directory holding the binary (clang/lib/Driver/
# Driver.cpp), so ../lib/clang-config means /usr/lib/clang-config for a clang in
# /usr/bin and the staged tree stays relocatable. This is how the Objective-C
# runtime default reaches the driver: there is no CLANG_DEFAULT_OBJC_RUNTIME.
CLANG_CFG_DIR := ../lib/clang-config
# The same directory seen from the root of the staged tree. These two must
# agree: the first is what the compiler was built to look for, the second is
# where step 6 puts the file.
CLANG_CFG_STAGE := usr/lib/clang-config

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
TARGET_SIG  = $(LLVM_VERSION)|$(LLVM_PROJECTS)|$(LLVM_TARGETS)|$(LLVM_TRIPLE)|$(TC_VENDOR)|$(TC_VERSION)|$(MUSL_VERSION)|$(CROSS_COMPILE)|$(CLANG_RTLIB)|$(CLANG_CXX_STDLIB)|$(CLANG_UNWINDLIB)|$(CLANG_CFG_DIR)
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
  -DLLVM_ENABLE_LIBEDIT=OFF \
  -DCLANG_DEFAULT_RTLIB=$(CLANG_RTLIB) \
  -DCLANG_DEFAULT_CXX_STDLIB=$(CLANG_CXX_STDLIB) \
  -DCLANG_DEFAULT_UNWINDLIB=$(CLANG_UNWINDLIB) \
  -DCLANG_CONFIG_FILE_SYSTEM_DIR=$(CLANG_CFG_DIR)

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
# Step 5b - the LLVM runtimes
#
# Step 5 produces a compiler; this produces the libraries that compiler emits
# calls into. Without them the shipped clang starts, parses and generates code,
# and then cannot link a single program: its driver asks for a builtins library
# and, for C++, a standard library, and neither is on the card.
#
#   compiler-rt   the builtins (__udivti3 and friends). Replaces libgcc.a.
#   libunwind     the unwinder. Replaces libgcc_s's.
#   libcxxabi     the Itanium C++ ABI - exceptions, RTTI, the vtable layout.
#   libcxx        the C++ standard library, headers included.
#
# Built with a *host clang* cross-targeting the device, not with the cross GCC
# that builds everything else here. That was the first design and CI refuted it:
# LLVM 23's libc++ headers are written against clang builtins GCC 14 does not
# have - __is_unbounded_array, __is_pointer, __builtin_operator_new, __decay,
# __add_lvalue_reference - so libc++abi dies ~1700 ninja steps in, with errors
# *inside the libc++ headers* rather than in anything this repo wrote. Measured,
# not read: compiler-rt and libunwind build fine under GCC (libunwind.so.1 was
# linked); libc++ is the one that cannot. Do not "simplify" this back to the
# cross GCC to match the other steps.
#
# The chicken-and-egg that made GCC look attractive is handled the way step 5c
# handles it: clang's default rtlib on this target is libgcc, and the cross
# toolchain's own libgcc is handed over with -L, so CMake's compiler check links
# on the first try without needing the builtins this build has not produced yet.
# The runtimes therefore link against libgcc for their own needs while the
# *shipped clang* defaults to compiler-rt for user code - which is set in step 5,
# not here.
#
# LLVM_ENABLE_PER_TARGET_RUNTIME_DIR is OFF on purpose. ON installs libc++ into
# lib/<triple>/, which clang would find but the *loader* would not - it is not
# on musl's default search path, so every program linked against libc++ would
# fail to start. This device hosts exactly one target, so the flat layout is
# both simpler and correct.
#
# compiler-rt's install path has to be said twice, and both times absolutely.
# A *standalone* runtimes build defaults COMPILER_RT_INSTALL_PATH to empty, which
# puts the builtins in <prefix>/lib/linux - not in the clang resource directory,
# which is the only place the on-device clang looks for them, so -rtlib=compiler-rt
# would fail on a card that looks complete. Setting COMPILER_RT_INSTALL_PATH alone
# fixes a *fresh* tree only: compiler-rt derives COMPILER_RT_INSTALL_LIBRARY_DIR
# from it into its own cache entry, and `set(... CACHE ...)` will not overwrite
# that on a reconfigure, so an existing build/runtimes keeps installing to the old
# place. Naming both is what makes this work whether the tree is new or not.
#
# Installed into the sysroot as well as into the stage: step 5c compiles
# Objective-C++ against these headers, and --sysroot is how it finds them.
# ---------------------------------------------------------------------------

LLVM_RUNTIMES ?= compiler-rt;libunwind;libcxxabi;libcxx

RUNTIMES_BUILD := $(BUILD_DIR)/runtimes
RUNTIMES_LOG    = $(RUNTIMES_BUILD)/build.log
RUNTIMES_STAMP  = $(RUNTIMES_BUILD)/.built

# A clang on *this* machine that can emit aarch64 ELF, used by steps 5b and 5c
# and by nothing else. It has to be roughly as new as the LLVM being built,
# because step 5b compiles libc++'s own headers: measured, Debian trixie's
# clang 19 fails on `#pragma clang attribute` with __visibility__, and GCC 14
# fails earlier still on clang-only builtins. CI installs clang-$(LLVM_MAJOR)
# from apt.llvm.org for an exact match; Apple clang 21 is new enough on macOS.
HOST_CLANG   ?= clang

# clang -> clang++, clang-23 -> clang++-23, /path/to/clang -> /path/to/clang++.
# The naive $(HOST_CLANG)++ gets the versioned Debian names wrong - it produces
# clang-23++, which does not exist - and the failure lands four steps and one
# toolchain download later.
HOST_CLANGXX ?= $(shell printf '%s' '$(HOST_CLANG)' \
                  | sed -e 's|clang$$|clang++|' -e 's|clang\(-[0-9][0-9.]*\)$$|clang++\1|')

# libgcc.a and libgcc_s.so.1 live in the toolchain, in two different
# directories, and both are asked for by name rather than guessed at - the same
# -print-file-name idiom the rest of this Makefile uses. Handing them to clang
# is what lets its default -rtlib=libgcc link before compiler-rt exists.
TC_LIBGCC_DIR = $(abspath $(dir $(shell $(CROSS)gcc -print-libgcc-file-name)))

# --gcc-install-dir is what makes clang find crtbegin/crtend. Without it clang
# hunts for a GCC installation by triple, finds none - these toolchains call
# themselves aarch64-buildroot-linux-musl and aarch64-unknown-linux-musl, while
# the product is built as the latter - and emits bare "crtbeginS.o" names that
# the linker cannot resolve. -L does not cover it: those are input objects, not
# libraries. The directory wanted is the one holding libgcc.a, which is exactly
# what -print-libgcc-file-name names.
CLANG_CROSS_LDFLAGS = --ld-path=$(CROSS)ld --gcc-install-dir=$(TC_LIBGCC_DIR) \
                      -L$(TC_LIBGCC_DIR) $(CROSS_LDFLAGS)

# The cross setup: where the sysroot is, which compilers drive the build, how
# they are told to link. Deliberately kept out of RUNTIMES_SIG below - these
# reach CLANG_CROSS_LDFLAGS, hence TC_LIBGCC_DIR, which shells out to the cross
# gcc. A signature is expanded at parse time, so signing them would run that
# probe on every `gmake help` and yield nothing at all before the toolchain has
# been downloaded. What they encode is which toolchain and which sysroot, and
# TC_VENDOR, TC_VERSION, CROSS_COMPILE, HOST_CLANG, MUSL_VERSION and
# LLVM_TRIPLE already say that.
RUNTIMES_CROSS_FLAGS = \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_SYSROOT=$(abspath $(SYSROOT)) \
  -DCMAKE_C_COMPILER=$(HOST_CLANG) \
  -DCMAKE_CXX_COMPILER=$(HOST_CLANGXX) \
  -DCMAKE_ASM_COMPILER=$(HOST_CLANG) \
  -DCMAKE_C_COMPILER_TARGET=$(LLVM_TRIPLE) \
  -DCMAKE_CXX_COMPILER_TARGET=$(LLVM_TRIPLE) \
  -DCMAKE_ASM_COMPILER_TARGET=$(LLVM_TRIPLE) \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_INSTALL_PREFIX=/usr \
  "-DCMAKE_EXE_LINKER_FLAGS=$(CLANG_CROSS_LDFLAGS)" \
  "-DCMAKE_SHARED_LINKER_FLAGS=$(CLANG_CROSS_LDFLAGS)" \
  "-DCMAKE_MODULE_LINKER_FLAGS=$(CLANG_CROSS_LDFLAGS)"

# What actually gets built, and it is signed: change a switch here and the
# stamp moves, so the runtimes are reconfigured instead of the old libc++
# being silently reused and the wrong binary verified.
#
# LIBCXX_HAS_ATOMIC_LIB is set rather than probed. libcxx's config-ix.cmake
# runs check_library_exists(atomic __atomic_fetch_add_8 "" ...), which asks
# whether the toolchain *has* a libatomic - not whether libc++ *uses* one - and
# CMakeLists.txt then links -latomic on that answer alone. The link is not
# --as-needed, so libc++.so.1 records DT_NEEDED libatomic.so.1 while
# referencing nothing from it, and since DT_NEEDED is loaded eagerly every
# program linked against libc++ dies at exec on a card that has no libatomic.
# Measured on the v23.1.0 asset: not one of libc++'s 230 undefined symbols is
# a __atomic_* one. check_library_exists is guarded by
# if(NOT DEFINED "${VARIABLE}"), so a cache value on the configure line skips
# the probe entirely. If a future libc++ ever does need 16-byte atomics this
# turns into a link error rather than a silent gap - and the answer then is to
# drop this flag and add libatomic.so.1 to CXX_RUNTIME_LIBS.
RUNTIMES_FEATURE_FLAGS = \
  -DLLVM_ENABLE_RUNTIMES="$(LLVM_RUNTIMES)" \
  -DLLVM_DEFAULT_TARGET_TRIPLE=$(LLVM_TRIPLE) \
  -DLLVM_TARGETS_TO_BUILD=$(LLVM_TARGETS) \
  -DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DCOMPILER_RT_INSTALL_PATH=/usr/lib/clang/$(LLVM_MAJOR) \
  -DCOMPILER_RT_INSTALL_LIBRARY_DIR=/usr/lib/clang/$(LLVM_MAJOR)/lib/linux \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_CTX_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_BUILD_GWP_ASAN=OFF \
  -DCOMPILER_RT_INCLUDE_TESTS=OFF \
  -DLIBUNWIND_ENABLE_STATIC=OFF \
  -DLIBUNWIND_INCLUDE_TESTS=OFF \
  -DLIBUNWIND_INSTALL_LIBRARY_DIR=lib \
  -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
  -DLIBCXXABI_ENABLE_STATIC=OFF \
  -DLIBCXXABI_INCLUDE_TESTS=OFF \
  -DLIBCXXABI_INSTALL_LIBRARY_DIR=lib \
  -DLIBCXX_HAS_MUSL_LIBC=ON \
  -DLIBCXX_ENABLE_STATIC=OFF \
  -DLIBCXX_INCLUDE_TESTS=OFF \
  -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
  -DLIBCXX_HAS_ATOMIC_LIB=NO \
  -DLIBCXX_INSTALL_LIBRARY_DIR=lib

RUNTIMES_CMAKE_FLAGS = $(RUNTIMES_CROSS_FLAGS) $(RUNTIMES_FEATURE_FLAGS)

RUNTIMES_CFG := $(RUNTIMES_BUILD)/.config
RUNTIMES_SIG  = $(LLVM_VERSION)|$(LLVM_RUNTIMES)|$(LLVM_TRIPLE)|$(TC_VENDOR)|$(TC_VERSION)|$(MUSL_VERSION)|$(CROSS_COMPILE)|$(HOST_CLANG)|$(RUNTIMES_FEATURE_FLAGS)
$(eval $(call config_stamp_rule,$(RUNTIMES_CFG),$(RUNTIMES_SIG)))

.PHONY: runtimes
runtimes: $(RUNTIMES_STAMP) ## Cross-build compiler-rt, libunwind, libc++abi and libc++
	@echo "  READY    runtimes -> $(SYSROOT)/usr/lib"

$(RUNTIMES_STAMP): $(MUSL_STAMP) $(LLVM_STAMP) $(RUNTIMES_CFG) Makefile
	@$(call require_build_tools)
	@$(call assert_cross_compiler)
	@$(call assert_host_clang)
	@mkdir -p $(RUNTIMES_BUILD)
	@echo "  CONFIG   runtimes $(LLVM_RUNTIMES) (log: $(RUNTIMES_LOG))"
	@$(SCRUB_ENV) cmake -G Ninja -S $(LLVM_SRC)/runtimes -B $(RUNTIMES_BUILD) \
	   $(RUNTIMES_CMAKE_FLAGS) > $(RUNTIMES_LOG) 2>&1 || { \
	   tail -40 $(RUNTIMES_LOG) >&2; \
	   echo "  FAIL     configure (full log: $(RUNTIMES_LOG))" >&2; exit 1; }
	@echo "  BUILD    runtimes (-j$(JOBS))"
	@$(SCRUB_ENV) cmake --build $(RUNTIMES_BUILD) --parallel $(JOBS) \
	   >> $(RUNTIMES_LOG) 2>&1 || { \
	   tail -40 $(RUNTIMES_LOG) >&2; \
	   echo "  FAIL     build (full log: $(RUNTIMES_LOG))" >&2; exit 1; }
	@echo "  INSTALL  runtimes -> $(SYSROOT)"
	@DESTDIR=$(abspath $(SYSROOT)) $(SCRUB_ENV) cmake --install $(RUNTIMES_BUILD) \
	   >> $(RUNTIMES_LOG) 2>&1 || { \
	   tail -30 $(RUNTIMES_LOG) >&2; \
	   echo "  FAIL     install (full log: $(RUNTIMES_LOG))" >&2; exit 1; }
	@$(call assert_runtimes,$(abspath $(SYSROOT))/usr)
	@touch $@

# $(1) the usr/ prefix to look under. The builtins archive is *found* rather
# than named: its filename and subdirectory depend on the per-target layout
# switch and on the OS name compiler-rt derives, and a wrong guess here would
# ship a toolchain that cannot link. If it moves, this prints the tree rather
# than failing mutely.
define assert_runtimes
	set -e; \
	for l in libc++.so.1 libc++abi.so.1 libunwind.so.1; do \
	  p=$(1)/lib/$$l; \
	  [ -e "$$p" ] || { echo "  FAIL     $$l was not installed" >&2; exit 1; }; \
	  $(CROSS)readelf -h "$$p" | grep -q AArch64 \
	    || { echo "  FAIL     $$l is not aarch64" >&2; exit 1; }; \
	done; \
	[ -f $(1)/include/c++/v1/vector ] \
	  || { echo "  FAIL     libc++ headers are missing from $(1)/include/c++/v1" >&2; exit 1; }; \
	b=$$(find $(1)/lib/clang/$(LLVM_MAJOR) -name 'libclang_rt.builtins*' -print 2>/dev/null | sed -n '1p') || true; \
	if [ -z "$$b" ]; then \
	  echo "  FAIL     no compiler-rt builtins in the clang resource directory," >&2; \
	  echo "           $(1)/lib/clang/$(LLVM_MAJOR)/lib/ - which is the only place" >&2; \
	  echo "           the on-device clang looks. COMPILER_RT_INSTALL_PATH decides it." >&2; \
	  echo "           What was installed instead:" >&2; \
	  find $(1) -name 'libclang_rt*' 2>/dev/null | sed 's/^/             /' >&2 || true; \
	  exit 1; \
	fi; \
	echo "  OK       libc++, libc++abi, libunwind, $$(basename $$b)"
endef

.PHONY: runtimes-info
runtimes-info: $(RUNTIMES_STAMP) ## Show the cross-built runtimes and their sizes
	@echo "  runtimes $(LLVM_RUNTIMES)"
	@echo "  tree     $(RUNTIMES_BUILD)"
	@for l in libc++.so.1 libc++abi.so.1 libunwind.so.1; do \
	   p=$(SYSROOT)/usr/lib/$$l; \
	   [ -e "$$p" ] && printf '  %-16s %s bytes\n' "$$l" "$$(wc -c < $$p | tr -d ' ')" || true; \
	 done
	@find $(SYSROOT)/usr/lib/clang/$(LLVM_MAJOR) -name 'libclang_rt.*' 2>/dev/null \
	   | sed 's|^$(SYSROOT)/usr/|  builtins /usr/|' || true
	@printf '  %s libc++ headers\n' \
	   "$$(find $(SYSROOT)/usr/include/c++/v1 -type f 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# Step 5c - the Objective-C runtime
#
# Objective-C and Objective-C++ are frontends clang already has; what it does
# not have is a runtime to emit calls into. That runtime is not an LLVM
# component at all - LLVM ships the compiler and nothing else - so it comes
# from GNUstep's libobjc2, the modern non-fragile-ABI runtime with ARC.
#
# Three things about it that shape this step:
#
#   It requires clang. Its CMakeLists.txt refuses any other compiler outright
#   (`if (NOT "${CMAKE_C_COMPILER_ID}" MATCHES Clang*)`), because the ABI it
#   implements is one only clang emits. The cross GCC that builds everything
#   else here cannot build it, so this is the one step that needs a host clang
#   able to target aarch64 musl - HOST_CLANG, asserted before it is used.
#
#   It carries its own blocks runtime (EMBEDDED_BLOCKS_RUNTIME, on by default),
#   so -fblocks needs nothing further.
#
#   It links against libgcc rather than compiler-rt, unlike everything the
#   shipped clang will emit. A host clang looks for compiler-rt in *its own*
#   resource directory, not in the sysroot, so pointing it at the builtins
#   cross-built in step 5b would mean overriding -resource-dir and dragging in
#   that clang's builtin headers as well. libgcc_s.so.1 is on the card anyway -
#   the toolchain binaries themselves need it - and both unwinders implement the
#   same ABI, so this is a wart rather than a defect. Ways out, in order of
#   sanity: build libobjc2 with the clang from step 5 under an emulator, or
#   construct a resource-dir shim holding our builtins and the host clang's
#   headers.
#
# GNUSTEP_INSTALL_TYPE is pinned to NONE so the layout is plain /usr/lib and
# /usr/include; left alone, libobjc2 asks gnustep-config where to install and
# would land somewhere else entirely on a developer machine that has GNUstep.
#
# OBJC and OBJCXX need their *own* CMAKE_<LANG>_COMPILER_TARGET. libobjc2 calls
# enable_language(OBJC) after project(), and CMake treats those as languages
# separate from C and CXX: without them the ObjC compiler check builds for the
# *host*, and the aarch64 linker then rejects the result with "unrecognised
# emulation mode: elf_x86_64" - which reads like a broken toolchain rather than
# a missing flag. Any language this project enables needs a target here.
#
# -include stdlib.h is not decoration. libobjc2 2.3 calls abort() in
# selector_table.cc without including it, and gets away with that against
# libstdc++, which pulls it in transitively. libc++ has been deleting those
# transitive includes for several releases, so against LLVM 23's the file simply
# does not compile: "use of undeclared identifier 'abort'". Forcing the header in
# is preferable to carrying a patch against an upstream release tarball; if a
# later libobjc2 fixes the include, this can go.
#
# Note also that libobjc2 2.3 pulls robin-map with FetchContent while it
# configures, so this step needs the network and downloads something that
# checksums/ does not pin. That is upstream's choice, not a decision made here.
# ---------------------------------------------------------------------------

# libobjc2 publishes no release assets, so this is GitHub's generated archive of
# the tag. Those are *not* guaranteed byte-stable - GitHub has changed its gzip
# settings before and invalidated every checksum pinned this way - so a verify
# failure here may mean the archive was regenerated rather than that anything is
# wrong. Check the contents before rewriting checksums/, and note that the tag
# itself is immutable even when the tarball around it is not. There are no
# submodules, so the archive is complete.
OBJC2_VERSION ?= 2.3
OBJC2_ARCHIVE  = libobjc2-$(OBJC2_VERSION).tar.gz
OBJC2_URL      = https://github.com/gnustep/libobjc2/archive/refs/tags/v$(OBJC2_VERSION).tar.gz
OBJC2_SUMS     = $(CHECKSUMS)/libobjc2-$(OBJC2_VERSION).sha256

DL_OBJC2   := $(DL_DIR)/libobjc2
OBJC2_DIR  := $(BUILD_DIR)/libobjc2
OBJC2_SRC   = $(OBJC2_DIR)/libobjc2-$(OBJC2_VERSION)
OBJC2_BUILD = $(OBJC2_DIR)/build
OBJC2_LOG   = $(OBJC2_DIR)/build.log
OBJC2_STAMP = $(OBJC2_DIR)/.installed

# The ABI the shipped clang will emit by default, written into its config file
# in step 6. libobjc2 2.3 implements the 2.2 ABI; clang parses the version
# generically, so a newer runtime does not need a newer clang.
OBJC_RUNTIME ?= gnustep-2.2

# Step 5b's link setup, plus the runtimes it has by now installed into the
# sysroot - libc++ and libunwind, which the Objective-C++ half links against.
OBJC2_LDFLAGS = $(CLANG_CROSS_LDFLAGS) -L$(abspath $(SYSROOT))/usr/lib

OBJC2_CFG := $(OBJC2_DIR)/.config
OBJC2_SIG  = $(OBJC2_VERSION)|$(LLVM_TRIPLE)|$(MUSL_VERSION)|$(TC_VENDOR)|$(TC_VERSION)|$(CROSS_COMPILE)|$(HOST_CLANG)
$(eval $(call config_stamp_rule,$(OBJC2_CFG),$(OBJC2_SIG)))

OBJC2_CMAKE_FLAGS = \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Linux \
  -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_SYSROOT=$(abspath $(SYSROOT)) \
  -DCMAKE_C_COMPILER=$(HOST_CLANG) \
  -DCMAKE_CXX_COMPILER=$(HOST_CLANGXX) \
  -DCMAKE_ASM_COMPILER=$(HOST_CLANG) \
  -DCMAKE_OBJC_COMPILER=$(HOST_CLANG) \
  -DCMAKE_OBJCXX_COMPILER=$(HOST_CLANGXX) \
  -DCMAKE_C_COMPILER_TARGET=$(LLVM_TRIPLE) \
  -DCMAKE_CXX_COMPILER_TARGET=$(LLVM_TRIPLE) \
  -DCMAKE_ASM_COMPILER_TARGET=$(LLVM_TRIPLE) \
  -DCMAKE_OBJC_COMPILER_TARGET=$(LLVM_TRIPLE) \
  -DCMAKE_OBJCXX_COMPILER_TARGET=$(LLVM_TRIPLE) \
  -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib \
  "-DCMAKE_CXX_FLAGS=-stdlib=libc++ -include stdlib.h" \
  "-DCMAKE_OBJCXX_FLAGS=-stdlib=libc++ -include stdlib.h" \
  "-DCMAKE_EXE_LINKER_FLAGS=$(OBJC2_LDFLAGS)" \
  "-DCMAKE_SHARED_LINKER_FLAGS=$(OBJC2_LDFLAGS)" \
  "-DCMAKE_MODULE_LINKER_FLAGS=$(OBJC2_LDFLAGS)" \
  -DGNUSTEP_INSTALL_TYPE=NONE \
  -DBUILD_STATIC_LIBOBJC=OFF \
  -DENABLE_OBJCXX=ON \
  -DTESTS=OFF

.PHONY: objc-runtime
objc-runtime: $(OBJC2_STAMP) ## Cross-build the GNUstep Objective-C runtime
	@echo "  READY    libobjc2 $(OBJC2_VERSION) -> $(SYSROOT)/usr/lib"

$(OBJC2_STAMP): $(RUNTIMES_STAMP) $(OBJC2_CFG) Makefile
	@$(call require_build_tools)
	@$(call assert_cross_compiler)
	@$(call assert_host_clang)
	@test -f "$$($(CROSS)gcc -print-libgcc-file-name)" || { \
	   echo "  FAIL     libgcc.a not found in the toolchain; libobjc2 links against it" >&2; \
	   exit 1; }
	@mkdir -p $(DL_OBJC2) $(OBJC2_DIR) $(CHECKSUMS)
	@if [ ! -f $(DL_OBJC2)/$(OBJC2_ARCHIVE) ]; then \
	   echo "  FETCH    $(OBJC2_ARCHIVE)"; \
	   $(CURL) -o $(DL_OBJC2)/$(OBJC2_ARCHIVE).part "$(OBJC2_URL)"; \
	   mv -f $(DL_OBJC2)/$(OBJC2_ARCHIVE).part $(DL_OBJC2)/$(OBJC2_ARCHIVE); \
	 fi
	@if [ -f $(OBJC2_SUMS) ]; then \
	   echo "  VERIFY   $(OBJC2_ARCHIVE)"; \
	   ( cd $(DL_OBJC2) && $(SHA256) --check --quiet $(abspath $(OBJC2_SUMS)) ) || { \
	     echo "  FAIL     $(OBJC2_ARCHIVE) does not match $(OBJC2_SUMS)" >&2; exit 1; }; \
	 else \
	   ( cd $(DL_OBJC2) && $(SHA256) $(OBJC2_ARCHIVE) ) > $(OBJC2_SUMS); \
	   echo "  RECORD   $(OBJC2_SUMS) - first fetch of this version, commit it"; \
	 fi
	@echo "  UNPACK   $(OBJC2_ARCHIVE)"
	@rm -rf $(OBJC2_SRC)
	@tar -xf $(DL_OBJC2)/$(OBJC2_ARCHIVE) -C $(OBJC2_DIR)
	@echo "  CONFIG   libobjc2 $(OBJC2_VERSION) (log: $(OBJC2_LOG))"
	@$(SCRUB_ENV) cmake -G Ninja -S $(OBJC2_SRC) -B $(OBJC2_BUILD) \
	   $(OBJC2_CMAKE_FLAGS) > $(OBJC2_LOG) 2>&1 || { \
	   tail -40 $(OBJC2_LOG) >&2; \
	   echo "  FAIL     configure (full log: $(OBJC2_LOG))" >&2; exit 1; }
	@echo "  BUILD    libobjc2 (-j$(JOBS))"
	@$(SCRUB_ENV) cmake --build $(OBJC2_BUILD) --parallel $(JOBS) \
	   >> $(OBJC2_LOG) 2>&1 || { \
	   tail -40 $(OBJC2_LOG) >&2; \
	   echo "  FAIL     build (full log: $(OBJC2_LOG))" >&2; exit 1; }
	@echo "  INSTALL  libobjc2 -> $(SYSROOT)"
	@DESTDIR=$(abspath $(SYSROOT)) $(SCRUB_ENV) cmake --install $(OBJC2_BUILD) \
	   >> $(OBJC2_LOG) 2>&1 || { \
	   tail -30 $(OBJC2_LOG) >&2; \
	   echo "  FAIL     install (full log: $(OBJC2_LOG))" >&2; exit 1; }
	@$(call assert_objc_runtime,$(abspath $(SYSROOT))/usr)
	@touch $@

# The one tool this build needs that is neither downloaded nor built here, used
# by step 5b and step 5c, so it is checked before either uses it rather than
# failing 200 lines into a CMake log. Apple's clang is not guaranteed to emit
# Linux ELF on every release, which is one thing this catches.
#
# It compiles *and links*, deliberately: linking is what exercises --ld-path,
# the -L that makes clang's default -rtlib=libgcc resolve, and the crt objects
# in the sysroot - exactly what CMake's own compiler check does as its first act
# in both steps. A pass here means that check will pass.
define assert_host_clang
	set -e; \
	for c in $(HOST_CLANG) $(HOST_CLANGXX); do \
	  command -v "$$c" >/dev/null 2>&1 || { \
	    echo "  FAIL     $$c not found - libc++ and libobjc2 can only be built by clang," >&2; \
	    echo "           and it must be about as new as LLVM $(LLVM_VERSION) itself." >&2; \
	    echo "           Debian/Ubuntu: apt.llvm.org, then HOST_CLANG=clang-$(LLVM_MAJOR)" >&2; \
	    echo "                          (the distro's own clang 19 is too old)" >&2; \
	    echo "           macOS:         Apple clang 21+, or brew install llvm and" >&2; \
	    echo "                          HOST_CLANG=/opt/homebrew/opt/llvm/bin/clang" >&2; \
	    exit 1; }; \
	done; \
	t=$$(mktemp -d); \
	printf 'int main(void){return 0;}\n' > $$t/probe.c; \
	if ! $(HOST_CLANG) --target=$(LLVM_TRIPLE) --sysroot=$(abspath $(SYSROOT)) \
	     $(CLANG_CROSS_LDFLAGS) $$t/probe.c -o $$t/probe 2> $$t/err; then \
	  echo "  FAIL     $(HOST_CLANG) cannot build for $(LLVM_TRIPLE):" >&2; \
	  sed 's/^/           /' $$t/err >&2; rm -rf $$t; exit 1; \
	fi; \
	if ! $(CROSS)readelf -h $$t/probe | grep -q AArch64; then \
	  echo "  FAIL     $(HOST_CLANG) produced something that is not aarch64" >&2; \
	  rm -rf $$t; exit 1; \
	fi; \
	rm -rf $$t; \
	echo "  OK       $(HOST_CLANG) builds and links for $(LLVM_TRIPLE)"
endef

# $(1) the usr/ prefix to look under.
define assert_objc_runtime
	set -e; \
	p=$$(find $(1)/lib -maxdepth 1 -name 'libobjc.so*' ! -type l -print | sed -n '1p'); \
	[ -n "$$p" ] || { echo "  FAIL     libobjc.so was not installed into $(1)/lib" >&2; exit 1; }; \
	$(CROSS)readelf -h "$$p" | grep -q AArch64 \
	  || { echo "  FAIL     $$(basename $$p) is not aarch64" >&2; exit 1; }; \
	[ -f $(1)/include/objc/runtime.h ] \
	  || { echo "  FAIL     objc headers are missing from $(1)/include/objc" >&2; exit 1; }; \
	echo "  OK       $$(basename $$p), objc headers, blocks runtime included"
endef

.PHONY: objc-runtime-info
objc-runtime-info: $(OBJC2_STAMP) ## Show the Objective-C runtime that will ship
	@echo "  libobjc2 $(OBJC2_VERSION)"
	@echo "  abi      $(OBJC_RUNTIME)"
	@echo "  built by $(HOST_CLANG)"
	@for f in $$(find $(SYSROOT)/usr/lib -maxdepth 1 -name 'libobjc.so*' ! -type l); do \
	   printf '  %-16s %s bytes\n' "$$(basename $$f)" "$$(wc -c < $$f | tr -d ' ')"; \
	 done
	@printf '  %s objc headers\n' \
	   "$$(find $(SYSROOT)/usr/include/objc -type f 2>/dev/null | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# Step 6 - stage the install tree
#
# `cmake --install` under DESTDIR, so the tree is laid out exactly as it will
# sit on the device (prefix /usr) without anything being written outside
# build/. Three build trees install into the same staged tree - the compiler
# from step 5, the runtimes from 5b and the Objective-C runtime from 5c - and
# LLVM_INSTALL_TOOLCHAIN_ONLY already keeps the development-only material out.
# What remains is stripping, the two GCC runtime libraries that the toolchain
# owns and the sysroot does not, and the clang config file that gives the
# on-device driver its Objective-C ABI without anyone passing a flag.
#
# The GCC pair still ships even though user code now defaults to compiler-rt
# and libc++: the clang binary itself was built by GCC and does not start
# without them.
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
STAGE_SIG  = $(LLVM_VERSION)|$(SHIP_BINARIES)|$(WITH_LIBCLANG)|$(CXX_RUNTIME_LIBS)|$(LLVM_RUNTIMES)|$(OBJC2_VERSION)|$(OBJC_RUNTIME)|$(CLANG_CFG_STAGE)
$(eval $(call config_stamp_rule,$(STAGE_CFG),$(STAGE_SIG)))

$(STAGE_STAMP): $(TARGET_STAMP) $(RUNTIMES_STAMP) $(OBJC2_STAMP) $(STAGE_CFG) Makefile
	@$(call require_build_tools)
	@rm -rf $(STAGE_DIR)
	@mkdir -p $(STAGE_DIR)/usr/lib
	@echo "  INSTALL  -> $(STAGE_DIR) (log: $(STAGE_LOG))"
	@DESTDIR=$(abspath $(STAGE_DIR)) $(SCRUB_ENV) cmake --install $(TARGET_BUILD) \
	   > $(STAGE_LOG) 2>&1 || { \
	   tail -30 $(STAGE_LOG) >&2; \
	   echo "  FAIL     install (full log: $(STAGE_LOG))" >&2; exit 1; }
	@echo "  INSTALL  runtimes + objc runtime"
	@for b in $(RUNTIMES_BUILD) $(OBJC2_BUILD); do \
	   DESTDIR=$(abspath $(STAGE_DIR)) $(SCRUB_ENV) cmake --install $$b \
	     >> $(STAGE_LOG) 2>&1 || { \
	     tail -30 $(STAGE_LOG) >&2; \
	     echo "  FAIL     install $$b (full log: $(STAGE_LOG))" >&2; exit 1; }; \
	 done
	@echo "  RUNTIME  $(CXX_RUNTIME_LIBS)"
	@for l in $(CXX_RUNTIME_LIBS); do \
	   p=$$($(CROSS)gcc -print-file-name=$$l); \
	   case "$$p" in /*) ;; *) echo "  FAIL     $$l not found in the toolchain" >&2; exit 1;; esac; \
	   cp -L "$$p" $(STAGE_DIR)/usr/lib/$$l; \
	 done
	@echo "  CONFIG   $(CLANG_CFG_STAGE)/$(LLVM_TRIPLE).cfg (-fobjc-runtime=$(OBJC_RUNTIME))"
	@mkdir -p $(STAGE_DIR)/$(CLANG_CFG_STAGE)
	@printf '%s\n' '-fobjc-runtime=$(OBJC_RUNTIME)' \
	   > $(STAGE_DIR)/$(CLANG_CFG_STAGE)/$(LLVM_TRIPLE).cfg
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
#
# The closure is walked over the staged *libraries* as well as the two
# binaries, and that is the whole point: an earlier version read the DT_NEEDED
# of clang and lld only, so when libc++.so.1 came out of the build recording a
# libatomic.so.1 that nothing ships, no step here ever opened its dynamic
# section. The gap escaped to rootfs and was caught one repository downstream.
# A library's dependency is as load-bearing as a binary's - DT_NEEDED is
# resolved eagerly, so an unsatisfied one kills every program that links it.
#
# Two things the glob catches that are not ELF objects. Symlinks are the
# obvious one - libc++.so.1 and its .1.0 target are the same file twice. The
# other is usr/lib/libc++.so, which is an ASCII *linker script* reading
# INPUT(libc++.so.1 -lc++abi -lunwind); readelf cannot parse it, and because
# the readelf runs inside a `for` word list its failure would otherwise be
# swallowed and the file counted as a library with no dependencies at all -
# a check reporting success on something it never read. So non-ELF files are
# skipped on the magic number, the strip_stage idiom, and a readelf that fails
# on a file that *is* ELF is fatal.
define assert_closure
	deps=$$($(CROSS)readelf -d "$(1)" \
	         | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p') \
	  || { echo "  FAIL     cannot read the dynamic section of $(2)" >&2; exit 1; }; \
	for dep in $$deps; do \
	  [ "$$dep" = "libc.so" ] && continue; \
	  [ -e $(STAGE_DIR)/usr/lib/$$dep ] \
	    || { echo "  FAIL     $(2) needs $$dep, which is not staged and is not musl" >&2; \
	         exit 1; }; \
	done
endef

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
	   $(call assert_closure,$$p,$$b); \
	   echo "  OK       $$b aarch64, musl loader, closure complete"; \
	 done
	@set -e; libs=0; \
	 for p in $(STAGE_DIR)/usr/lib/*.so*; do \
	   if [ -L "$$p" ] || [ ! -f "$$p" ]; then continue; fi; \
	   if [ "$$(od -An -tx1 -N4 "$$p" | tr -d ' \n')" != "7f454c46" ]; then continue; fi; \
	   $(call assert_closure,$$p,$${p##*/}); \
	   libs=$$((libs + 1)); \
	 done; \
	 [ "$$libs" -gt 0 ] \
	   || { echo "  FAIL     no staged shared libraries to check" >&2; exit 1; }; \
	 echo "  OK       $$libs staged libraries, closure complete"
	@$(call assert_runtimes,$(STAGE_DIR)/usr)
	@$(call assert_objc_runtime,$(STAGE_DIR)/usr)
	@$(call assert_language_support)
	@echo "  READY    staged tree is self-contained apart from musl"

# What each language needs in order to get past the compile, over and above a
# clang that can parse it. This is a layout check, not a compile: it says the
# pieces are on the card in the places the driver looks, not that a program
# built with them runs. Only the device, or an emulator, can say that.
define assert_language_support
	set -e; \
	c=$(STAGE_DIR)/$(CLANG_CFG_STAGE)/$(LLVM_TRIPLE).cfg; \
	[ -f "$$c" ] \
	  || { echo "  FAIL     no clang config file at $$c - the shipped clang was" >&2; \
	       echo "           built to read $(CLANG_CFG_DIR)/$(LLVM_TRIPLE).cfg" >&2; exit 1; }; \
	grep -q -- '-fobjc-runtime=' "$$c" \
	  || { echo "  FAIL     $$c does not set an Objective-C runtime" >&2; exit 1; }; \
	[ -f $(STAGE_DIR)/usr/lib/clang/$(LLVM_MAJOR)/include/stddef.h ] \
	  || { echo "  FAIL     clang's builtin headers are missing - C cannot compile" >&2; exit 1; }; \
	[ -f $(STAGE_DIR)/usr/include/c++/v1/vector ] \
	  || { echo "  FAIL     no libc++ headers - C++ cannot compile" >&2; exit 1; }; \
	[ -f $(STAGE_DIR)/usr/include/objc/runtime.h ] \
	  || { echo "  FAIL     no objc headers - Objective-C cannot compile" >&2; exit 1; }; \
	[ -f $(STAGE_DIR)/usr/include/Block.h ] \
	  || echo "  WARN     no Block.h staged; -fblocks will not compile"; \
	echo "  OK       C, C++, Objective-C and Objective-C++ have their headers and runtimes"
endef

# ---------------------------------------------------------------------------
# Step 7 - the release asset
#
# The staged tree, tarred and compressed: exactly what rootfs unpacks into the
# root filesystem. Sibling repositories consume each other's *published
# releases* rather than each other's build trees, so this is the supported way
# out of here - nothing should read build/ across the filesystem.
#
# What ships is LLVM and nothing else. libstdc++.so.6 and libgcc_s.so.1 are in
# there because the linkage is dynamic and clang cannot run without them, and
# nothing else provides them; musl is emphatically *not*, because the device's
# libc comes from rootfs and a second copy on the card is how two libcs end up
# disagreeing. That is a property of the staged tree rather than of this
# recipe, so it is asserted here rather than assumed.
# ---------------------------------------------------------------------------

# Set by the release workflow so the published file names the release it came
# from; empty for a local build, which names the LLVM version alone.
DIST_TAG   ?=
DIST_ASSET  = sepiaos-llvm-$(LLVM_VERSION)-aarch64-musl$(if $(DIST_TAG),-$(DIST_TAG)).tar.xz
DIST_SUMS  := SHA256SUMS

.PHONY: dist
dist: $(STAGE_STAMP) ## Pack the staged tree into dist/ as a release asset
	@$(call assert_no_libc)
	@mkdir -p $(DIST_DIR)
	@echo "  PACK     $(DIST_ASSET)"
	@tar -C $(STAGE_DIR) -cf - usr \
	   | xz -9 -T0 -c > $(DIST_DIR)/$(DIST_ASSET).part
	@mv -f $(DIST_DIR)/$(DIST_ASSET).part $(DIST_DIR)/$(DIST_ASSET)
	@( cd $(DIST_DIR) && $(SHA256) $(DIST_ASSET) > $(DIST_SUMS) )
	@echo "  READY    $$(du -h $(DIST_DIR)/$(DIST_ASSET) | cut -f1) -> $(DIST_DIR)/$(DIST_ASSET)"

# musl reaching the asset would be a packaging mistake with a long fuse: it
# would install over rootfs's own libc and its loader, and the mismatch would
# only show up as something odd at runtime on the device.
define assert_no_libc
	set -e; \
	found=$$(find $(STAGE_DIR) \( -name 'libc.so*' -o -name 'ld-musl-*' \) -print); \
	if [ -n "$$found" ]; then \
	  echo "  FAIL     musl is in the staged tree; only LLVM ships:" >&2; \
	  printf '           %s\n' $$found >&2; exit 1; \
	fi; \
	echo "  OK       LLVM only - no libc, no loader"
endef

.PHONY: dist-info
dist-info: ## Show the packed asset and its digest
	@test -f $(DIST_DIR)/$(DIST_ASSET) \
	  || { echo "No $(DIST_DIR)/$(DIST_ASSET); run 'make dist' first." >&2; exit 1; }
	@echo "  asset    $(DIST_DIR)/$(DIST_ASSET)"
	@du -h $(DIST_DIR)/$(DIST_ASSET) | sed 's/^/  size     /' | cut -f1,2
	@sed 's/^/  sha256   /' $(DIST_DIR)/$(DIST_SUMS)
	@echo "  contents $$(tar -tf $(DIST_DIR)/$(DIST_ASSET) | wc -l | tr -d ' ') entries under usr/"

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
	  "LLVM_RUNTIMES" "target runtimes (default $(LLVM_RUNTIMES))" \
	  "LLVM_TARGETS"  "backends to enable (default $(LLVM_TARGETS))" \
	  "OBJC2_VERSION" "GNUstep Objective-C runtime (default $(OBJC2_VERSION))" \
	  "OBJC_RUNTIME"  "Objective-C ABI the shipped clang defaults to (default $(OBJC_RUNTIME))" \
	  "HOST_CLANG"    "clang on this machine, for libobjc2 (default $(HOST_CLANG))" \
	  "CLANG_RTLIB"   "shipped clang's default rtlib (default $(CLANG_RTLIB))" \
	  "CLANG_CXX_STDLIB" "shipped clang's default C++ library (default $(CLANG_CXX_STDLIB))" \
	  "MUSL_VERSION"  "target musl - must match what rootfs ships (default $(MUSL_VERSION))" \
	  "SHIP_BINARIES" "allowlist of what lands in usr/bin" \
	  "WITH_LIBCLANG" "also ship libclang.so, the 41 MiB C API (default $(WITH_LIBCLANG))" \
	  "TC_VERSION"    "cross-toolchain release (default $(TC_VERSION))" \
	  "CROSS_COMPILE" "use a musl cross-toolchain you already have" \
	  "JOBS"          "parallelism for the target builds (default $(JOBS))" \
	  "DIST_TAG"      "release tag to name the packed asset after (default: none)"
