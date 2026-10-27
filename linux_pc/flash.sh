#!/bin/bash

usage() {
	echo "Usage: $0 <target> <method>"
	echo
	echo "Supported targets:"
	echo "  ai2h    Bananapi-AI2H"
	echo "  ai2n    Bananapi-AI2N"
	echo "  g3l     Bananapi-G3L"
	echo
	echo "Supported methods:"
	echo "  xspi   Program SPI Flash"
	echo "  emmc   Program eMMC"
	echo
	echo "Examples:"
	echo "  $0 ai2h xspi"
	echo "  $0 g3l emmc"
}

if [ "$#" -ne 2 ]; then
	usage >&2
	exit 1
fi

TARGET=$1
METHOD=$2

BOARD=
SERIAL=/dev/ttyACM0
#SERIAL=/dev/ttyUSB0
BAUD=115200
IMAGE_PATH=$BOOTLOADER

if [ "$TARGET" = "ai2h" ]; then
	FLASH_WRITER=$IMAGE_PATH/Flash_Writer_SCIF_RZV2H_DEV_INTERNAL_MEMORY.mot
	BOARD="rzv2h-evk"
elif [ "$TARGET" = "ai2n" ]; then
	FLASH_WRITER=$IMAGE_PATH/Flash_Writer_SCIF_RZV2N_DEV_LPDDR4X.mot
	BOARD="rzv2h-evk"
elif [ "$TARGET" = "g3l" ]; then
	FLASH_WRITER=$IMAGE_PATH/Flash_Writer_SCIF_RZG3L_SMARC_LPDDR4.mot
	BOARD="rzg3l-evk"
else
	echo "Invalid target: $TARGET" >&2
	echo >&2
	usage >&2
	exit 1
fi

if [ "$METHOD" = "xspi" ]; then
	BL2=$IMAGE_PATH/bl2_bp_spi-bananapi-${TARGET}.srec
elif [ "$METHOD" = "emmc" ]; then
	BL2=$IMAGE_PATH/bl2_bp_emmc-bananapi-${TARGET}.srec
else
	echo "Invalid flash method: $METHOD" >&2
	echo >&2
	usage >&2
	exit 1
fi

FIP=$IMAGE_PATH/fip-bananapi-${TARGET}.srec

[ -f "$FLASH_WRITER" ] || { echo "File not found: $FLASH_WRITER"; exit 1; }
[ -f "$BL2" ] || { echo "File not found: $BL2"; exit 1; }
[ -f "$FIP" ] || { echo "File not found: $FIP"; exit 1; }


python3 bootloader_flash.py \
	--board_name "$BOARD" \
	--flash_method "$METHOD" \
	--serial_port "$SERIAL" \
	--serial_port_baud "$BAUD" \
	--image_writer "$FLASH_WRITER" \
	--image_bl2 "$BL2" \
	--image_fip "$FIP"
