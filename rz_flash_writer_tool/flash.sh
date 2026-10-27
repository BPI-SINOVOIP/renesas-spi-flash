#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FLASH_WRITER_TOOL="$SCRIPT_DIR/flash_writer_tool.sh"
ACTIVE_CONFIG=""
TEMP_CONFIG=""
SERIAL_DEVICE=""
SERIAL_LOG=""
SERIAL_MONITOR_PID=""
SERIAL_DISPLAY_PID=""
VERIFY_MODE="${VERIFY_MODE:-auto}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-120}"
VERIFY_PROFILE="${VERIFY_PROFILE:-}"
FLASH_PLATFORM="${FLASH_PLATFORM:-}"
VERIFY_ERROR_PATTERN=""
VERIFY_DOWNLOAD_PATTERN=""
VERIFY_PROMPT_PATTERN=""

cleanup() {
	local status=$?

	if [[ -n "$SERIAL_DISPLAY_PID" ]] && kill -0 "$SERIAL_DISPLAY_PID" 2>/dev/null; then
		kill "$SERIAL_DISPLAY_PID" 2>/dev/null || true
		wait "$SERIAL_DISPLAY_PID" 2>/dev/null || true
	fi
	if [[ -n "$SERIAL_MONITOR_PID" ]] && kill -0 "$SERIAL_MONITOR_PID" 2>/dev/null; then
		kill "$SERIAL_MONITOR_PID" 2>/dev/null || true
		wait "$SERIAL_MONITOR_PID" 2>/dev/null || true
	fi
	if [[ -n "$TEMP_CONFIG" && -f "$TEMP_CONFIG" ]]; then
		rm -f -- "$TEMP_CONFIG"
	fi
	if [[ -n "$SERIAL_LOG" && -f "$SERIAL_LOG" ]]; then
		if (( status == 0 )); then
			rm -f -- "$SERIAL_LOG"
		else
			echo "Serial log retained after failure: $SERIAL_LOG" >&2
		fi
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
	cat <<EOF
Usage:
  $0                         Open the interactive menu
  $0 config                  Open the GUI to select, create, or edit a config
  $0 fw [config]             Verify Download Mode and load Flash Writer only
  $0 spi [config]            Program SPI: FW -> BL2 -> FIP
  $0 emmc [config]           Program eMMC: FW -> BL2 -> FIP -> eMMC setup
  $0 erase-emmc PART [config]

eMMC erase PART:
  user    Erase the User Partition
  boot1   Erase Boot Partition 1
  boot2   Erase Boot Partition 2
  all     Erase Boot1, Boot2, and the User Partition

Default config:
  FLASH_CONFIG, the GUI-selected config, or config.ini (in that order)

Override the default config with FLASH_CONFIG:
  FLASH_CONFIG=/path/to/config.ini $0 spi

Verification settings in the board config:
  VERIFY_MODE=auto                Read and verify target output (default)
  VERIFY_MODE=manual              Explicitly confirm every target result manually
  FLASH_PLATFORM=rzv2h            Override the platform selected from BOARD
  VERIFY_PROFILE=name-or-path     Override the platform-selected profile
  VERIFY_TIMEOUT=120              Timeout in seconds for each automatic check
  VERIFY_DOWNLOAD_PATTERN='...'   Required in auto mode; derive it from a target log
  VERIFY_PROMPT_PATTERN='...'     Common completion pattern derived from a target log
  VERIFY_FW_PATTERN='...'         Optional per-operation overrides
  VERIFY_BL2_PATTERN='...'
  VERIFY_FIP_PATTERN='...'
  VERIFY_SPI_BL2_PATTERN='...'    Optional target-specific patterns
  VERIFY_SPI_FIP_PATTERN='...'
  VERIFY_EMMC_BL2_PATTERN='...'
  VERIFY_EMMC_FIP_PATTERN='...'
  VERIFY_EMMC_CONFIG_B1_PATTERN='...'
  VERIFY_EMMC_CONFIG_B1_RESULT_PATTERN='...'
  VERIFY_EMMC_CONFIG_PATTERN='...'
  VERIFY_EMMC_CONFIG_RESULT_PATTERN='...'
  VERIFY_ERASE_PATTERN='...'
  VERIFY_ERROR_PATTERN='...'
EOF
}

platform_for_board() {
	local board=$1

	case "$board" in
		rzv2h-evk-ver1|bananapi-ai2h) echo rzv2h ;;
		rzv2n-evk|bananapi-ai2n)      echo rzv2n ;;
		smarc-rzg3l|bananapi_g3l)     echo rzg3l ;;
		*)                             echo "$board" ;;
	esac
}

die() {
	echo "Error: $*" >&2
	exit 1
}

read_gui_selected_config() {
	local settings_file="$SCRIPT_DIR/settings.txt"
	local selected=""

	[[ -f "$settings_file" ]] || return 1
	selected="$(
		cd -- "$SCRIPT_DIR"
		bash -c 'source ./settings.txt >/dev/null 2>&1; printf "%s" "${CONFIG_FILE:-}"'
	)"
	[[ -n "$selected" ]] || return 1

	if [[ "$selected" != /* ]]; then
		selected="$SCRIPT_DIR/$selected"
	fi
	[[ -f "$selected" ]] || return 1
	ACTIVE_CONFIG="$selected"
}

launch_config_gui() {
	if [[ ! -f "$SCRIPT_DIR/settings.txt" && ! -f "$SCRIPT_DIR/config.ini" ]]; then
		echo "No default config file was found."
	fi
	echo "Opening the config GUI. Use 'Config File' to select or create a config."
	(
		cd -- "$SCRIPT_DIR"
		"$FLASH_WRITER_TOOL"
	)
}

select_config() {
	local requested=${1:-}

	if [[ -n "$requested" ]]; then
		ACTIVE_CONFIG="$requested"
		return 0
	fi
	if [[ -n "${FLASH_CONFIG:-}" ]]; then
		ACTIVE_CONFIG="$FLASH_CONFIG"
		return 0
	fi
	if read_gui_selected_config; then
		return 0
	fi
	if [[ -f "$SCRIPT_DIR/config.ini" ]]; then
		ACTIVE_CONFIG="$SCRIPT_DIR/config.ini"
		return 0
	fi

	launch_config_gui

	if read_gui_selected_config; then
		return 0
	fi
	if [[ -f "$SCRIPT_DIR/config.ini" ]]; then
		ACTIVE_CONFIG="$SCRIPT_DIR/config.ini"
		return 0
	fi
	die "The GUI exited without saving a usable config file"
}

check_prerequisites() {
	local config=$1

	[[ -x "$FLASH_WRITER_TOOL" ]] || die "Executable not found: $FLASH_WRITER_TOOL"
	[[ -f "$config" ]] || die "Config file not found: $config"
}

make_target_config() {
	local config=$1
	local target=$2
	local config_abs

	config_abs="$(realpath -- "$config")"
	TEMP_CONFIG="$(mktemp /tmp/rz-flash-config.XXXXXX.ini)"
	chmod 600 "$TEMP_CONFIG"

	{
		printf 'source %q\n' "$config_abs"
		printf 'FLASH=%q\n' "$target"
		if [[ "$target" == "0" ]]; then
			printf '%s\n' \
				'if [[ -n "${SPI_BL2_FILE:-}" ]]; then' \
				'  BL2_FILE="$SPI_BL2_FILE"' \
				'elif [[ -f "${FILES_DIR:-}/bl2_bp_spi.srec" ]]; then' \
				'  BL2_FILE="$FILES_DIR/bl2_bp_spi.srec"' \
				'fi'
		else
			printf '%s\n' \
				'if [[ -n "${EMMC_BL2_FILE:-}" ]]; then' \
				'  BL2_FILE="$EMMC_BL2_FILE"' \
				'elif [[ -f "${FILES_DIR:-}/bl2_bp_emmc.srec" ]]; then' \
				'  BL2_FILE="$FILES_DIR/bl2_bp_emmc.srec"' \
				'elif [[ -f "${FILES_DIR:-}/bl2_bp_mmc.srec" ]]; then' \
				'  BL2_FILE="$FILES_DIR/bl2_bp_mmc.srec"' \
				'fi'
		fi
	} > "$TEMP_CONFIG"
}

load_verification_settings() {
	local profile_path=""

	# The config is already shell syntax and is sourced by flash_writer_tool.sh.
	# Source it here as well so a board can provide its own verification profile.
	set +u
	# shellcheck disable=SC1090
	source "$TEMP_CONFIG"
	FLASH_PLATFORM="${FLASH_PLATFORM:-$(platform_for_board "${BOARD:-}")}"

	if [[ -n "${VERIFY_PROFILE:-}" ]]; then
		if [[ -f "$VERIFY_PROFILE" ]]; then
			profile_path="$VERIFY_PROFILE"
		else
			profile_path="$SCRIPT_DIR/profiles/${VERIFY_PROFILE%.conf}.conf"
		fi
		[[ -f "$profile_path" ]] || die "Verification profile not found: $VERIFY_PROFILE"
	elif [[ -n "$FLASH_PLATFORM" && -f "$SCRIPT_DIR/profiles/$FLASH_PLATFORM.conf" ]]; then
		profile_path="$SCRIPT_DIR/profiles/$FLASH_PLATFORM.conf"
	fi

	if [[ -n "$profile_path" ]]; then
		# Profiles use default assignments so explicit board-config values win.
		# shellcheck disable=SC1090
		source "$profile_path"
		echo "Flash platform: $FLASH_PLATFORM"
		echo "Verification profile: $profile_path"
	fi
	set -u

	VERIFY_MODE="${VERIFY_MODE:-auto}"
	VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-120}"
	VERIFY_ERROR_PATTERN="${VERIFY_ERROR_PATTERN:-}"
	VERIFY_DOWNLOAD_PATTERN="${VERIFY_DOWNLOAD_PATTERN:-}"
	VERIFY_PROMPT_PATTERN="${VERIFY_PROMPT_PATTERN:-}"
	SERIAL_DEVICE="${SERIAL_DEVICE_INTERFACE:-}"

	case "$VERIFY_MODE" in
		manual|auto) ;;
		*) die "VERIFY_MODE must be 'manual' or 'auto', not '$VERIFY_MODE'" ;;
	esac
	[[ "$VERIFY_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "VERIFY_TIMEOUT must be a positive integer"
	echo "Verification mode: $VERIFY_MODE"
}

serial_log_size() {
	if [[ -n "$SERIAL_LOG" && -f "$SERIAL_LOG" ]]; then
		stat -c %s -- "$SERIAL_LOG"
	else
		echo 0
	fi
}

show_recent_serial_output() {
	local offset=$1

	[[ -f "$SERIAL_LOG" ]] || return 0
	echo "----- target output -----" >&2
	tail -c "+$((offset + 1))" -- "$SERIAL_LOG" | tr -d '\000' | tail -n 40 >&2 || true
	echo "-------------------------" >&2
}

assert_serial_reader_available() {
	local allowed_pid=${1:-}
	local holders
	local pid
	local other_pids=""
	local device_name
	local lock_file
	local lock_pid

	device_name="$(basename -- "$SERIAL_DEVICE")"
	for lock_file in "/run/lock/LCK..$device_name" "/var/lock/LCK..$device_name"; do
		[[ -r "$lock_file" ]] || continue
		lock_pid="$(tr -cd '0-9' < "$lock_file")"
		if [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && \
		   [[ -d "/proc/$lock_pid" ]] && \
		   [[ -z "$allowed_pid" || "$lock_pid" != "$allowed_pid" ]]; then
			die "Serial device $SERIAL_DEVICE is locked by PID $lock_pid. Close the other serial program first."
		fi
	done

	command -v fuser >/dev/null 2>&1 \
		|| die "fuser is required to check whether the serial device is in use"
	holders="$(fuser "$SERIAL_DEVICE" 2>/dev/null || true)"
	for pid in $holders; do
		if [[ -z "$allowed_pid" || "$pid" != "$allowed_pid" ]]; then
			other_pids+=" $pid"
		fi
	done
	[[ -z "$other_pids" ]] \
		|| die "Serial device $SERIAL_DEVICE is already open by PID(s):$other_pids. Close the other serial program first."
}

start_serial_monitor() {

	[[ "$VERIFY_MODE" == "auto" ]] || return 0
	[[ -n "$SERIAL_DEVICE" ]] || die "SERIAL_DEVICE_INTERFACE is required for automatic verification"
	[[ -c "$SERIAL_DEVICE" ]] || die "Serial device is not available: $SERIAL_DEVICE"
	assert_serial_reader_available

	SERIAL_LOG="$(mktemp /tmp/rz-flash-serial.XXXXXX.log)"
	export RZ_FLASH_SERIAL_LOG="$SERIAL_LOG"
	export RZ_FLASH_SYNC_TIMEOUT="$VERIFY_TIMEOUT"
	export RZ_FLASH_SYNC_ERROR_PATTERN="$VERIFY_ERROR_PATTERN"
	# The Boot ROM always starts SCI download at 115200. A previous operation may
	# have left the host port at 921600, which would make the ROM banner unreadable.
	stty -F "$SERIAL_DEVICE" 115200 -icrnl -onlcr -isig -icanon -echo -echoe -opost min 1 time 5 \
		|| die "Cannot configure serial device: $SERIAL_DEVICE"
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$SERIAL_DEVICE" <<'PY'
import os
import sys
import termios

fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
try:
    termios.tcflush(fd, termios.TCIFLUSH)
finally:
    os.close(fd)
PY
	fi
	tee -a "$SERIAL_LOG" < "$SERIAL_DEVICE" > /dev/null &
	SERIAL_MONITOR_PID=$!
	sleep 0.2
	kill -0 "$SERIAL_MONITOR_PID" 2>/dev/null \
		|| die "Cannot start serial reader on $SERIAL_DEVICE"

	echo "Automatic target verification is enabled."
	echo "Target serial output will be displayed after Download Mode is confirmed."
	echo "Do not run cat, minicom, screen, or another reader on $SERIAL_DEVICE."
}

start_serial_display() {
	local offset=$1

	[[ "$VERIFY_MODE" == "auto" ]] || return 0
	[[ -z "$SERIAL_DISPLAY_PID" ]] || return 0
	tail -c "+$((offset + 1))" -f -- "$SERIAL_LOG" &
	SERIAL_DISPLAY_PID=$!
}

wait_for_pattern() {
	local description=$1
	local pattern=$2
	local offset=$3
	local start_time=$SECONDS

	[[ -n "$pattern" ]] || die "No success pattern configured for $description"
	echo "Waiting for target: $description"

	while (( SECONDS - start_time < VERIFY_TIMEOUT )); do
		assert_serial_reader_available "$SERIAL_MONITOR_PID"
		kill -0 "$SERIAL_MONITOR_PID" 2>/dev/null \
			|| die "Serial reader stopped while waiting for $description"
		if [[ -n "$VERIFY_ERROR_PATTERN" ]] && \
		   tail -c "+$((offset + 1))" -- "$SERIAL_LOG" 2>/dev/null | \
		   tr -d '\000' | grep -Ei -- "$VERIFY_ERROR_PATTERN" >/dev/null; then
			show_recent_serial_output "$offset"
			die "Target reported an error while waiting for $description"
		fi
		if tail -c "+$((offset + 1))" -- "$SERIAL_LOG" 2>/dev/null | \
		   tr -d '\000' | grep -Ei -- "$pattern" >/dev/null; then
			echo "Target confirmed: $description"
			return 0
		fi
		sleep 0.1
	done

	show_recent_serial_output "$offset"
	die "Timed out after ${VERIFY_TIMEOUT}s waiting for $description"
}

require_final_logged_pattern() {
	local description=$1
	local result_pattern=$2
	local expected_pattern=$3
	local minimum=$4
	local offset=$5
	local output
	local matches
	local count
	local final_result

	[[ -n "$result_pattern" && -n "$expected_pattern" ]] || return 0
	[[ "$minimum" =~ ^[1-9][0-9]*$ ]] \
		|| die "Required result count for $description must be a positive integer"
	output="$(tail -c "+$((offset + 1))" -- "$SERIAL_LOG" 2>/dev/null | tr -d '\000' || true)"
	matches="$(grep -Ei -- "$result_pattern" <<< "$output" || true)"
	count="$(wc -l <<< "$matches")"
	[[ -n "$matches" ]] || count=0
	if (( count < minimum )); then
		show_recent_serial_output "$offset"
		die "Target output has $count of $minimum required result(s) for $description"
	fi
	final_result="$(tail -n 1 <<< "$matches")"
	if ! grep -Eiq -- "$expected_pattern" <<< "$final_result"; then
		show_recent_serial_output "$offset"
		die "The final target result is incorrect for $description"
	fi
	echo "Target confirmed: $description"
}

operation_pattern() {
	local operation=$1
	local variable=""
	local fallback_variable=""
	local pattern=""

	case "$operation" in
		fw)          variable=VERIFY_FW_PATTERN ;;
		bl2)
			fallback_variable=VERIFY_BL2_PATTERN
			if [[ "${FLASH:-0}" == "0" ]]; then
				variable=VERIFY_SPI_BL2_PATTERN
			else
				variable=VERIFY_EMMC_BL2_PATTERN
			fi
			;;
		fip)
			fallback_variable=VERIFY_FIP_PATTERN
			if [[ "${FLASH:-0}" == "0" ]]; then
				variable=VERIFY_SPI_FIP_PATTERN
			else
				variable=VERIFY_EMMC_FIP_PATTERN
			fi
			;;
		emmc_config) variable=VERIFY_EMMC_CONFIG_PATTERN ;;
		x0|x1|x2)    variable=VERIFY_ERASE_PATTERN ;;
		*)           variable=VERIFY_PROMPT_PATTERN ;;
	esac
	if [[ -n "$variable" ]]; then
		pattern="${!variable:-}"
	fi
	if [[ -z "$pattern" && -n "$fallback_variable" ]]; then
		pattern="${!fallback_variable:-}"
	fi
	if [[ -z "$pattern" ]]; then
		pattern="$VERIFY_PROMPT_PATTERN"
	fi
	printf '%s' "$pattern"
}

validate_verification_profile() {
	local operation
	local pattern

	[[ "$VERIFY_MODE" == "auto" ]] || return 0
	[[ -n "$VERIFY_DOWNLOAD_PATTERN" ]] \
		|| die "VERIFY_DOWNLOAD_PATTERN is required for auto mode and must be derived from a target log"

	for operation in "$@"; do
		pattern="$(operation_pattern "$operation")"
		[[ -n "$pattern" ]] \
			|| die "No auto-verification pattern is configured for '$operation'; collect a target log first"
	done
}

drain_serial_output() {
	[[ -n "$SERIAL_DEVICE" && -c "$SERIAL_DEVICE" ]] || return 0
	command -v python3 >/dev/null 2>&1 || return 0

	python3 - "$SERIAL_DEVICE" <<'PY'
import os
import sys
import termios

fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY)
try:
    termios.tcdrain(fd)
finally:
    os.close(fd)
PY
}

confirm_target_result() {
	local description=$1
	local answer

	echo
	read -r -p "Confirm that the target completed '$description' successfully [y/N]: " answer
	[[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]] \
		|| die "Target result was not confirmed"
}

wait_for_download_mode() {
	local mode=$1
	local offset
	local answer

	echo
	echo "Operation: $mode"
	if [[ "$VERIFY_MODE" == "auto" ]]; then
		offset="$(serial_log_size)"
		echo "Set the board to SCIF Download Mode, then power-cycle it or press RESET."
		wait_for_pattern "Download mode" "$VERIFY_DOWNLOAD_PATTERN" "$offset"
		start_serial_display "$(serial_log_size)"
	else
		echo "Set the board to SCIF Download Mode, then power-cycle it or press RESET."
		read -r -p "Press Enter after the 'Download mode / please send' message appears, or q to cancel: " answer
		[[ "${answer,,}" != "q" ]] || die "Cancelled by user"
	fi
}

run_tool() {
	local operation=$1

	echo
	echo ">>> $FLASH_WRITER_TOOL $TEMP_CONFIG $operation"
	"$FLASH_WRITER_TOOL" "$TEMP_CONFIG" "$operation"
}

run_verified() {
	local operation=$1
	local description=$2
	local offset
	local pattern

	offset="$(serial_log_size)"
	if [[ "$VERIFY_MODE" == "auto" ]]; then
		assert_serial_reader_available "$SERIAL_MONITOR_PID"
	fi
	if [[ "$operation" == "fw" ]]; then
		AUTO=true run_tool "$operation"
	else
		run_tool "$operation"
	fi
	drain_serial_output

	if [[ "$VERIFY_MODE" == "auto" ]]; then
		pattern="$(operation_pattern "$operation")"
		wait_for_pattern "$description" "$pattern" "$offset"
		if [[ "$operation" == "emmc_config" ]]; then
			require_final_logged_pattern \
				"eMMC BOOT_BUS_CONDITIONS" \
				"${VERIFY_EMMC_CONFIG_B1_RESULT_PATTERN:-}" \
				"${VERIFY_EMMC_CONFIG_B1_PATTERN:-}" \
				2 \
				"$offset"
			require_final_logged_pattern \
				"eMMC PARTITION_CONFIG" \
				"${VERIFY_EMMC_CONFIG_RESULT_PATTERN:-}" \
				"$pattern" \
				2 \
				"$offset"
		fi
	else
		confirm_target_result "$description"
	fi
}

load_flash_writer() {
	local mode=$1

	wait_for_download_mode "$mode"
	run_verified fw "Flash Writer startup"
}

program_flash_writer() {
	local config=$1

	check_prerequisites "$config"
	make_target_config "$config" 0
	load_verification_settings
	validate_verification_profile fw
	start_serial_monitor
	load_flash_writer "Load Flash Writer"

	echo
	echo "Flash Writer startup has been verified."
}

program_spi() {
	local config=$1

	check_prerequisites "$config"
	make_target_config "$config" 0
	load_verification_settings
	validate_verification_profile fw bl2 fip
	start_serial_monitor
	load_flash_writer "Program SPI Flash"
	run_verified bl2 "BL2 programming"
	run_verified fip "FIP programming"

	echo
	echo "SPI programming commands have been sent. Check the target Flash Writer output for the result."
}

program_emmc() {
	local config=$1

	check_prerequisites "$config"
	make_target_config "$config" 1
	load_verification_settings
	validate_verification_profile fw bl2 fip emmc_config
	start_serial_monitor
	load_flash_writer "Program eMMC"
	run_verified bl2 "BL2 programming"
	run_verified fip "FIP programming"
	run_verified emmc_config "eMMC boot setup"

	echo
	echo "eMMC programming commands have been sent. Check the target Flash Writer output for the result."
}

confirm_erase() {
	local part=$1
	local prompt
	local answer

	case "$part" in
		user)  prompt="User Partition" ;;
		boot1) prompt="Boot Partition 1" ;;
		boot2) prompt="Boot Partition 2" ;;
		all)   prompt="Boot1, Boot2, and the entire User Partition" ;;
		*)     die "Invalid eMMC partition: $part" ;;
	esac

	echo
	echo "WARNING: This will erase eMMC $prompt. The data cannot be recovered."
	read -r -p 'Type ERASE to confirm; any other input cancels: ' answer
	[[ "$answer" == "ERASE" ]] || die "Cancelled by user"
}

erase_emmc() {
	local part=$1
	local config=$2

	check_prerequisites "$config"
	make_target_config "$config" 1
	load_verification_settings
	validate_verification_profile fw x0
	confirm_erase "$part"
	start_serial_monitor
	load_flash_writer "Erase eMMC"

	case "$part" in
		user)  run_verified x0 "User Partition erase" ;;
		boot1) run_verified x1 "Boot Partition 1 erase" ;;
		boot2) run_verified x2 "Boot Partition 2 erase" ;;
		all)
			run_verified x1 "Boot Partition 1 erase"
			run_verified x2 "Boot Partition 2 erase"
			run_verified x0 "User Partition erase"
			;;
	esac

	echo
	echo "eMMC erase commands have been sent. Check the target Flash Writer output for the result."
}

select_erase_part() {
	local choice

	echo "1) User Partition"
	echo "2) Boot Partition 1"
	echo "3) Boot Partition 2"
	echo "4) All partitions"
	read -r -p "Select the erase target [1-4]: " choice

	case "$choice" in
		1) SELECTED_ERASE_PART=user ;;
		2) SELECTED_ERASE_PART=boot1 ;;
		3) SELECTED_ERASE_PART=boot2 ;;
		4) SELECTED_ERASE_PART=all ;;
		*) die "Invalid selection: $choice" ;;
	esac
}

interactive_menu() {
	local config=$1
	local choice

	echo "Config file: $config"
	echo "1) Program SPI Flash"
	echo "2) Program eMMC"
	echo "3) Erase eMMC"
	echo "4) Exit"
	read -r -p "Select an operation [1-4]: " choice

	case "$choice" in
		1) program_spi "$config" ;;
		2) program_emmc "$config" ;;
		3)
			select_erase_part
			erase_emmc "$SELECTED_ERASE_PART" "$config"
			;;
		4) exit 0 ;;
		*) die "Invalid selection: $choice" ;;
	esac
}

main() {
	local command=${1:-menu}
	local config
	local part

	case "$command" in
		config)
			[[ $# -eq 1 ]] || die "The config command does not take arguments"
			launch_config_gui
			;;
		fw)
			select_config "${2:-}"
			config=$ACTIVE_CONFIG
			program_flash_writer "$config"
			;;
		spi)
			select_config "${2:-}"
			config=$ACTIVE_CONFIG
			program_spi "$config"
			;;
		emmc)
			select_config "${2:-}"
			config=$ACTIVE_CONFIG
			program_emmc "$config"
			;;
		erase-emmc|erase)
			part=${2:-}
			[[ -n "$part" ]] || die "Specify user, boot1, boot2, or all"
			select_config "${3:-}"
			config=$ACTIVE_CONFIG
			erase_emmc "$part" "$config"
			;;
		menu)
			select_config "${2:-}"
			config=$ACTIVE_CONFIG
			interactive_menu "$config"
			;;
		-h|--help|help)
			usage
			;;
		*)
			usage >&2
			die "Unknown operation: $command"
			;;
	esac
}

main "$@"
