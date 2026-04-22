# Copyright (C) 2021-present ScyllaDB
#

#
# SPDX-License-Identifier: AGPL-3.0-or-later
#

#
# "nix build" produces a full ScyllaDB installation under $out/opt/scylladb
# with binaries, libraries, configs, scripts, and systemd units.
#
# IMPORTANT: to avoid using up ungodly amounts of disk space under
# /nix/store/ when you are not using flakes, make sure to move the
# actual build directory outside this tree and make ./build a
# symlink to it.  Or use flakes (seriously, just use flakes).
#

{ flake ? false
, shell ? false
, pkgs ? import <nixpkgs> { system = builtins.currentSystem; overlays = [ (import ./dist/nix/overlay.nix <nixpkgs>) ]; }
, srcPath ? builtins.path { path = ./.; name = "scylla"; }
, repl ? null
, mode ? "release"
, verbose ? false

# shell env will want to add stuff to the environment, and the way
# for it to do so is to pass us a function with this signatire:
, devInputs ? ({ pkgs, llvm }: [])
}:

let
  inherit (builtins)
    baseNameOf
    head
    match
    split
  ;

  inherit (import (builtins.fetchTarball {
    url = "https://github.com/hercules-ci/gitignore/archive/5b9e0ff9d3b551234b4f3eb3983744fa354b17f1.tar.gz";
    sha256 = "01l4phiqgw9xgaxr6jr456qmww6kzghqrnbc7aiiww3h6db5vw53";
  }) { inherit (pkgs) lib; })
    gitignoreSource;

  # all later Boost versions are problematic one way or another
  boost = pkgs.boost175;

  llvm = pkgs.llvmPackages_15;

  stdenvUnwrapped = llvm.stdenv;

  # define custom ccache- and distcc-aware wrappers for all relevant
  # compile drivers (used only in shell env)
  cc-wrappers = pkgs.callPackage ./dist/nix/pkg/custom/ccache-distcc-wrap {
    cc = stdenvUnwrapped.cc;
    clang = llvm.clang;
    inherit (pkgs) gcc;
  };

  stdenv = if shell then pkgs.overrideCC stdenvUnwrapped cc-wrappers
           else stdenvUnwrapped;

  noNix = path: type: type != "regular" || (match ".*\.nix" path) == null;
  src = builtins.filterSource noNix (if flake then srcPath
                                     else gitignoreSource srcPath);

  derive = if shell then pkgs.mkShell.override { inherit stdenv; }
           else stdenv.mkDerivation;

in derive ({
  name = "scylla";
  inherit src;

  # since Scylla build, as it exists, is not cross-capable, the
  # nativeBuildInputs/buildInputs distinction below ranges, depending
  # on how charitable one feels, from "pedantic" through
  # "aspirational" all the way to "cargo cult ritual" -- i.e. not
  # expected to be actually correct or verifiable.  but it's the
  # thought that counts!
  nativeBuildInputs = with pkgs; [
    ant
    antlr3
    boost
    cargo
    cmake
    cxx-rs
    doxygen
    gcc
    openjdk11_headless
    libtool
    llvm.bintools
    maven
    ninja
    pkg-config
    python2
    (python3.withPackages (ps: with ps; [
      aiohttp
      boto3
      colorama
      distro
      magic
      psutil
      pyparsing
      pytest
      pytest-asyncio
      pyudev
      pyyaml
      requests
      scylla-driver
      setuptools
      tabulate
      urwid
    ]))
    patchelf
    ragel
    rustc
    stow
  ] ++ (devInputs { inherit pkgs llvm; });

  buildInputs = with pkgs; [
    abseil-cpp
    antlr3
    boost
    c-ares
    cryptopp
    fmt
    gmp
    gnutls
    hwloc
    icu
    jsoncpp
    libdeflate
    libidn2
    libp11
    libsystemtap
    libtasn1
    libunistring
    liburing
    libxcrypt
    libxfs
    libxml2
    libyamlcpp
    llvm.compiler-rt
    lksctp-tools
    lua54Packages.lua
    lz4
    nettle
    numactl
    openssl
    p11-kit
    protobuf
    rapidjson
    snappy
    systemd
    valgrind
    xorg.libpciaccess
    xxHash
    zlib
    zstd
  ];

  JAVA8_HOME = "${pkgs.openjdk8_headless}/lib/openjdk";
  JAVA_HOME = "${pkgs.openjdk11_headless}/lib/openjdk";

}
// (if shell then {

  configurePhase = "./configure.py${if verbose then " --verbose" else ""} --disable-dpdk";

} else {

  # sha256 of the filtered source tree:
  SCYLLA_RELEASE = head (split "-" (baseNameOf src));

  postPatch = ''
    patchShebangs ./configure.py
    patchShebangs ./seastar/scripts/seastar-json2code.py
    patchShebangs ./seastar/cooking.sh

    # Pre-create version files so SCYLLA-VERSION-GEN doesn't
    # try to use git (which fails in the Nix sandbox).
    mkdir -p build
    echo "6.2.0" > build/SCYLLA-VERSION-FILE
    echo "0" > build/SCYLLA-RELEASE-FILE
    echo "scylla" > build/SCYLLA-PRODUCT-FILE

    # Also create them at the top level for install.sh
    echo "6.2.0" > SCYLLA-VERSION-FILE
    echo "0" > SCYLLA-RELEASE-FILE
    echo "scylla" > SCYLLA-PRODUCT-FILE

    # Patch SCYLLA-VERSION-GEN to be a no-op (files already exist)
    cat > SCYLLA-VERSION-GEN <<'VGEN'
    #!/bin/sh
    exit 0
    VGEN
    chmod +x SCYLLA-VERSION-GEN
  '';

  configurePhase = "./configure.py${if verbose then " --verbose" else ""} --mode=${mode}";

  buildPhase = ''
    ${pkgs.ninja}/bin/ninja \
      build/${mode}/scylla \
      build/${mode}/iotune \

  '';

  installPhase = let
    python3 = pkgs.python3.withPackages (ps: with ps; [
      pyyaml psutil distro pyudev requests setuptools
    ]);
  in ''
    runHook preInstall

    # Create the relocatable package (self-contained tarball with
    # binaries, shared libs, configs, scripts)
    patchShebangs scripts/create-relocatable-package.py
    ${python3}/bin/python3 scripts/create-relocatable-package.py \
      --build-dir build/${mode} \
      --node-exporter-dir build/node_exporter \
      --debian-dir build/debian/debian \
      build/scylla-package.tar.gz || true

    # If the relocatable package script fails (e.g. missing node_exporter),
    # fall back to manual installation from build artifacts.
    if [ ! -f build/scylla-package.tar.gz ]; then
      echo "Relocatable package not created, installing manually..."

      # Create the installation layout directly
      local prefix="$out/opt/scylladb"
      mkdir -p "$prefix"/{bin,libexec,libreloc,scripts,conf}
      mkdir -p "$out/etc/scylla" "$out/etc/scylla.d"

      # Binaries
      cp build/${mode}/scylla "$prefix/libexec/"
      cp build/${mode}/iotune "$prefix/libexec/"
      chmod 755 "$prefix/libexec/"*

      # Gather shared library dependencies
      for exe in "$prefix/libexec/scylla" "$prefix/libexec/iotune"; do
        for lib in $(ldd "$exe" | grep "=> /" | awk '{print $3}'); do
          basename=$(basename "$lib")
          [ ! -f "$prefix/libreloc/$basename" ] && cp "$lib" "$prefix/libreloc/" || true
        done
        # Also copy the dynamic linker
        local ld_so=$(ldd "$exe" | grep "ld-linux" | awk '{print $1}')
        [ -n "$ld_so" ] && [ ! -f "$prefix/libreloc/ld.so" ] && cp "$ld_so" "$prefix/libreloc/ld.so" || true
      done
      chmod 755 "$prefix/libreloc/"*

      # Create wrapper scripts that set LD_LIBRARY_PATH
      for bin in scylla iotune; do
        cat > "$prefix/bin/$bin" <<WRAPPER
    #!/bin/bash -e
    [[ -z "\$LD_PRELOAD" ]] || { echo "\$0: not compatible with LD_PRELOAD" >&2; exit 110; }
    export LD_LIBRARY_PATH="/opt/scylladb/libreloc"
    exec -a "\$0" "/opt/scylladb/libexec/$bin" "\$@"
    WRAPPER
        chmod 755 "$prefix/bin/$bin"
      done

      # Config files
      cp conf/* "$out/etc/scylla/"

      # Scripts
      cp -r dist/common/scripts/* "$prefix/scripts/"
      patchShebangs "$prefix/scripts/"

      # Seastar scripts
      mkdir -p "$prefix/scripts"
      cp seastar/scripts/seastar-cpu-map.sh "$prefix/scripts/"

      # Systemd units
      mkdir -p "$out/lib/systemd/system"
      cp dist/common/systemd/*.service "$out/lib/systemd/system/" || true
      cp dist/common/systemd/*.slice "$out/lib/systemd/system/" || true
      cp dist/common/systemd/*.timer "$out/lib/systemd/system/" || true

    else
      # Unpack relocatable package and run install.sh
      mkdir -p unpack
      tar xzf build/scylla-package.tar.gz -C unpack
      cd unpack/scylla

      patchShebangs install.sh
      # install.sh uses its own install() wrapper that adds -Z (SELinux context)
      # which fails on NixOS. Patch it out.
      sed -i 's/command install -Z/command install/' install.sh

      bash install.sh \
        --root "$out" \
        --prefix /opt/scylladb \
        --packaging \
        --without-systemd

      # Install systemd units separately
      mkdir -p "$out/lib/systemd/system"
      cp dist/common/systemd/*.service "$out/lib/systemd/system/" || true
      cp dist/common/systemd/*.slice "$out/lib/systemd/system/" || true
      cp dist/common/systemd/*.timer "$out/lib/systemd/system/" || true

      cd ../..
    fi

    # Create usr/bin symlinks
    mkdir -p "$out/usr/bin"
    ln -sf /opt/scylladb/bin/scylla "$out/usr/bin/scylla"
    ln -sf /opt/scylladb/bin/iotune "$out/usr/bin/iotune"

    runHook postInstall
  '';

})
// (if !shell || repl == null then {} else {

  REPL = repl;

})
)
