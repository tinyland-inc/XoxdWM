# Chapel 2.8.0 — parallel programming language for productive HPC
#
# Build configuration targets the Dell T7810 dual-socket Xeon (NUMA):
#   CHPL_TASKS=qthreads    — required for NUMA sublocale support
#   CHPL_LOCALE_MODEL=flat — single-locale default (numa available at runtime)
#   CHPL_COMM=none         — single-node; use gasnet for multi-locale
#   CHPL_LLVM=system       — consistent codegen via Nix's LLVM

{ lib
, stdenv
, fetchurl
, python3
, llvmPackages_18
, gmp
, which
, perl
, bash
, cmake
}:

stdenv.mkDerivation rec {
  pname = "chapel";
  version = "2.8.0";

  src = fetchurl {
    url = "https://github.com/chapel-lang/chapel/releases/download/${version}/chapel-${version}.tar.gz";
    hash = "sha256-GfBW7eFSm0/Yt6i9vTeNwbVaCTTUV9oQeCBml/ka4XQ=";
  };

  nativeBuildInputs = [ python3 which perl bash cmake ];
  buildInputs = [ gmp llvmPackages_18.llvm llvmPackages_18.clang ];

  # Chapel uses environment variables extensively for build configuration
  CHPL_LLVM = "system";
  CHPL_TASKS = "qthreads";
  CHPL_LOCALE_MODEL = "flat";
  CHPL_COMM = "none";
  CHPL_RE2 = "bundled";
  CHPL_GMP = "system";
  CHPL_HOST_COMPILER = "llvm";
  CHPL_TARGET_COMPILER = "llvm";

  preBuild = ''
    export CHPL_HOME=$PWD
    export CHPL_LLVM_CONFIG=${llvmPackages_18.llvm.dev}/bin/llvm-config
  '';

  buildPhase = ''
    runHook preBuild
    make -j$NIX_BUILD_CORES
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/{bin,lib,share/chapel}

    # Compiler and tools
    cp -r bin/linux64-* $out/bin/ 2>/dev/null || cp -r bin/* $out/bin/
    cp -r lib $out/

    # Runtime, modules, and standard libraries
    cp -r modules $out/share/chapel/
    cp -r runtime $out/share/chapel/ 2>/dev/null || true
    cp -r make $out/share/chapel/ 2>/dev/null || true
    cp -r util $out/share/chapel/ 2>/dev/null || true
    cp -r third-party $out/share/chapel/ 2>/dev/null || true

    # Mason package manager
    if [ -f tools/mason/mason ]; then
      cp tools/mason/mason $out/bin/
    fi

    runHook postInstall
  '';

  # Chapel needs CHPL_HOME at runtime to find modules/runtime
  postFixup = ''
    for f in $out/bin/*; do
      if [ -f "$f" ] && [ -x "$f" ]; then
        wrapProgram "$f" \
          --set CHPL_HOME "$out/share/chapel" \
          --prefix PATH : "${llvmPackages_18.clang}/bin" \
          2>/dev/null || true
      fi
    done
  '';

  meta = with lib; {
    description = "Chapel parallel programming language";
    homepage = "https://chapel-lang.org/";
    license = licenses.asl20;
    platforms = [ "x86_64-linux" ];
    maintainers = [];
  };
}
