{
  lib,
  stdenvNoCC,
  dpkg,
  patchelf,
  removeReferencesTo,
  athena,
  flakever,
}:

let
  system = stdenvNoCC.hostPlatform.system;

  archMap = {
    "x86_64-linux" = {
      deb = "amd64";
      interpreter = "/lib64/ld-linux-x86-64.so.2";
      libDir = "/usr/lib/x86_64-linux-gnu";
    };
    "aarch64-linux" = {
      deb = "arm64";
      interpreter = "/lib/ld-linux-aarch64.so.1";
      libDir = "/usr/lib/aarch64-linux-gnu";
    };
  };

  arch = archMap.${system};

  version = flakever.version;
in

stdenvNoCC.mkDerivation {
  pname = "athena-deb";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [
    dpkg
    patchelf
    removeReferencesTo
  ];

  allowedReferences = [ ];

  buildPhase = ''
    runHook preBuild

    pkg=$TMPDIR/pkg
    mkdir -p $pkg/DEBIAN
    mkdir -p $pkg/usr/bin
    mkdir -p $pkg/usr/share/applications
    mkdir -p $pkg/usr/share/metainfo

    # DEBIAN/control
    cat > $pkg/DEBIAN/control <<CONTROL
    Package: athena
    Version: ${version}
    Architecture: ${arch.deb}
    Maintainer: Midstall <info@midstall.com>
    Description: Graphical EDA IDE for Aegis FPGAs
     Athena is a graphical electronic design automation IDE for designing
     on Aegis FPGAs. Provides synthesis, place-and-route, simulation, and
     floorplan visualization in a single integrated environment.
    Depends: libc6, libvulkan1, libwayland-client0, libxkbcommon0, libgl1, aegis-terra-1
    Priority: optional
    Section: electronics
    CONTROL

    # Strip leading whitespace from control file (heredoc indentation)
    sed -i 's/^    //' $pkg/DEBIAN/control

    # Patch and install the binary
    cp ${athena}/bin/athena $pkg/usr/bin/athena
    chmod u+w $pkg/usr/bin/athena
    patchelf --set-interpreter ${arch.interpreter} $pkg/usr/bin/athena
    patchelf --set-rpath ${arch.libDir} $pkg/usr/bin/athena
    remove-references-to -t ${athena} $pkg/usr/bin/athena

    # Install desktop entry and metainfo
    cp ${./flatpak/com.midstall.athena.desktop} $pkg/usr/share/applications/
    cp ${./flatpak/com.midstall.athena.metainfo.xml} $pkg/usr/share/metainfo/

    # Build the .deb
    dpkg-deb --build $pkg $TMPDIR/athena_${version}_${arch.deb}.deb

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp $TMPDIR/athena_${version}_${arch.deb}.deb $out
    runHook postInstall
  '';
}
