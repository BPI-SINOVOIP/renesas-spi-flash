# Board Flashing Configuration on RZ devices

All the scripts uses a `boards_flash_config.toml` file to define flash layout and bootloader addresses for supported boards. The configuration is structured per board and boot type (e.g., xspi, emmc), and includes information such as:

- BL2, FIP, BID (Board Identification) flash offsets
- Ethernet addresses
- Common load_address per board

## Example Structure

```toml
[rzg2l-sbc]
ethernet = ["11c20000", "11c30000"]
flash_address = ["00000", "1D200", "1C700"]
load_address = "0x48000000"

[rzg2l-sbc.xspi]
BL2 = ["11E00", "00000"]
FIP = ["00000", "1D200"]
BID = ["00810", "1C700"]

[rzg2l-sbc.emmc]
BL2 = ["1", "1", "11E00"]
FIP = ["1", "100", "00000", "2", "8"]
BID = ["1", "200", "1C700", "250", "122"]
```

## How to support new board to script

Edit the `boards_flash_config.toml` file to include the new board information:

```toml
[<board_name>]
bl2_base = "<bl2_base_address>"
fconf_dtb_base = "<fconf_dtb_base_address>"
ethernet = ["<eth0_address>", "eth1_address"]
flash_address = ["<bl2>", "<fip>", "<board_information>"]
load_address = "<working_ram>"

[<board_name>.xspi]
"BL2": ["<srec_top_address>", "<flash_address>"]
"FIP": ["<srec_top_address>", "<flash_address>"]
"BID": ["<binary_size (.bin) / srec_top_address (.srec)>", "<flash_address>"]

[<board_name>.emmc]
"BL2": ["<area>", "<sector_start>", "<program_start_address>"]
"FIP": ["<area>", "<sector_start>", "<program_start_address>", "<ext_csd_b1>", "<ext_csd_b3>"]
"BID": ["<area>", "<sector_start>", "<program_start_address>", "<ext_csd_b1>", "<ext_csd_b3>"]
```

Each board has a dedicated section for its specific configuration. The available setting types are as follows:

- **General**:
  - bl2_base: Base address of the BL2 image in memory. This defines where the BL2 binary is loaded or linked before execution or flashing. The address must align with the memory map of the target board and match the BL2 linker configuration.
  - fconf_dtb_base: Base address (in-memory) where the FCONF DTB is loaded.
  - ethernet: Specifies the addresses of `ether0` and `ether1` in sequential order.
  - flash_address: The SPI flash address where BL2, FIP, and board information are sequentially stored.
  - load_address: The working RAM address used to load the binary file before writing it to SPI flash.

- **xspi**:
  - BL2: Provide the `srec_top_address` and `flash_address` sequentially for the BL2 image.
  - FIP: Provide the `srec_top_address` and `flash_address` sequentially for the FIP image.
  - BID: Supports two image formats: `.bin` and `.srec`.
    - If using `.bin`: Specify `binary_size` and `flash_address` sequentially.
    - If using `.srec`: Specify `srec_top_address` and `flash_address` sequentially.

- **emmc**:
  - BL2: Specify `area`, `sector_start`, and `program_start_address` sequentially for the BL2 image.
  - FIP: Specify `area`, `sector_start`, `program_start_address`, `ext_csd_b1`, and `ext_csd_b3` sequentially for the FIP image.
  - BID: Provide `area`, `sector_start`, `program_start_address`, `ext_csd_b1`, and `ext_csd_b3` sequentially for the board identification image.
