{
  lib,
  callPackage,
  flakever,
  mkShell,
  buildDartApplication,
  yq,
  dart,
}:
let
  shell = mkShell {
    name = "aegis-ip-tools-dev-shell";

    packages = [
      dart
      yq
    ];
  };

  schemaFile = ../../crates/aegis-ip/descriptor.schema.json;
in
buildDartApplication (finalAttrs: {
  pname = "aegis-ip-tools";
  inherit (flakever) version;

  src = lib.fileset.toSource {
    root = ../../ip;
    fileset = lib.fileset.unions [
      ../../ip/bin
      ../../ip/data
      ../../ip/lib
      ../../ip/test
      ../../ip/pubspec.lock
      ../../ip/pubspec.yaml
    ];
  };

  pubspecLock = lib.importJSON ../../ip/pubspec.lock.json;

  dartEntryPoints = {
    "bin/aegis-genip" = "bin/aegis_genip.dart";
    "bin/aegis-sim" = "bin/aegis_sim.dart";
  };

  postUnpack = ''
    rm -f "$sourceRoot/data/descriptor.schema.json"
    install -Dm0644 ${schemaFile} "$sourceRoot/data/descriptor.schema.json"
  '';

  doCheck = true;

  checkPhase = ''
    runHook preCheck
    packageRun test -r expanded
    runHook postCheck
  '';

  postInstall = ''
    install -Dm0644 ${schemaFile} $out/share/aegis-ip/descriptor.schema.json
  '';

  passthru = {
    inherit shell;
    mkIp = callPackage ../aegis-ip { aegis-ip-tools = finalAttrs.finalPackage; };
  };
})
