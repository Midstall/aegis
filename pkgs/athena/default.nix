{
  lib,
  stdenv,
  callPackage,
  craneLib,
  mkShell,
  flakever,
  pkg-config,
  vulkan-loader,
  wayland,
  libxkbcommon,
  libx11,
  libxcursor,
  libxrandr,
  libxi,
  libGL,
  darwin,
  libiconv,
  makeWrapper,
  yosys,
  nextpnr-aegis,
  enableCosmic ? false,
  dataPacks ? [ ],
}:

let
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../crates
      ../../ip/data/descriptor.schema.json
    ];
  };

  nativeBuildInputsLinux = lib.optionals stdenv.isLinux [
    pkg-config
  ];

  buildInputsLinux = lib.optionals stdenv.isLinux [
    vulkan-loader
    wayland
    libxkbcommon
    libx11
    libxcursor
    libxrandr
    libxi
    libGL
  ];

  buildInputsDarwin = lib.optionals stdenv.isDarwin [
    darwin.apple_sdk.frameworks.Metal
    darwin.apple_sdk.frameworks.AppKit
    darwin.apple_sdk.frameworks.QuartzCore
    darwin.apple_sdk.frameworks.CoreGraphics
    libiconv
  ];

  runtimeLibPath = lib.makeLibraryPath buildInputsLinux;

  cargoFeatures = lib.optionalString enableCosmic "--features cosmic";

  commonArgs = {
    inherit src;
    pname = "athena";
    strictDeps = true;
    cargoExtraArgs = "--package athena ${cargoFeatures}";

    nativeBuildInputs = nativeBuildInputsLinux;
    buildInputs = buildInputsLinux ++ buildInputsDarwin;
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;

  shell = craneLib.devShell {
    name = "athena-dev-shell";

    inputsFrom = [ (craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; })) ];

    LD_LIBRARY_PATH = lib.optionalString stdenv.isLinux (lib.makeLibraryPath buildInputsLinux);
  };
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;

    # Work around rustc ICE on aarch64 with opt-level=3 + typify proc macro
    CARGO_PROFILE_RELEASE_OPT_LEVEL = "2";

    nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ makeWrapper ];

    postInstall = lib.optionalString (dataPacks != [ ]) ''
      mkdir -p $out/share/athena/data-packs
      ${lib.concatMapStringsSep "\n" (pack: ''
        for f in ${pack}/*.json ${pack}/*.tcl ${pack}/*.v ${pack}/*.rules; do
          [ -f "$f" ] && install -Dm644 "$f" $out/share/athena/data-packs/
        done
      '') dataPacks}
    '';

    postFixup = ''
      ${lib.optionalString stdenv.isLinux ''
        patchelf --add-rpath "${runtimeLibPath}" $out/bin/athena
      ''}
      wrapProgram $out/bin/athena \
        --prefix PATH : ${
          lib.makeBinPath [
            yosys
            nextpnr-aegis
          ]
        }
    '';

    passthru = {
      inherit shell src;
      deb = callPackage ./deb.nix {
        athena = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
            CARGO_PROFILE_RELEASE_OPT_LEVEL = "2";
          }
        );
        inherit flakever;
      };
    };

    meta = {
      description = "Graphical EDA IDE for Aegis FPGAs";
      mainProgram = "athena";
    };
  }
)
