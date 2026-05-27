use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

use clap::Parser;

/// Fast cycle-accurate simulator for Aegis FPGA.
///
/// Default mode reads a device descriptor JSON and a bitstream binary, then
/// simulates the configured fabric cycle-by-cycle. With `--rbb-port`, runs
/// as a Spike-compatible remote_bitbang JTAG server modelling the Aegis TAP
/// (used as fake silicon for heimdall's silicon-aegis NixOS test).
#[derive(Parser)]
#[command(name = "aegis-sim")]
struct Args {
    /// Path to the device descriptor JSON. Required in simulation mode.
    #[arg(short, long, required_unless_present = "rbb_port")]
    descriptor: Option<PathBuf>,

    /// Path to the bitstream binary. Required in simulation mode.
    #[arg(short, long, required_unless_present = "rbb_port")]
    bitstream: Option<PathBuf>,

    /// Number of clock cycles to simulate
    #[arg(short, long, default_value = "1000")]
    cycles: u64,

    /// Output VCD waveform file
    #[arg(long)]
    vcd: Option<PathBuf>,

    /// IO pad indices to monitor (comma-separated)
    #[arg(long, value_delimiter = ',')]
    monitor: Vec<usize>,

    /// Monitor IO pads by edge and position: n0=north pad 0, w3=west pad 3, etc.
    #[arg(long, value_delimiter = ',')]
    monitor_pin: Vec<String>,

    /// IO pad index to use as clock (toggled each cycle)
    #[arg(long)]
    clock_pad: Option<usize>,

    /// Clock pad by edge and position (e.g., w0)
    #[arg(long)]
    clock_pin: Option<String>,

    /// Set a pin high for a cycle range: "w1:0-9" sets west pad 1 high
    /// during cycles 0 through 9. Multiple allowed.
    #[arg(long, value_delimiter = ',')]
    set_pin: Vec<String>,

    /// Run as a Spike-compatible remote_bitbang JTAG server on this port
    /// instead of simulating cycles. Cycle-simulation flags are ignored.
    #[arg(long)]
    rbb_port: Option<u16>,

    /// Bind address for `--rbb-port`.
    #[arg(long, default_value = "127.0.0.1")]
    rbb_host: String,

    /// 32-bit IDCODE the rbb TAP reports during IDCODE DR shift.
    #[arg(long, default_value = "0x00000001", value_parser = parse_u32_hex)]
    rbb_idcode: u32,

    /// File to write the bitstream received via CONFIG on Update-DR.
    /// Bytes are LSB-first per the JTAG shift order.
    #[arg(long)]
    rbb_bitstream_out: Option<PathBuf>,

    /// Exit after the first rbb client disconnects.
    #[arg(long, default_value_t = false)]
    rbb_once: bool,
}

fn parse_u32_hex(s: &str) -> Result<u32, String> {
    let s = s
        .strip_prefix("0x")
        .or_else(|| s.strip_prefix("0X"))
        .unwrap_or(s);
    u32::from_str_radix(s, 16).map_err(|e| format!("expected hex u32: {e}"))
}

fn run_rbb(args: &Args) -> ExitCode {
    let cfg = aegis_sim::jtag::RbbConfig {
        host: args.rbb_host.clone(),
        port: args.rbb_port.expect("guarded by clap"),
        idcode: args.rbb_idcode,
        bitstream_out: args.rbb_bitstream_out.clone(),
        once: args.rbb_once,
    };
    if let Err(e) = aegis_sim::jtag::serve(&cfg) {
        eprintln!("aegis-sim: rbb server error: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let args = Args::parse();

    if args.rbb_port.is_some() {
        return run_rbb(&args);
    }

    let descriptor = args
        .descriptor
        .as_ref()
        .expect("required by clap in sim mode");
    let bitstream_path = args
        .bitstream
        .as_ref()
        .expect("required by clap in sim mode");

    let desc_json =
        fs::read_to_string(descriptor).unwrap_or_else(|e| panic!("Failed to read descriptor: {e}"));
    let desc: aegis_ip::AegisFpgaDeviceDescriptor = serde_json::from_str(&desc_json)
        .unwrap_or_else(|e| panic!("Failed to parse descriptor: {e}"));

    let bitstream =
        fs::read(bitstream_path).unwrap_or_else(|e| panic!("Failed to read bitstream: {e}"));

    eprintln!(
        "Simulating {} ({}x{}) for {} cycles",
        desc.device,
        u64::from(desc.fabric.width),
        u64::from(desc.fabric.height),
        args.cycles,
    );

    let mut sim = aegis_sim::Simulator::new(&desc, &bitstream);

    // Resolve named pins to pad indices
    let fw = u64::from(desc.fabric.width) as usize;
    let fh = u64::from(desc.fabric.height) as usize;
    let mut all_monitors = args.monitor.clone();
    for pin in &args.monitor_pin {
        let (edge, pos) = pin.split_at(1);
        if let Ok(p) = pos.parse::<usize>() {
            let idx = match edge {
                "n" | "N" => p,               // north: 0..fw
                "e" | "E" => fw + p,          // east: fw..fw+fh
                "s" | "S" => fw + fh + p,     // south: fw+fh..2*fw+fh
                "w" | "W" => 2 * fw + fh + p, // west: 2*fw+fh..2*(fw+fh)
                _ => {
                    eprintln!("Unknown edge '{edge}' in pin '{pin}'");
                    continue;
                }
            };
            eprintln!("Pin {pin} -> pad {idx}");
            all_monitors.push(idx);
        }
    }

    // Set up VCD writer if requested
    let mut vcd = args.vcd.as_ref().map(|_| {
        let mut w = aegis_sim::VcdWriter::new("1ns");
        w.add_signal("clk");
        for &pad in &all_monitors {
            w.add_signal(&format!("io_{pad}"));
        }
        w.finish_header();
        w
    });

    // Signal IDs: '!' = clk, '"' = first monitor, '#' = second, etc.
    let monitor_ids: Vec<char> = all_monitors
        .iter()
        .enumerate()
        .map(|(i, _)| (b'"' + i as u8) as char)
        .collect();

    // Resolve clock pad
    let clock_pad = args.clock_pad.or_else(|| {
        args.clock_pin.as_ref().map(|pin| {
            let (edge, pos) = pin.split_at(1);
            let p: usize = pos.parse().expect("Invalid clock pin position");
            match edge {
                "n" | "N" => p,
                "e" | "E" => fw + p,
                "s" | "S" => fw + fh + p,
                "w" | "W" => 2 * fw + fh + p,
                _ => panic!("Unknown edge '{edge}'"),
            }
        })
    });
    if let Some(cp) = clock_pad {
        eprintln!("Clock pad: {cp}");
    }

    // Parse --set-pin entries: "w1:0-9" -> (pad_idx, start_cycle, end_cycle)
    let mut stimuli: Vec<(usize, u64, u64)> = Vec::new();
    for spec in &args.set_pin {
        let parts: Vec<&str> = spec.split(':').collect();
        if parts.len() != 2 {
            eprintln!("Invalid --set-pin format '{spec}', expected 'pin:start-end'");
            continue;
        }
        let pin = parts[0];
        let (edge, pos) = pin.split_at(1);
        let p: usize = pos.parse().expect("Invalid pin position");
        let pad_idx = match edge {
            "n" | "N" => p,
            "e" | "E" => fw + p,
            "s" | "S" => fw + fh + p,
            "w" | "W" => 2 * fw + fh + p,
            _ => {
                eprintln!("Unknown edge '{edge}' in set-pin '{spec}'");
                continue;
            }
        };
        let range: Vec<&str> = parts[1].split('-').collect();
        let start: u64 = range[0].parse().expect("Invalid start cycle");
        let end: u64 = if range.len() > 1 {
            range[1].parse().expect("Invalid end cycle")
        } else {
            args.cycles
        };
        eprintln!("Set pin {pin} (pad {pad_idx}) high for cycles {start}-{end}");
        stimuli.push((pad_idx, start, end));
    }

    for cycle in 0..args.cycles {
        // Toggle clock pad each cycle
        if let Some(cp) = clock_pad {
            sim.set_io(cp, cycle % 2 == 0);
        }
        // Apply stimuli
        for &(pad, start, end) in &stimuli {
            sim.set_io(pad, cycle >= start && cycle <= end);
        }
        sim.step();

        if let Some(ref mut w) = vcd {
            w.timestamp(cycle * 2);
            w.set_value('!', true); // clk high
            for (i, &pad) in all_monitors.iter().enumerate() {
                w.set_value(monitor_ids[i], sim.get_io(pad));
            }
            w.timestamp(cycle * 2 + 1);
            w.set_value('!', false); // clk low
        }
    }

    eprintln!("Simulation complete: {} cycles", sim.cycle());

    // Dump internal state summary
    let total_pads = 2 * fw + 2 * fh;
    let active_pads: Vec<usize> = (0..total_pads).filter(|&i| sim.get_io(i)).collect();
    eprintln!(
        "  Active IO pads: {:?} ({}/{})",
        &active_pads[..active_pads.len().min(20)],
        active_pads.len(),
        total_pads
    );

    if let Some(vcd_path) = &args.vcd {
        if let Some(w) = vcd {
            fs::write(vcd_path, w.finish()).unwrap_or_else(|e| panic!("Failed to write VCD: {e}"));
            eprintln!("VCD written to {}", vcd_path.display());
        }
    }

    // Print monitored IO values
    for &pad in &all_monitors {
        eprintln!("  IO pad {}: {}", pad, sim.get_io(pad) as u8);
    }
    ExitCode::SUCCESS
}
