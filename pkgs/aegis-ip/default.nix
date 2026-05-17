{
  lib,
  callPackage,
  stdenvNoCC,
  dockerTools,
  bashInteractive,
  coreutils,
  mkShell,
  makeWrapper,
  yosys,
  surfer,
  nextpnr-aegis,
  aegis-ip-tools,
  aegis-pack,
  aegis-sim,
}:

lib.extendMkDerivation {
  constructDrv = stdenvNoCC.mkDerivation;

  excludeDrvArgNames = [
    "deviceName"
    "width"
    "height"
    "tracks"
    "serdesCount"
    "bramColumnInterval"
    "dspColumnInterval"
    "clockTileCount"
    "configClk"
    "configDataWidth"
    "configAddressWidth"
    "enableJtag"
  ];

  extendDrvArgs =
    finalAttrs:
    {
      name ? "aegis-ip-${deviceName}",
      deviceName ? "aegis_fpga",
      width ? 1,
      height ? 1,
      tracks ? 1,
      serdesCount ? 4,
      bramColumnInterval ? 0,
      dspColumnInterval ? 0,
      clockTileCount ? 1,
      configClk ? false,
      configDataWidth ? 8,
      configAddressWidth ? 8,
      enableJtag ? false,
      ...
    }@args:

    assert lib.assertMsg (width >= 1) "aegis-ip: width must be >= 1, got ${toString width}";
    assert lib.assertMsg (height >= 1) "aegis-ip: height must be >= 1, got ${toString height}";
    assert lib.assertMsg (tracks >= 1) "aegis-ip: tracks must be >= 1, got ${toString tracks}";
    assert lib.assertMsg (
      serdesCount >= 0
    ) "aegis-ip: serdesCount must be >= 0, got ${toString serdesCount}";
    assert lib.assertMsg (
      bramColumnInterval >= 0
    ) "aegis-ip: bramColumnInterval must be >= 0, got ${toString bramColumnInterval}";
    assert lib.assertMsg (
      clockTileCount >= 0
    ) "aegis-ip: clockTileCount must be >= 0, got ${toString clockTileCount}";
    assert lib.assertMsg (
      configDataWidth >= 1
    ) "aegis-ip: configDataWidth must be >= 1, got ${toString configDataWidth}";
    assert lib.assertMsg (
      configAddressWidth >= 1
    ) "aegis-ip: configAddressWidth must be >= 1, got ${toString configAddressWidth}";
    assert lib.assertMsg (bramColumnInterval == 0 || bramColumnInterval <= width)
      "aegis-ip: bramColumnInterval (${toString bramColumnInterval}) must not exceed width (${toString width})";

    let
      cliArgs = lib.cli.toCommandLineShellGNU { } {
        name = deviceName;
        inherit width height tracks;
        serdes = serdesCount;
        bram-interval = bramColumnInterval;
        dsp-interval = dspColumnInterval;
        clock-tiles = clockTileCount;
        config-clk = configClk;
        config-data-width = configDataWidth;
        config-address-width = configAddressWidth;
        jtag = enableJtag;
      };
    in
    builtins.removeAttrs args [
      "deviceName"
      "width"
      "height"
      "tracks"
      "serdesCount"
      "bramColumnInterval"
      "dspColumnInterval"
      "clockTileCount"
      "configClk"
      "configDataWidth"
      "configAddressWidth"
      "enableJtag"
    ]
    // {
      inherit name;

      outputs = [
        "out"
        "tools"
      ];

      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
        aegis-ip-tools
        makeWrapper
        nextpnr-aegis
      ];

      buildPhase = ''
        runHook preBuild
        aegis-genip ${cliArgs} --output "$out" --symbol-path "${aegis-ip-tools}/share/aegis-ip"
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        # Create device-specific wrapped tools
        mkdir -p $tools/bin

        # Rust simulator: fast cycle-accurate simulation
        makeWrapper ${aegis-sim}/bin/aegis-sim $tools/bin/${deviceName}-sim \
          --add-flags "--descriptor $out/${deviceName}.json"

        # nextpnr wrapper: aegis viaduct uarch with device dimensions
        makeWrapper ${nextpnr-aegis}/bin/nextpnr-generic $tools/bin/nextpnr-aegis-${deviceName} \
          --add-flags "--uarch aegis -o device=${toString width}x${toString height}t${toString tracks}"

        # bitstream packer wrapper: pre-loads the descriptor for this device
        makeWrapper ${aegis-pack}/bin/aegis-pack $tools/bin/${deviceName}-pack \
          --add-flags "--descriptor $out/${deviceName}.json"

        # Install EDA support files for targeting this device
        mkdir -p $tools/share/yosys/aegis
        cp $out/${deviceName}_cells.v $tools/share/yosys/aegis/
        cp $out/${deviceName}_techmap.v $tools/share/yosys/aegis/
        cp $out/${deviceName}_bram.rules $tools/share/yosys/aegis/ 2>/dev/null || true
        cp $out/${deviceName}-synth-aegis.tcl $tools/share/yosys/aegis/

        runHook postInstall
      '';

      passthru = {
        inherit
          deviceName
          width
          height
          tracks
          serdesCount
          bramColumnInterval
          dspColumnInterval
          clockTileCount
          configClk
          configDataWidth
          configAddressWidth
          enableJtag
          ;
        mkTapeout = callPackage ../aegis-tapeout { aegis-ip = finalAttrs.finalPackage; };
        mkTapeoutLr = callPackage ../aegis-tapeout-lr {
          aegis-ip = finalAttrs.finalPackage;
        };
        shell = mkShell {
          name = "aegis-${deviceName}-shell";
          packages = [
            aegis-ip-tools
            aegis-pack
            aegis-sim
            nextpnr-aegis
            yosys
            surfer
          ];
        };
        deb = callPackage ./deb.nix { aegis-ip = finalAttrs.finalPackage; };
        docker = dockerTools.buildLayeredImage {
          name = "aegis-${deviceName}";
          tag = "latest";
          contents = [
            bashInteractive
            coreutils
            yosys
            aegis-ip-tools
            aegis-pack
            aegis-sim
            nextpnr-aegis
            finalAttrs.finalPackage
            finalAttrs.finalPackage.tools
          ];
          config = {
            Env = [
              "AEGIS_DEVICE_DIR=${finalAttrs.finalPackage}"
            ];
            Cmd = [ "/bin/bash" ];
            WorkingDir = "/workspace";
            Volumes = {
              "/workspace" = { };
            };
          };
        };
      }
      // (args.passthru or { });

    };
}
