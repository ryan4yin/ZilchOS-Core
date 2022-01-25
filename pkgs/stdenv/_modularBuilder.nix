{ envname ? "stdenv", mkCaDerivation, musl, clang, busybox, patchelf }:

let
  phaseNames = [
    "preUnpack"     "unpackPhase"     "postUnpack"
    "prePatch"      "patchPhase"      "postPatch"
    "preConfigure"  "configurePhase"  "postConfigure"
    "preBuild"      "buildPhase"      "postBuild"
    "preInstall"    "installPhase"    "postInstall"
    "preFixup"      "fixupPhase"      "postFixup"
  ];

  _buildScript = ''
    set -ue

    : ''${outputs:=out}
    export outputs

    eval "$_nprocSetup"
    eval "$_pathSetup"
    eval "$_ccacheSetup"

    set +u
  '' + (builtins.concatStringsSep "\n\n" (map (phaseName: ''
    if [ -e "''${${phaseName}Path}" ]; then
      echo "${phaseName}:"
      ${busybox}/bin/ash -uex "''${${phaseName}Path}"
      echo "${phaseName}: exit code $?"
    fi
  '') phaseNames ));

  writeFile = { name, contents }: mkCaDerivation {
    inherit name contents;
    passAsFile = [ "contents" ];
    builder = "${busybox}/bin/ash";
    args = [ "-c" "${busybox}/bin/cat $contentsPath >$out" ];
  };

  _buildScriptFile = writeFile { name = "stdenv"; contents = _buildScript; };

  _mkMkDerivation = bakedInBuiltInputs:
    { pname, version
    , builder ? "${busybox}/bin/ash"
    , buildInputs ? [], passthru ? {}
    , src ? null, patches ? []
    , extraPatchFlags ? [ "-p1" ]
    , extraConfigureFlags ? []
    , extraBuildFlags ? []
    , ... }@args:
    (mkCaDerivation ( rec {
      name = "${pname}-${version}";
      inherit builder;
      args = [ _buildScriptFile ];

      passAsFile = phaseNames;

      _nprocSetup = ''
        if [ -n "$NIX_BUILD_CORES" ] && [ "$NIX_BUILD_CORES" != 0 ]; then
          export NPROC=$NIX_BUILD_CORES
        elif [ "$NIX_BUILD_CORES" == 0 ] && [ -r /proc/cpuinfo ]; then
          export NPROC=$(${busybox}/bin/grep -c processor /proc/cpuinfo)
        else
          export NPROC=1
        fi
      '';

      _pathSetup = ''
        export PATH=${builtins.concatStringsSep ":" (
          map (x: "${x}/bin") (buildInputs ++ bakedInBuiltInputs)
        )}
      '';

      # for building as part of bootstrap-from-tcc with USE_CCACHE=1
      _ccacheSetup = ''
          if [ -e /ccache/setup ]; then
            . /ccache/setup ZilchOS/core/${pname}
          fi
      '';

      patchFlags = [ "-p1" ] ++ extraConfigureFlags;
      configureFlags = [ "--prefix=$out" ] ++ extraConfigureFlags;
      buildFlags = [ "-j" "$NPROC" ] ++ extraBuildFlags;

      unpackPhase = "${busybox}/bin/tar --strip-components=1 -xf ${src}";
      patchPhase = builtins.concatStringsSep "\n" (map (patch:
        "${busybox}/bin/patch ${builtins.toString patchFlags} < ${patch}"
      ) patches);
      configurePhase = "./configure ${builtins.toString configureFlags}";
      buildPhase = "make -j $NPROC ${builtins.toString buildFlags}";
      installPhase = "make install";
      fixupPhase = ''
        for output in $outputs; do
          opath=$(eval "echo $"$output"")
          if [ -e $opath/lib ]; then
            find $opath/lib -type f -name '*.a' -exec \
              sh -c '${clang}/bin/strip {} || true' +
            find $opath/lib -type f -name '*.so' -exec \
              sh -c '${clang}/bin/strip {} || true' +
          fi
          if [ -e $opath/bin ]; then
            find $opath/bin -type f -exec \
              sh -c '${clang}/bin/strip {} || true' +
          fi
        done
      '';

    } // args )) // { inherit src; } // passthru;

    stdenvBase = writeFile { name = envname; contents = ""; };
in
  stdenvBase // {
    inherit writeFile musl clang busybox patchelf;
    mkDerivation = _mkMkDerivation [ busybox clang ];
    mkDerivationNoCC = _mkMkDerivation [ busybox ];
  }
