#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    cat <<EOF
Usage: $0 <target> [--erase-env] [--erase-user]

Supported targets:
  ai2h    Bananapi-AI2H, 64 MiB SPI-NOR
  ai2n    Bananapi-AI2N, 64 MiB SPI-NOR
  g3l     Bananapi-G3L, 16 MiB SPI-NOR

Options:
  --erase-env   Erase the env partition before writing BL2 and FIP
  --erase-user  Erase the user partition before writing BL2 and FIP

By default, only the bl2 and fip partitions are erased. The env and user
partitions are preserved unless their corresponding option is specified.

The BOOTLOADER environment variable must point to the target bootloader
directory. Source ../env.sh <target> before running this script.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

if [[ $# -eq 0 ]]; then
    usage >&2
    exit 1
fi

case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
esac

TARGET=$1
shift

ERASE_ENV=0
ERASE_USER=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --erase-env)
            ERASE_ENV=1
            ;;
        --erase-user)
            ERASE_USER=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

BL2_FILENAME="bl2_bp_spi-bananapi-${TARGET}.bin"
FIP_FILENAME="fip-bananapi-${TARGET}.bin"

case "$TARGET" in
    ai2h|ai2n)
        # Bananapi-AI2H/AI2N DTS layout (64 MiB SPI-NOR):
        #   bl2  @ 0x0000000, size 0x0060000
        #   fip  @ 0x0060000, size 0x0780000
        #   env  @ 0x07E0000, size 0x0020000
        #   user @ 0x0800000, size 0x3800000
        PARTITION_NAMES=("bl2" "fip" "env" "user")
        PARTITION_OFFSETS=(0x00000000 0x00060000 0x007E0000 0x00800000)
        PARTITION_SIZES=(0x00060000 0x00780000 0x00020000 0x03800000)
        ;;
    g3l)
        # Bananapi-G3L DTS layout (16 MiB SPI-NOR):
        #   bl2  @ 0x000000, size 0x060000
        #   fip  @ 0x060000, size 0x780000
        #   env  @ 0x7E0000, size 0x020000
        #   user @ 0x800000, size 0x800000
        PARTITION_NAMES=("bl2" "fip" "env" "user")
        PARTITION_OFFSETS=(0x00000000 0x00060000 0x007E0000 0x00800000)
        PARTITION_SIZES=(0x00060000 0x00780000 0x00020000 0x00800000)
        ;;
    *)
        echo "Invalid target: $TARGET" >&2
        echo >&2
        usage >&2
        exit 1
        ;;
esac

[[ -n "${BOOTLOADER:-}" ]] \
    || die "BOOTLOADER is not set. Run: source ../env.sh $TARGET"

BL2_BIN="$BOOTLOADER/$BL2_FILENAME"
FIP_BIN="$BOOTLOADER/$FIP_FILENAME"

for cmd in mtd_debug stat cmp awk; do
    command -v "$cmd" >/dev/null 2>&1 \
        || die "$cmd is required. Install mtd-utils if it is missing."
done

if [[ $(id -u) -eq 0 ]]; then
    RUN_AS_ROOT=()
elif command -v sudo >/dev/null 2>&1; then
    RUN_AS_ROOT=(sudo)
else
    die "Root privileges are required. Run this script as root; sudo is not installed."
fi

if [[ ! -r /proc/mtd ]] || ! grep -q '^mtd' /proc/mtd; then
    echo "No MTD partitions detected; attempting to load spi_nor..."
    command -v modprobe >/dev/null 2>&1 \
        || die "No MTD partitions were detected and modprobe is not available. Check the SPI-NOR driver and device tree."
    "${RUN_AS_ROOT[@]}" modprobe spi_nor || die "Failed to load spi_nor"
    sleep 1
fi

[[ -r /proc/mtd ]] || die "/proc/mtd is not available"
[[ -f "$BL2_BIN" ]] || die "File not found: $BL2_BIN"
[[ -f "$FIP_BIN" ]] || die "File not found: $FIP_BIN"

declare -a MTD_DEVICES

resolve_partition() {
    local index=$1
    local name=${PARTITION_NAMES[$index]}
    local expected_size=${PARTITION_SIZES[$index]}
    local expected_hex
    local entry
    local device_id
    local actual_hex
    local actual_size
    local device

    expected_hex=$(printf '%08x' "$expected_size")
    entry=$(awk -v wanted="$name" '$4 == "\"" wanted "\"" { print; count++ } END { if (count != 1) exit 1 }' /proc/mtd) \
        || die "Expected exactly one MTD partition named '$name'"

    device_id=${entry%%:*}
    read -r actual_hex _ _ <<< "${entry#*:}"
    actual_size=$((16#$actual_hex))
    device="/dev/$device_id"

    [[ -c "$device" ]] || die "MTD character device is missing: $device"
    [[ "$actual_size" -eq "$expected_size" ]] \
        || die "Partition '$name' has size 0x${actual_hex^^}; expected 0x${expected_hex^^} for $TARGET"

    MTD_DEVICES[$index]=$device
}

for i in "${!PARTITION_NAMES[@]}"; do
    resolve_partition "$i"
done

BL2_FILE_SIZE=$(stat -c%s "$BL2_BIN")
FIP_FILE_SIZE=$(stat -c%s "$FIP_BIN")

(( BL2_FILE_SIZE <= PARTITION_SIZES[0] )) \
    || die "$BL2_BIN exceeds the bl2 partition size"
(( FIP_FILE_SIZE <= PARTITION_SIZES[1] )) \
    || die "$FIP_BIN exceeds the fip partition size"

echo "Target: $TARGET"
echo "BL2: $BL2_BIN ($BL2_FILE_SIZE bytes)"
echo "FIP: $FIP_BIN ($FIP_FILE_SIZE bytes)"
echo "Validated MTD layout:"
for i in "${!PARTITION_NAMES[@]}"; do
    printf '  %-4s %-10s offset 0x%08X, size 0x%08X\n' \
        "${PARTITION_NAMES[$i]}" "${MTD_DEVICES[$i]}" \
        "${PARTITION_OFFSETS[$i]}" "${PARTITION_SIZES[$i]}"
done

VERIFY_DIR=$(mktemp -d /tmp/spi-flash-verify.XXXXXX)
VERIFY_BL2="$VERIFY_DIR/bl2.bin"
VERIFY_FIP="$VERIFY_DIR/fip.bin"

cleanup() {
    [[ ! -e "$VERIFY_BL2" ]] || unlink "$VERIFY_BL2"
    [[ ! -e "$VERIFY_FIP" ]] || unlink "$VERIFY_FIP"
    rmdir "$VERIFY_DIR" 2>/dev/null || true
}
trap cleanup EXIT

ERASE_PARTITION_INDICES=(0 1)
(( ERASE_ENV == 0 )) || ERASE_PARTITION_INDICES+=(2)
(( ERASE_USER == 0 )) || ERASE_PARTITION_INDICES+=(3)

ERASE_PARTITION_NAMES=()
for i in "${ERASE_PARTITION_INDICES[@]}"; do
    ERASE_PARTITION_NAMES+=("${PARTITION_NAMES[$i]}")
done

echo "=== Erasing partitions: ${ERASE_PARTITION_NAMES[*]} ==="
for i in "${ERASE_PARTITION_INDICES[@]}"; do
    echo "Erasing ${PARTITION_NAMES[$i]} (${MTD_DEVICES[$i]})..."
    "${RUN_AS_ROOT[@]}" mtd_debug erase "${MTD_DEVICES[$i]}" 0 "${PARTITION_SIZES[$i]}" \
        || die "Failed to erase ${MTD_DEVICES[$i]}"
done

echo "Writing BL2 to ${MTD_DEVICES[0]}..."
"${RUN_AS_ROOT[@]}" mtd_debug write "${MTD_DEVICES[0]}" 0 "$BL2_FILE_SIZE" "$BL2_BIN" \
    || die "Failed to write $BL2_BIN"

echo "Writing FIP to ${MTD_DEVICES[1]}..."
"${RUN_AS_ROOT[@]}" mtd_debug write "${MTD_DEVICES[1]}" 0 "$FIP_FILE_SIZE" "$FIP_BIN" \
    || die "Failed to write $FIP_BIN"

echo "=== Verifying written data ==="
"${RUN_AS_ROOT[@]}" mtd_debug read "${MTD_DEVICES[0]}" 0 "$BL2_FILE_SIZE" "$VERIFY_BL2" \
    || die "Failed to read back BL2"
cmp -s "$BL2_BIN" "$VERIFY_BL2" || die "BL2 verification failed"
echo "BL2 verification successful"

"${RUN_AS_ROOT[@]}" mtd_debug read "${MTD_DEVICES[1]}" 0 "$FIP_FILE_SIZE" "$VERIFY_FIP" \
    || die "Failed to read back FIP"
cmp -s "$FIP_BIN" "$VERIFY_FIP" || die "FIP verification failed"
echo "FIP verification successful"

echo "Operation completed successfully. BL2 and FIP were written and verified."
(( ERASE_ENV != 0 )) || echo "The env partition was preserved."
(( ERASE_USER != 0 )) || echo "The user partition was preserved."
