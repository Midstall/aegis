{
  aegis-ip-tools,
  gf180mcu-pdk,
  sky130-pdk,
}:
{
  terra-1 = {
    ip = aegis-ip-tools.mkIp {
      deviceName = "terra_1";
      width = 48;
      height = 64;
      tracks = 4;
      serdesCount = 4;
      bramColumnInterval = 16;
      dspColumnInterval = 24;
      clockTileCount = 2;
    };
    tapeout = {
      pdk = sky130-pdk;
      clockPeriodNs = 20;
    };
  };
  luna-1 = {
    ip = aegis-ip-tools.mkIp {
      deviceName = "luna_1";
      width = 23;
      height = 23;
      tracks = 1;
      serdesCount = 0;
      bramColumnInterval = 7;
      dspColumnInterval = 8;
      clockTileCount = 1;
    };
    tapeout = {
      pdk = gf180mcu-pdk;
      clockPeriodNs = 20;
      dieWidthUm = 3930;
      dieHeightUm = 5120;
      fabSlot = "1x1";
      tileDieSizes = {
        Tile = {
          w = 100;
          h = 150;
        };
      };
    };
  };
}
