/// Device descriptor types generated from the JSON Schema.
pub mod desc {
    use typify::import_types;
    import_types!(schema = "descriptor.schema.json");
}

pub use desc::*;

#[allow(unused_imports)]
pub use tile_bits::TileConfig;

pub mod tile_bits;

#[cfg(test)]
mod desc_tests {
    use std::num::NonZero;

    use super::*;

    #[test]
    fn deserialize_minimal_descriptor() {
        let json = r#"{
            "device": "test_fpga",
            "fabric": {
                "width": 2,
                "height": 2,
                "tracks": 1,
                "tile_config_width": 46,
                "bram": {
                    "column_interval": 0,
                    "columns": [],
                    "data_width": null,
                    "addr_width": null,
                    "depth": null,
                    "tile_config_width": 8
                },
                "dsp": {
                    "column_interval": 0,
                    "columns": [],
                    "a_width": null,
                    "b_width": null,
                    "result_width": null,
                    "tile_config_width": 16
                },
                "carry_chain": {
                    "direction": "south_to_north",
                    "per_column": true
                }
            },
            "io": {
                "total_pads": 8,
                "tile_config_width": 8,
                "pads": []
            },
            "serdes": {
                "count": 0,
                "tile_config_width": 32,
                "edge_assignment": []
            },
            "clock": {
                "tile_count": 1,
                "tile_config_width": 49,
                "outputs_per_tile": 4,
                "total_outputs": 4
            },
            "config": {
                "total_bits": 233,
                "chain_order": []
            },
            "tiles": []
        }"#;

        let desc: AegisFpgaDeviceDescriptor = serde_json::from_str(json).unwrap();
        assert_eq!(desc.device, "test_fpga");
        assert_eq!(desc.fabric.width, NonZero::new(2).unwrap());
        assert_eq!(desc.fabric.height, NonZero::new(2).unwrap());
    }
}
