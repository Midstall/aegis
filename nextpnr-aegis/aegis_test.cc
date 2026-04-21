/*
 *  Tests for the Aegis FPGA viaduct micro-architecture.
 *
 *  Verifies the routing graph: per-track output mux wires, pip
 *  connectivity, IO tile constraints, and input mux coverage.
 */

#include <set>
#include <string>
#include <vector>

#include "log.h"
#include "nextpnr.h"
#include "viaduct_api.h"
#include "gtest/gtest.h"

USING_NEXTPNR_NAMESPACE

// Small device for fast tests: 4x4 fabric, 4 tracks
static const int TEST_W = 4;
static const int TEST_H = 4;
static const int TEST_T = 4;

class AegisTest : public ::testing::Test {
protected:
  Context *ctx = nullptr;

  void SetUp() override {
    ArchArgs arch_args;
    ctx = new Context(arch_args);
    dict<std::string, std::string> vopts;
    vopts["device"] = std::to_string(TEST_W) + "x" + std::to_string(TEST_H) +
                      "t" + std::to_string(TEST_T);
    ctx->uarch = ViaductArch::create("aegis", vopts);
    ASSERT_NE(ctx->uarch, nullptr) << "Failed to create Aegis viaduct";
    ctx->uarch->init(ctx);
  }

  void TearDown() override { delete ctx; }

  // Grid dimensions including IO ring
  int gw() const { return TEST_W + 2; }
  int gh() const { return TEST_H + 2; }

  bool is_io(int x, int y) const {
    return x == 0 || x == gw() - 1 || y == 0 || y == gh() - 1;
  }

  // Find a BEL by name string "X{x}/Y{y}/name"
  BelId find_bel(const std::string &name) const {
    return ctx->getBelByName(IdStringList::parse(ctx, name));
  }

  // Find a wire by name string "X{x}/Y{y}/name"
  WireId find_wire(const std::string &name) const {
    auto id = ctx->getWireByName(IdStringList::parse(ctx, name));
    return id;
  }

  // Find a pip by destination and source wire names
  PipId find_pip(const std::string &dst, const std::string &src) const {
    WireId dw = find_wire(dst);
    WireId sw = find_wire(src);
    if (dw == WireId() || sw == WireId())
      return PipId();
    for (auto pip : ctx->getPipsDownhill(sw)) {
      if (ctx->getPipDstWire(pip) == dw)
        return pip;
    }
    return PipId();
  }

  // Count downhill pips from a wire
  int count_downhill(const std::string &wire) const {
    WireId w = find_wire(wire);
    if (w == WireId())
      return -1;
    int count = 0;
    for (auto pip : ctx->getPipsDownhill(w)) {
      (void)pip;
      count++;
    }
    return count;
  }

  // Count uphill pips to a wire
  int count_uphill(const std::string &wire) const {
    WireId w = find_wire(wire);
    if (w == WireId())
      return -1;
    int count = 0;
    for (auto pip : ctx->getPipsUphill(w)) {
      (void)pip;
      count++;
    }
    return count;
  }

  // Collect all wire names at a tile location
  std::set<std::string> wires_at(int x, int y) const {
    std::set<std::string> result;
    for (auto wire : ctx->getWires()) {
      auto loc = ctx->getWireName(wire);
      auto str = loc.str(ctx);
      auto prefix = "X" + std::to_string(x) + "/Y" + std::to_string(y) + "/";
      if (str.find(prefix) == 0)
        result.insert(str);
    }
    return result;
  }
};

// === Wire existence tests ===

TEST_F(AegisTest, FabricTileHasPerTrackOutputMuxWires) {
  // Logic tile at (1,1) should have OUT_N0..OUT_N3, OUT_E0..OUT_E3, etc.
  const char *dirs[] = {"N", "E", "S", "W"};
  for (auto dir : dirs) {
    for (int t = 0; t < TEST_T; t++) {
      auto name = "X1/Y1/OUT_" + std::string(dir) + std::to_string(t);
      EXPECT_NE(find_wire(name), WireId())
          << "Missing output mux wire: " << name;
    }
  }
}

TEST_F(AegisTest, PerTrackOutputMuxWiresAreIndependent) {
  // Each OUT_N{t} should be a distinct wire
  std::set<WireId> wires;
  for (int t = 0; t < TEST_T; t++) {
    auto w = find_wire("X1/Y1/OUT_N" + std::to_string(t));
    ASSERT_NE(w, WireId());
    EXPECT_TRUE(wires.insert(w).second)
        << "OUT_N" << t << " is not a distinct wire";
  }
}

TEST_F(AegisTest, FabricTileHasTrackWires) {
  const char *dirs[] = {"N", "E", "S", "W"};
  for (auto dir : dirs) {
    for (int t = 0; t < TEST_T; t++) {
      auto name = "X2/Y2/" + std::string(dir) + std::to_string(t);
      EXPECT_NE(find_wire(name), WireId()) << "Missing track wire: " << name;
    }
  }
}

TEST_F(AegisTest, FabricTileHasCLBWires) {
  EXPECT_NE(find_wire("X1/Y1/CLB_O"), WireId());
  EXPECT_NE(find_wire("X1/Y1/CLB_Q"), WireId());
  EXPECT_NE(find_wire("X1/Y1/CLK"), WireId());
  for (int i = 0; i < 4; i++) {
    EXPECT_NE(find_wire("X1/Y1/CLB_I" + std::to_string(i)), WireId());
  }
}

TEST_F(AegisTest, IOTileHasNoOutputMuxWires) {
  // IO tiles should NOT have OUT_* wires
  auto wires = wires_at(0, 1);
  for (auto &w : wires) {
    EXPECT_EQ(w.find("OUT_"), std::string::npos)
        << "IO tile has output mux wire: " << w;
  }
}

TEST_F(AegisTest, IOTileHasTrackWires) {
  // IO tiles still have routing tracks
  EXPECT_NE(find_wire("X0/Y1/N0"), WireId());
  EXPECT_NE(find_wire("X0/Y1/E0"), WireId());
}

TEST_F(AegisTest, IOTileHasPadWires) {
  EXPECT_NE(find_wire("X0/Y1/PAD0"), WireId());
  EXPECT_NE(find_wire("X0/Y1/IO_I0"), WireId());
  EXPECT_NE(find_wire("X0/Y1/IO_O0"), WireId());
}

// === Output mux pip tests ===

TEST_F(AegisTest, CLBOutputDrivesAllPerTrackMuxes) {
  // CLB_O and CLB_Q should have pips to every OUT_*{t}
  const char *dirs[] = {"N", "E", "S", "W"};
  for (auto dir : dirs) {
    for (int t = 0; t < TEST_T; t++) {
      auto dst = "X1/Y1/OUT_" + std::string(dir) + std::to_string(t);
      EXPECT_NE(find_pip(dst, "X1/Y1/CLB_O"), PipId())
          << "Missing pip: CLB_O -> " << dst;
      EXPECT_NE(find_pip(dst, "X1/Y1/CLB_Q"), PipId())
          << "Missing pip: CLB_Q -> " << dst;
    }
  }
}

TEST_F(AegisTest, PassThroughPipsUseSameTrackIndex) {
  // OUT_N{t} should have pips from all 4 directions at same track index
  for (int t = 0; t < TEST_T; t++) {
    auto dst = "X2/Y2/OUT_N" + std::to_string(t);
    const char *dirs[] = {"N", "E", "S", "W"};
    for (auto dir : dirs) {
      EXPECT_NE(find_pip(dst, "X2/Y2/" + std::string(dir) + std::to_string(t)),
                PipId())
          << "Missing pass-through pip: " << dir << t << " -> OUT_N" << t;
    }
  }
}

TEST_F(AegisTest, PassThroughDoesNotCrossTrackIndices) {
  // OUT_N0 should NOT have a pip from E1 (different track index)
  EXPECT_EQ(find_pip("X2/Y2/OUT_N0", "X2/Y2/E1"), PipId())
      << "Cross-track pass-through should not exist";
  EXPECT_EQ(find_pip("X2/Y2/OUT_N0", "X2/Y2/S3"), PipId())
      << "Cross-track pass-through should not exist";
}

TEST_F(AegisTest, OutputMuxDrivesInterTileDirectly) {
  // OUT_N{t} should drive the neighboring tile's S{t} via inter-tile pip,
  // not the local N{t} track (which is input-only).
  for (int t = 0; t < TEST_T; t++) {
    auto src = "X2/Y2/OUT_N" + std::to_string(t);
    // Should NOT drive local track (input/output are separated)
    auto local_dst = "X2/Y2/N" + std::to_string(t);
    EXPECT_EQ(find_pip(local_dst, src), PipId())
        << "OUT_N" << t << " should not drive local N" << t;
    // Should drive neighbor's track via inter-tile
    auto nb_dst = "X2/Y1/S" + std::to_string(t);
    EXPECT_NE(find_pip(nb_dst, src), PipId())
        << "OUT_N" << t << " should drive neighbor's S" << t;
  }
}

TEST_F(AegisTest, OutputMuxSourceCount) {
  // Each per-track output mux wire should have exactly 6 uphill pips:
  // CLB_O, CLB_Q, and 4 pass-through from all directions
  for (int t = 0; t < TEST_T; t++) {
    auto wire = "X2/Y2/OUT_N" + std::to_string(t);
    EXPECT_EQ(count_uphill(wire), 6)
        << "OUT_N" << t << " should have 6 sources (CLB_O, CLB_Q, N, E, S, W)";
  }
}

// === Input mux pip tests ===

TEST_F(AegisTest, InputMuxReadsFromAllTracksAllDirections) {
  // Each CLB_I{n} should have pips from every track of every direction
  for (int i = 0; i < 4; i++) {
    auto dst = "X2/Y2/CLB_I" + std::to_string(i);
    const char *dirs[] = {"N", "E", "S", "W"};
    for (auto dir : dirs) {
      for (int t = 0; t < TEST_T; t++) {
        auto src = "X2/Y2/" + std::string(dir) + std::to_string(t);
        EXPECT_NE(find_pip(dst, src), PipId())
            << "Missing input pip: " << src << " -> " << dst;
      }
    }
  }
}

TEST_F(AegisTest, InputMuxHasCLBFeedback) {
  for (int i = 0; i < 4; i++) {
    auto dst = "X2/Y2/CLB_I" + std::to_string(i);
    EXPECT_NE(find_pip(dst, "X2/Y2/CLB_O"), PipId())
        << "Missing CLB_O feedback to CLB_I" << i;
    EXPECT_NE(find_pip(dst, "X2/Y2/CLB_Q"), PipId())
        << "Missing CLB_Q feedback to CLB_I" << i;
  }
}

TEST_F(AegisTest, InputMuxTotalSources) {
  // Each CLB_I should have 4*T + 2 + 8 uphill pips (4 dirs * T tracks +
  // CLB_O + CLB_Q + 4 neighbor lut_out + 4 neighbor ff_q)
  int expected = 4 * TEST_T + 2 + 8;
  for (int i = 0; i < 4; i++) {
    auto wire = "X2/Y2/CLB_I" + std::to_string(i);
    EXPECT_EQ(count_uphill(wire), expected)
        << "CLB_I" << i << " should have " << expected << " sources";
  }
}

// === Clock wire tests ===

TEST_F(AegisTest, ClockWireDrivenByAllTracks) {
  // CLK wire should have pips from every track of every direction
  int expected = 4 * TEST_T;
  EXPECT_EQ(count_uphill("X2/Y2/CLK"), expected)
      << "CLK should be driven by all " << expected << " tracks";
}

// === Inter-tile pip tests ===

TEST_F(AegisTest, Span1InterTilePips) {
  // OUT_N0 at (2,2) should drive S0 at (2,1) (span-1 northward)
  EXPECT_NE(find_pip("X2/Y1/S0", "X2/Y2/OUT_N0"), PipId())
      << "Missing span-1 inter-tile pip northward";
  // OUT_E0 at (2,2) should drive W0 at (3,2) (span-1 eastward)
  EXPECT_NE(find_pip("X3/Y2/W0", "X2/Y2/OUT_E0"), PipId())
      << "Missing span-1 inter-tile pip eastward";
}

TEST_F(AegisTest, Span2InterTilePips) {
  // OUT_N0 at (2,3) should drive S0 at (2,1) (span-2 northward)
  EXPECT_NE(find_pip("X2/Y1/S0", "X2/Y3/OUT_N0"), PipId())
      << "Missing span-2 inter-tile pip northward";
}

TEST_F(AegisTest, Span4InterTilePips) {
  // OUT_S0 at (2,1) should drive N0 at (2,5) (span-4 southward)
  // y=1 + 4 = 5, which is within the grid (gh=6)
  EXPECT_NE(find_pip("X2/Y5/N0", "X2/Y1/OUT_S0"), PipId())
      << "Missing span-4 inter-tile pip southward";
}

TEST_F(AegisTest, InterTilePipsPreserveTrackIndex) {
  // OUT_N2 at (2,2) should drive S2 at (2,1), not S0
  EXPECT_NE(find_pip("X2/Y1/S2", "X2/Y2/OUT_N2"), PipId())
      << "Inter-tile pip should preserve track index";
  EXPECT_EQ(find_pip("X2/Y1/S0", "X2/Y2/OUT_N2"), PipId())
      << "Inter-tile pip should not cross track indices";
}

// === IO tile constraint tests ===

TEST_F(AegisTest, IOTileSpan1Only) {
  // IO tile at (0,1): should have span-1 inter-tile pips
  // IO tiles use track wires directly (no output mux)
  EXPECT_NE(find_pip("X1/Y1/W0", "X0/Y1/E0"), PipId())
      << "IO tile should have span-1 eastward pip";

  // IO tile at (0,3): should NOT have span-2 inter-tile pips
  // E0 at (0,3) -> W0 at (2,3) would be span-2
  EXPECT_EQ(find_pip("X2/Y3/W0", "X0/Y3/E0"), PipId())
      << "IO tile should not have span-2 inter-tile pips";
}

TEST_F(AegisTest, IOTileNoPassThroughPips) {
  // IO tiles should not have intra-tile track-to-track pass-through pips
  // (no S0 -> E0 within an IO tile)
  EXPECT_EQ(find_pip("X0/Y1/E0", "X0/Y1/S0"), PipId())
      << "IO tile should not have pass-through pips";
  EXPECT_EQ(find_pip("X0/Y1/N0", "X0/Y1/W0"), PipId())
      << "IO tile should not have pass-through pips";
}

TEST_F(AegisTest, IOTileIOPadsConnectToTracks) {
  // IO_O0 should drive all tracks in all directions
  int downhill = count_downhill("X0/Y1/IO_O0");
  EXPECT_EQ(downhill, 4 * TEST_T)
      << "IO output should drive all " << 4 * TEST_T << " tracks";

  // All tracks should drive IO_I0
  auto dst = "X0/Y1/IO_I0";
  const char *dirs[] = {"N", "E", "S", "W"};
  for (auto dir : dirs) {
    for (int t = 0; t < TEST_T; t++) {
      auto src = "X0/Y1/" + std::string(dir) + std::to_string(t);
      EXPECT_NE(find_pip(dst, src), PipId())
          << "Missing IO input pip: " << src << " -> " << dst;
    }
  }
}

// === BEL tests ===

TEST_F(AegisTest, FabricTileHasLUTAndDFFBels) {
  auto lut = ctx->getBelByName(IdStringList::parse(ctx, "X1/Y1/SLICE0_LUT"));
  auto dff = ctx->getBelByName(IdStringList::parse(ctx, "X1/Y1/SLICE0_FF"));
  EXPECT_NE(lut, BelId()) << "Missing LUT BEL at fabric tile";
  EXPECT_NE(dff, BelId()) << "Missing DFF BEL at fabric tile";
}

TEST_F(AegisTest, IOTileHasIOBels) {
  auto io0 = ctx->getBelByName(IdStringList::parse(ctx, "X0/Y1/IO0"));
  auto io1 = ctx->getBelByName(IdStringList::parse(ctx, "X0/Y1/IO1"));
  EXPECT_NE(io0, BelId()) << "Missing IO0 BEL";
  EXPECT_NE(io1, BelId()) << "Missing IO1 BEL";
}

TEST_F(AegisTest, CornerTilesHaveNoBelsExceptJtag) {
  // Corner (0,0) has the JTAG BEL; other corners have nothing
  auto w00 = wires_at(0, 0);
  EXPECT_FALSE(w00.empty()) << "Corner (0,0) should have JTAG wires";

  // Verify the JTAG BEL exists
  auto jtag_bel = find_bel("X0/Y0/JTAG0");
  EXPECT_NE(jtag_bel, BelId()) << "JTAG BEL should exist at (0,0)";

  // Other corners should still be empty
  int gw_val = gw(), gh_val = gh();
  auto w_tr = wires_at(gw_val - 1, 0);
  EXPECT_TRUE(w_tr.empty()) << "Corner (W-1,0) should have no wires";
  auto w_bl = wires_at(0, gh_val - 1);
  EXPECT_TRUE(w_bl.empty()) << "Corner (0,H-1) should have no wires";
  auto w_br = wires_at(gw_val - 1, gh_val - 1);
  EXPECT_TRUE(w_br.empty()) << "Corner (W-1,H-1) should have no wires";
}

// === Completeness tests ===

TEST_F(AegisTest, AllFabricTilesHaveOutputMuxWires) {
  for (int x = 1; x < gw() - 1; x++) {
    for (int y = 1; y < gh() - 1; y++) {
      auto wire =
          "X" + std::to_string(x) + "/Y" + std::to_string(y) + "/OUT_N0";
      EXPECT_NE(find_wire(wire), WireId())
          << "Missing OUT_N0 at fabric tile (" << x << "," << y << ")";
    }
  }
}

TEST_F(AegisTest, NoFabricTilesMissing) {
  int fabric_tiles = 0;
  for (int x = 1; x < gw() - 1; x++) {
    for (int y = 1; y < gh() - 1; y++) {
      auto wire = "X" + std::to_string(x) + "/Y" + std::to_string(y) + "/CLB_O";
      if (find_wire(wire) != WireId())
        fabric_tiles++;
    }
  }
  EXPECT_EQ(fabric_tiles, TEST_W * TEST_H);
}
