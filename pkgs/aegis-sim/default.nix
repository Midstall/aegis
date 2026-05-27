{
  lib,
  craneLib,
}:

let
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../crates
    ];
  };

  commonArgs = {
    inherit src;
    pname = "aegis-sim";
    strictDeps = true;
    cargoExtraArgs = "--package aegis-sim";
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
craneLib.buildPackage (
  commonArgs
  // {
    inherit cargoArtifacts;

    # Work around rustc ICE on aarch64 with opt-level=3 + typify proc macro
    CARGO_PROFILE_RELEASE_OPT_LEVEL = "2";

    meta = {
      description = "Fast cycle-accurate simulator for Aegis FPGA";
      mainProgram = "aegis-sim";
    };
  }
)
