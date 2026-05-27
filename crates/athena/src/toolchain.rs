use std::path::PathBuf;
use std::process::Command;

use crate::project::ProjectState;

#[derive(Debug, Clone)]
pub struct ToolchainResult {
    pub success: bool,
    pub stage: String,
    pub log: String,
}

/// Find a device support file (TCL, Verilog, rules) in the data pack directory.
fn find_device_file(proj: &ProjectState, suffix: &str) -> Option<PathBuf> {
    let pack_dir = proj.descriptor_path.as_ref()?.parent()?;
    let path = pack_dir.join(format!("{}{suffix}", proj.manifest.device));
    path.exists().then_some(path)
}

pub fn synthesize(proj: &ProjectState) -> ToolchainResult {
    let build_dir = proj.project_dir.join("build");
    let _ = std::fs::create_dir_all(&build_dir);

    if proj.manifest.sources.is_empty() {
        return ToolchainResult {
            success: false,
            stage: "Synthesis".to_string(),
            log: "No source files in project.".to_string(),
        };
    }

    let top_module = proj
        .manifest
        .top_module
        .clone()
        .unwrap_or_else(|| "top".to_string());

    let device_name = &proj.manifest.device;
    let synth_tcl = build_dir.join("synth.tcl");

    // Quote a path for TCL (brace-quoting handles Unicode and spaces)
    let tcl_path = |p: &std::path::Path| format!("{{{}}}", p.display());

    // Source files are project_dir/foo.v, build_dir is project_dir/build/,
    // so relative paths are ../foo.v
    let sources_rel: Vec<String> = proj
        .manifest
        .sources
        .iter()
        .map(|s| format!("../{s}"))
        .collect();

    let synth_script = if let Some(device_script) = find_device_file(proj, "-synth-aegis.tcl") {
        // Use the device-provided synth script, setting the required TCL variables
        // Device files are in the Nix store (ASCII paths), so tcl_path is fine for those
        let verilog_files: String = sources_rel.iter().map(|s| format!(" {{{s}}}")).collect();
        let cells_v = find_device_file(proj, "_cells.v")
            .map(|p| tcl_path(&p))
            .unwrap_or_default();
        let techmap_v = find_device_file(proj, "_techmap.v")
            .map(|p| tcl_path(&p))
            .unwrap_or_default();
        let bram_rules = find_device_file(proj, "_bram.rules")
            .map(|p| tcl_path(&p))
            .unwrap_or_default();

        format!(
            "set VERILOG_FILES [list{verilog_files}]\n\
             set TOP_MODULE {top_module}\n\
             set CELLS_V {cells_v}\n\
             set TECHMAP_V {techmap_v}\n\
             set BRAM_RULES {bram_rules}\n\
             set DEVICE_NAME {device_name}\n\
             source {}\n",
            tcl_path(&device_script)
        )
    } else {
        // Fallback: basic synthesis without device-specific script
        let read_cmds: String = sources_rel
            .iter()
            .map(|s| format!("read_verilog {{{s}}}\n"))
            .collect();

        format!(
            "{read_cmds}\
             synth -top {top_module} -flatten\n\
             abc -lut 4\n\
             opt_clean -purge\n\
             write_json synth.json\n"
        )
    };

    if let Err(e) = std::fs::write(&synth_tcl, &synth_script) {
        return ToolchainResult {
            success: false,
            stage: "Synthesis".to_string(),
            log: format!(
                "Failed to write synth script at {}: {e}",
                synth_tcl.display()
            ),
        };
    }

    let output = Command::new("yosys")
        .arg("-c")
        .arg("synth.tcl")
        .current_dir(&build_dir)
        .output();

    match output {
        Ok(out) => {
            let log = format!(
                "{}\n{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );

            // The device script writes to {device_name}_pnr.json, copy to synth.json
            let device_output = build_dir.join(format!("{device_name}_pnr.json"));
            let synth_json = build_dir.join("synth.json");
            if device_output.exists() {
                let _ = std::fs::copy(&device_output, &synth_json);
            }

            ToolchainResult {
                success: out.status.success(),
                stage: "Synthesis".to_string(),
                log,
            }
        }
        Err(e) => ToolchainResult {
            success: false,
            stage: "Synthesis".to_string(),
            log: format!("Failed to run yosys: {e}"),
        },
    }
}

pub fn place_route(proj: &ProjectState) -> ToolchainResult {
    let build_dir = proj.project_dir.join("build");
    let synth_json = build_dir.join("synth.json");
    let routed_json = build_dir.join("routed.json");

    if !synth_json.exists() {
        return ToolchainResult {
            success: false,
            stage: "Place & Route".to_string(),
            log: "No synthesis output found. Run Synthesize first.".to_string(),
        };
    }

    let device_arg = format!(
        "{}x{}t{}",
        proj.descriptor.fabric.width, proj.descriptor.fabric.height, proj.descriptor.fabric.tracks
    );

    let mut cmd = Command::new("nextpnr-generic");
    cmd.arg("--uarch")
        .arg("aegis")
        .arg("-o")
        .arg(format!("device={device_arg}"))
        .arg("--json")
        .arg(&synth_json)
        .arg("--write")
        .arg(&routed_json);

    // Add constraints if present
    if let Some(ref constraints) = proj.manifest.constraints {
        let pcf = proj.project_dir.join(constraints);
        if pcf.exists() {
            cmd.arg("-o").arg(format!("pcf={}", pcf.display()));
        }
    }

    let output = cmd.current_dir(&proj.project_dir).output();

    match output {
        Ok(out) => {
            let log = format!(
                "{}\n{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            ToolchainResult {
                success: out.status.success(),
                stage: "Place & Route".to_string(),
                log,
            }
        }
        Err(e) => ToolchainResult {
            success: false,
            stage: "Place & Route".to_string(),
            log: format!("Failed to run nextpnr: {e}"),
        },
    }
}

pub fn pack(proj: &ProjectState) -> ToolchainResult {
    let build_dir = proj.project_dir.join("build");
    let routed_json = build_dir.join("routed.json");
    let bitstream_path = build_dir.join("bitstream.bin");

    if !routed_json.exists() {
        return ToolchainResult {
            success: false,
            stage: "Pack".to_string(),
            log: "No PnR output found. Run Place & Route first.".to_string(),
        };
    }

    let pnr_json = match std::fs::read_to_string(&routed_json) {
        Ok(s) => s,
        Err(e) => {
            return ToolchainResult {
                success: false,
                stage: "Pack".to_string(),
                log: format!("Failed to read routed.json: {e}"),
            };
        }
    };

    let pnr: aegis_pack::PnrOutput = match serde_json::from_str(&pnr_json) {
        Ok(p) => p,
        Err(e) => {
            return ToolchainResult {
                success: false,
                stage: "Pack".to_string(),
                log: format!("Failed to parse routed.json: {e}"),
            };
        }
    };

    let bitstream = aegis_pack::pack(&proj.descriptor, &pnr);

    match std::fs::write(&bitstream_path, &bitstream) {
        Ok(_) => ToolchainResult {
            success: true,
            stage: "Pack".to_string(),
            log: format!(
                "Bitstream generated: {} ({} bytes)",
                bitstream_path.display(),
                bitstream.len()
            ),
        },
        Err(e) => ToolchainResult {
            success: false,
            stage: "Pack".to_string(),
            log: format!("Failed to write bitstream: {e}"),
        },
    }
}

pub fn simulate(proj: &ProjectState, cycles: u64) -> ToolchainResult {
    let build_dir = proj.project_dir.join("build");
    let bitstream_path = build_dir.join("bitstream.bin");

    if !bitstream_path.exists() {
        return ToolchainResult {
            success: false,
            stage: "Simulate".to_string(),
            log: "No bitstream found. Run Generate Bitstream first.".to_string(),
        };
    }

    let bitstream = match std::fs::read(&bitstream_path) {
        Ok(b) => b,
        Err(e) => {
            return ToolchainResult {
                success: false,
                stage: "Simulate".to_string(),
                log: format!("Failed to read bitstream: {e}"),
            };
        }
    };

    let mut sim = aegis_sim::Simulator::new(&proj.descriptor, &bitstream);
    sim.run(cycles);

    let vcd_path = build_dir.join("simulation.vcd");
    let mut vcd = aegis_sim::VcdWriter::new("1ns");
    // Add basic IO signals
    let total_pads = proj.descriptor.io.total_pads;
    let mut pad_ids = Vec::new();
    for i in 0..total_pads {
        let id = vcd.add_signal(&format!("io_{i}"));
        pad_ids.push(id);
    }
    vcd.finish_header();

    // Re-simulate with VCD capture
    let mut sim = aegis_sim::Simulator::new(&proj.descriptor, &bitstream);
    for cycle in 0..cycles {
        sim.step();
        vcd.timestamp(cycle);
        for (i, &id) in pad_ids.iter().enumerate() {
            vcd.set_value(id, sim.get_io(i));
        }
    }

    let vcd_data = vcd.finish();
    let _ = std::fs::write(&vcd_path, &vcd_data);

    ToolchainResult {
        success: true,
        stage: "Simulate".to_string(),
        log: format!(
            "Simulation complete: {cycles} cycles\nVCD output: {}",
            vcd_path.display()
        ),
    }
}

pub fn generate_bitstream(proj: &ProjectState) -> Vec<ToolchainResult> {
    let mut results = Vec::new();

    let synth = synthesize(proj);
    let ok = synth.success;
    results.push(synth);
    if !ok {
        return results;
    }

    let pnr = place_route(proj);
    let ok = pnr.success;
    results.push(pnr);
    if !ok {
        return results;
    }

    let pack = pack(proj);
    results.push(pack);

    results
}
