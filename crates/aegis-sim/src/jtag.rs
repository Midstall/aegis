//! Aegis JTAG TAP model + Spike-compatible remote_bitbang server.
//!
//! Mirrors `ip/lib/src/components/digital/jtag_tap.dart`: IR_WIDTH=4 with
//! IDCODE / CONFIG / BYPASS plus the 16-state IEEE 1149.1 TAP. The server
//! speaks the same byte protocol Spike exposes via `--rbb-port`, so OpenOCD's
//! `remote_bitbang` adapter driver treats the process as JTAG silicon.

use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};

// IEEE 1149.1 TAP states.
const TLR: u8 = 0;
const RTI: u8 = 1;
const SDR_S: u8 = 2;
const CDR: u8 = 3;
const SDR: u8 = 4;
const E1DR: u8 = 5;
const PDR: u8 = 6;
const E2DR: u8 = 7;
const UDR: u8 = 8;
const SIR_S: u8 = 9;
const CIR: u8 = 10;
const SIR: u8 = 11;
const E1IR: u8 = 12;
const PIR: u8 = 13;
const E2IR: u8 = 14;
const UIR: u8 = 15;

fn next_state(state: u8, tms: bool) -> u8 {
    match (state, tms) {
        (TLR, false) => RTI,
        (TLR, true) => TLR,
        (RTI, false) => RTI,
        (RTI, true) => SDR_S,
        (SDR_S, false) => CDR,
        (SDR_S, true) => SIR_S,
        (CDR, false) => SDR,
        (CDR, true) => E1DR,
        (SDR, false) => SDR,
        (SDR, true) => E1DR,
        (E1DR, false) => PDR,
        (E1DR, true) => UDR,
        (PDR, false) => PDR,
        (PDR, true) => E2DR,
        (E2DR, false) => SDR,
        (E2DR, true) => UDR,
        (UDR, false) => RTI,
        (UDR, true) => SDR_S,
        (SIR_S, false) => CIR,
        (SIR_S, true) => TLR,
        (CIR, false) => SIR,
        (CIR, true) => E1IR,
        (SIR, false) => SIR,
        (SIR, true) => E1IR,
        (E1IR, false) => PIR,
        (E1IR, true) => UIR,
        (PIR, false) => PIR,
        (PIR, true) => E2IR,
        (E2IR, false) => SIR,
        (E2IR, true) => UIR,
        (UIR, false) => RTI,
        (UIR, true) => SDR_S,
        _ => TLR,
    }
}

// Aegis IR opcodes per jtag_tap.dart.
const IR_WIDTH: u8 = 4;
const IR_EXTEST: u32 = 0x0;
const IR_IDCODE: u32 = 0x1;
const IR_CONFIG: u32 = 0x2;
const IR_USER: u32 = 0x3;
const IR_BYPASS: u32 = 0xF;

/// Per-connection TAP state. Public so external simulators can poke at it
/// directly, e.g. to wire a captured CONFIG bitstream into a `Simulator`.
pub struct Tap {
    state: u8,
    last_tck: bool,
    ir: u32,
    ir_shift: u32,
    idcode: u32,
    dr_shift: u64,
    config_bits: Vec<bool>,
    last_config: Option<Vec<bool>>,
    tdo: bool,
}

impl Tap {
    pub fn new(idcode: u32) -> Self {
        Self {
            state: TLR,
            last_tck: false,
            ir: IR_IDCODE,
            ir_shift: 0,
            idcode,
            dr_shift: 0,
            config_bits: Vec::new(),
            last_config: None,
            tdo: false,
        }
    }

    pub fn tdo(&self) -> bool {
        self.tdo
    }

    /// Take the most recently latched CONFIG bitstream (LSB-first bits in
    /// shift order). Cleared after read.
    pub fn take_last_config(&mut self) -> Option<Vec<bool>> {
        self.last_config.take()
    }

    pub fn trst(&mut self) {
        self.state = TLR;
        self.ir = IR_IDCODE;
        self.ir_shift = 0;
        self.dr_shift = 0;
        self.config_bits.clear();
        self.tdo = false;
    }

    fn ir_mask(&self) -> u32 {
        (1u32 << IR_WIDTH) - 1
    }

    fn capture_dr(&mut self) {
        match self.ir {
            IR_IDCODE => self.dr_shift = u64::from(self.idcode),
            IR_BYPASS | IR_EXTEST => self.dr_shift = 0,
            IR_CONFIG => self.config_bits.clear(),
            _ => self.dr_shift = 0,
        }
    }

    fn shift_dr_bit(&mut self, tdi: bool) {
        match self.ir {
            IR_IDCODE => {
                self.tdo = (self.dr_shift & 1) != 0;
                self.dr_shift >>= 1;
                if tdi {
                    self.dr_shift |= 1u64 << 31;
                }
            }
            IR_BYPASS | IR_EXTEST => {
                self.tdo = (self.dr_shift & 1) != 0;
                self.dr_shift = tdi as u64;
            }
            IR_CONFIG => {
                // cfgOut in the RTL is the per-section chain output; we
                // mirror TDI back so OpenOCD's drscan still sees a defined
                // return value.
                self.tdo = tdi;
                self.config_bits.push(tdi);
            }
            IR_USER => self.tdo = tdi,
            _ => self.tdo = tdi,
        }
    }

    fn update_dr(&mut self) {
        if self.ir == IR_CONFIG {
            self.last_config = Some(std::mem::take(&mut self.config_bits));
        }
    }

    fn capture_ir(&mut self) {
        // IEEE 1149.1 specifies the two LSBs of the captured IR shift
        // register to be `01` on entry to Capture-IR.
        self.ir_shift = 0x1 & self.ir_mask();
    }

    fn shift_ir_bit(&mut self, tdi: bool) {
        self.tdo = (self.ir_shift & 1) != 0;
        self.ir_shift >>= 1;
        if tdi {
            self.ir_shift |= 1u32 << (IR_WIDTH - 1);
        }
        self.ir_shift &= self.ir_mask();
    }

    fn update_ir(&mut self) {
        self.ir = self.ir_shift & self.ir_mask();
    }

    fn rising_edge(&mut self, tms: bool, tdi: bool) {
        // IEEE 1149.1: shifting happens while the TAP is *in* Shift-DR/IR,
        // so it must reference the current state. Update/Capture/Reset are
        // entry actions on the new state.
        match self.state {
            SDR => self.shift_dr_bit(tdi),
            SIR => self.shift_ir_bit(tdi),
            _ => {}
        }
        let next = next_state(self.state, tms);
        match next {
            TLR => self.trst(),
            CDR => self.capture_dr(),
            UDR => self.update_dr(),
            CIR => self.capture_ir(),
            UIR => self.update_ir(),
            _ => {}
        }
        self.state = next;
    }

    /// Process one remote_bitbang clock byte where lower 3 bits are
    /// (TCK, TMS, TDI). Edge-triggered on the rising TCK transition.
    pub fn step(&mut self, byte: u8) {
        let tck = (byte & 0b100) != 0;
        let tms = (byte & 0b010) != 0;
        let tdi = (byte & 0b001) != 0;
        if !self.last_tck && tck {
            self.rising_edge(tms, tdi);
        }
        self.last_tck = tck;
    }
}

/// Pack a bit vector LSB-first within each byte, matching how the JTAG
/// shift order maps to a host byte stream.
pub fn pack_bits_lsb_first(bits: &[bool]) -> Vec<u8> {
    let mut out = vec![0u8; bits.len().div_ceil(8)];
    for (i, &b) in bits.iter().enumerate() {
        if b {
            out[i / 8] |= 1 << (i % 8);
        }
    }
    out
}

/// Configuration for the remote_bitbang server.
pub struct RbbConfig {
    pub host: String,
    pub port: u16,
    pub idcode: u32,
    pub bitstream_out: Option<PathBuf>,
    pub once: bool,
}

/// Start a Spike-compatible remote_bitbang server. Accepts one client at a
/// time; on disconnect, either loops (default) or returns (`once`).
pub fn serve(cfg: &RbbConfig) -> std::io::Result<()> {
    let addr = format!("{}:{}", cfg.host, cfg.port);
    let listener = TcpListener::bind(&addr)?;
    eprintln!(
        "aegis-rbb listening on {addr} (idcode=0x{:08x})",
        cfg.idcode
    );
    loop {
        let (mut sock, peer) = listener.accept()?;
        eprintln!("aegis-rbb: accepted connection from {peer}");
        let mut tap = Tap::new(cfg.idcode);
        let result = serve_client(&mut sock, &mut tap, cfg.bitstream_out.as_deref());
        if let Err(e) = &result {
            eprintln!("aegis-rbb: client error: {e}");
        }
        eprintln!("aegis-rbb: client disconnected");
        if cfg.once {
            return Ok(());
        }
    }
}

fn serve_client(
    client: &mut TcpStream,
    tap: &mut Tap,
    bitstream_out: Option<&Path>,
) -> std::io::Result<()> {
    let mut buf = [0u8; 4096];
    loop {
        let n = client.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        let mut response: Vec<u8> = Vec::new();
        for &c in &buf[..n] {
            match c {
                b'0'..=b'7' => tap.step(c - b'0'),
                b'r' | b's' | b't' | b'u' => tap.trst(),
                b'R' => response.push(if tap.tdo() { b'1' } else { b'0' }),
                b'Q' => {
                    if !response.is_empty() {
                        client.write_all(&response)?;
                    }
                    return Ok(());
                }
                // LED/blink controls, ignored.
                b'B' | b'b' | b'O' | b'o' | b'd' => {}
                _ => {}
            }
        }
        if !response.is_empty() {
            client.write_all(&response)?;
        }
        if let (Some(path), Some(bits)) = (bitstream_out, tap.take_last_config()) {
            fs::write(path, pack_bits_lsb_first(&bits))?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Drive TMS bit-by-bit on rising clocks. Each entry is a TMS value; TDI=0.
    fn tms_seq(tap: &mut Tap, tms_bits: &[u8]) {
        for &t in tms_bits {
            let tms = t != 0;
            tap.step((tms as u8) << 1);
            tap.step(0b100 | (tms as u8) << 1);
        }
    }

    /// Shift `bits` of TDI through SDR or SIR. Returns TDO bits in order
    /// captured (one per shift cycle).
    fn shift(tap: &mut Tap, tdi_bits: &[bool]) -> Vec<bool> {
        let mut out = Vec::with_capacity(tdi_bits.len());
        for (i, &b) in tdi_bits.iter().enumerate() {
            let last = i + 1 == tdi_bits.len();
            let tms = (last as u8) << 1;
            let tdi = b as u8;
            tap.step(tms | tdi);
            tap.step(0b100 | tms | tdi);
            out.push(tap.tdo());
        }
        out
    }

    /// Walk from Test-Logic-Reset to Shift-DR.
    fn enter_shift_dr(tap: &mut Tap) {
        tms_seq(tap, &[0, 1, 0, 0]);
        assert_eq!(tap.state, SDR);
    }

    /// Walk from Test-Logic-Reset to Shift-IR.
    fn enter_shift_ir(tap: &mut Tap) {
        tms_seq(tap, &[0, 1, 1, 0, 0]);
        assert_eq!(tap.state, SIR);
    }

    /// Walk from Exit1-DR/IR back to Run-Test-Idle via Update.
    fn exit_to_rti(tap: &mut Tap) {
        tms_seq(tap, &[1, 0]);
        assert_eq!(tap.state, RTI);
    }

    #[test]
    fn idcode_shifts_out_lsb_first() {
        let mut tap = Tap::new(0xdead_beef);
        enter_shift_dr(&mut tap);
        let tdo = shift(&mut tap, &[false; 32]);
        let mut got: u32 = 0;
        for (i, b) in tdo.iter().enumerate() {
            if *b {
                got |= 1 << i;
            }
        }
        assert_eq!(got, 0xdead_beef);
    }

    #[test]
    fn config_shift_captures_bitstream() {
        let mut tap = Tap::new(1);
        enter_shift_ir(&mut tap);
        // 0b0010 LSB-first selects IR_CONFIG.
        let _ = shift(&mut tap, &[false, true, false, false]);
        exit_to_rti(&mut tap);
        assert_eq!(tap.ir, IR_CONFIG);

        enter_shift_dr(&mut tap);
        let payload: Vec<bool> = (0..17).map(|i| i % 3 == 0).collect();
        let _ = shift(&mut tap, &payload);
        exit_to_rti(&mut tap);

        let captured = tap
            .take_last_config()
            .expect("Update-DR should have latched CONFIG");
        assert_eq!(captured, payload);
    }

    #[test]
    fn pack_bits_packs_lsb_first() {
        let bits = [false, false, true, false, true, true, false, true];
        assert_eq!(pack_bits_lsb_first(&bits), vec![0xb4]);
    }

    #[test]
    fn pack_bits_pads_partial_byte() {
        let bits = [true, false, true, true, false];
        assert_eq!(pack_bits_lsb_first(&bits), vec![0b0000_1101]);
    }

    #[test]
    fn trst_resets_tap_and_ir() {
        let mut tap = Tap::new(7);
        enter_shift_ir(&mut tap);
        let _ = shift(&mut tap, &[true, true, true, true]);
        exit_to_rti(&mut tap);
        assert_eq!(tap.ir, IR_BYPASS);
        tap.trst();
        assert_eq!(tap.state, TLR);
        assert_eq!(tap.ir, IR_IDCODE);
    }
}
