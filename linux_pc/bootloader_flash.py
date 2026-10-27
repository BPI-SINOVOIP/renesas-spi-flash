#!/usr/bin/env python3

# Imports
import serial
import argparse
import time
import os
from serial.tools.list_ports import comports
import sys
if sys.version_info >= (3, 11):  # pragma: Python version >=3.11
    import tomllib
else:  # pragma: Python version <3.11
    import tomli as tomllib

class BootloaderFlashUtil:
	def __init__(self, args=[]):
		self.__scriptDir = os.path.dirname(os.path.abspath(__file__))
		self.__rootDir = os.path.abspath(os.path.join(self.__scriptDir, '..', '..', '..'))
		self.__imagesDir = os.path.abspath(os.path.join(self.__rootDir, 'target', 'images'))

		self.__setupArgumentParser(args)
		self.__getFlashAddress()
		self.__setupSerialPort()

	# Setup CLI parser
	def __setupArgumentParser(self, args=[]):
		# Create parser
		self.__parser = argparse.ArgumentParser(description='Util to flash bootloader on RZ Board.\n', epilog='Example:\n\t./bootloader_flash.py')

		# Add arguments
		# Board name
		self.__parser.add_argument('--board_name',
									default='rzg2l-sbc',
									dest='boardName',
									action='store',
									type=str,
									help='Board name to flash bootloader (defaults to: rzg2l-sbc).')
		self.__parser.add_argument('--flash_method',
									default='xspi',
									dest='flashMethod',
									action='store',
									type=str,
									choices=['emmc', 'xspi', 'esd'],
									help='Flash method to use (defaults to: xspi).')

		# Serial port arguments
		self.__parser.add_argument('--serial_port',
									default=None,
									dest='serialPort',
									action='store',
									help='Serial port used to talk to board (defaults to: most recently connected port).')
		self.__parser.add_argument('--serial_port_baud',
									default=115200,
									dest='baudRate',
									action='store',
									type=int,
									help='Baud rate for serial port (defaults to: 115200).')

		# Images
		self.__parser.add_argument('--image_writer',
									default=f'{self.__imagesDir}/Flash_Writer_SCIF_rzg2l-sbc.mot',
									dest='flashWriterImage',
									action='store',
									type=str,
									help="Path to Flash Writer image (defaults to: <path/to/your/package>/target/images/Flash_Writer_SCIF_rzg2l-sbc.mot).")
		self.__parser.add_argument('--image_bl2',
									default=f'{self.__imagesDir}/bl2_bp_rzg2l-sbc.srec',
									dest='bl2Image',
									action='store',
									type=str,
									help='Path to bl2 image (defaults to: <path/to/your/package>/target/images/bl2_bp_rzg2l-sbc.srec).')
		self.__parser.add_argument('--image_fip',
									default=f'{self.__imagesDir}/fip_rzg2l-sbc.srec',
									dest='fipImage',
									action='store',
									type=str,
									help='Path to FIP image (defaults to: <path/to/your/package>/target/images/fip_rzg2l-sbc.srec).')
		self.__parser.add_argument('--image_bid',
									default=f'{self.__imagesDir}/rzg2l-sbc-platform-settings.bin',
									dest='bidImage',
									action='store',
									type=str,
									help='Path to board identification image (defaults to: <path/to/your/package>/target/images/rzg2l-sbc-platform-settings.bin).')

		if args:
			self.__args = self.__parser.parse_args(args)
		else:
			self.__args = self.__parser.parse_args()

	# Setup Serial Port
	def __setupSerialPort(self):
		try:
			if (self.__args.serialPort is None):
				ports = [port.device for port in comports()]
				print(f"Available serial ports: {ports}")
				print(f"Using serial port: {ports[0]}")
				self.__serialPort = serial.Serial(port= ports[0], baudrate = self.__args.baudRate, timeout=60)
			else:
				self.__serialPort = serial.Serial(port=self.__args.serialPort, baudrate = self.__args.baudRate, timeout=60)

		except:
			die(msg='Unable to open serial port.')

	def __getFlashAddress(self):
		configFile = os.path.join(self.__scriptDir, "." , "config", 'boards_flash_config.toml')
		with open(configFile, "rb") as f:
			flash_info = tomllib.load(f)

		self.__flashAddress = flash_info.get(self.__args.boardName)

		if self.__flashAddress is None:
			die(msg=f"Board name {self.__args.boardName} is not supported.")
		if self.__args.flashMethod not in self.__flashAddress:
			die(msg=f"Flash method {self.__args.flashMethod} is not configured for {self.__args.boardName}.")

	# Setup Serial Port SUP
	def __setupSerialPort_SUP(self):
		try:
			self.__serialPort.baudrate = 921600
		except:
			die(msg='Unable to open serial port 921600 bps.')

	def __wait_for_prompt(self, timeout=30, required=None):
		end_time = time.time() + timeout
		buffer = b""
		sent_y = False

		while time.time() < end_time:
			if self.__serialPort.in_waiting:
				buffer += self.__serialPort.read(self.__serialPort.in_waiting)
				decoded = buffer.decode(errors='ignore')

				if not sent_y and "Clear OK" in decoded:
					self.__writeSerialCmd('y')
					sent_y = True  # prevent sending again

				if ">" in decoded:
					if required is not None and required not in decoded:
						die(msg=f"Target prompt arrived without the expected result: {required}")
					print(decoded)
					return

			time.sleep(0.1)

		decoded = buffer.decode(errors='ignore')
		print(decoded)
		die(msg="Timed out waiting for the Flash Writer prompt.")

	# Function to write bootloader
	def writeBootloader(self):
		start_time = time.time()

		# Check file exists
		if not os.path.exists(self.__args.flashWriterImage):
			print(f"The file {self.__args.flashWriterImage} does not exist.")
			exit()
		if not os.path.exists(self.__args.bl2Image):
			print(f"The file {self.__args.bl2Image} does not exist.")
			exit()
		if not os.path.exists(self.__args.fipImage):
			print(f"The file {self.__args.fipImage} does not exist.")
			exit()
		#if not os.path.exists(self.__args.bidImage):
		#	print(f"The file {self.__args.bidImage} does not exist.")
		#	exit()

		# Wait for device to be ready to receive image.
		print("Please power on the board and ensure the DIP switches are set to SCIF Download Mode. Press RESET if available (on EVK boards); otherwise, power-cycle (e.g., toggle the POWER switch or unplug/replug power).")

		if self.__args.boardName in (
			"rzv2h-evk",
			"rzg3l-evk",
		):
			self.__serialRead('Load Program to SRAM')
		else:
			self.__serialRead('please send !')

		# Write flash writer application
		time1 = time.time()
		print("Writing Flash Writer application...")
		self.__writeFileToSerial(self.__args.flashWriterImage)
		self.__serialRead('>')

		time2 = time.time()
		elapsed_time = time2 - time1
		print(f"Elapsed time: Flash Writer: {elapsed_time:.6f} seconds")

		self.__writeSerialCmd('')
		self.__serialRead('>')

		# emmc flash
		if (self.__args.flashMethod == "emmc"):
			self.__handle_emmc_flash(self.__flashAddress["emmc"])
		# xspi flasj
		elif (self.__args.flashMethod == "xspi"):
			self.__handle_xspi_flash(self.__flashAddress["xspi"])

		print("Closed serial port.")
		self.__serialPort.close()

		end_time = time.time()
		elapsed_time = end_time - start_time
		print(f"Elapsed time: {elapsed_time:.6f} seconds")

	def __handle_emmc_flash(self, flashAddress):
		if self.__args.boardName not in (
			"rzv2h-evk",
			"rzg3l-evk",
		):
			self.__writeSerialCmd('EM_E')
			self.__serialRead('Select area')
			self.__writeSerialCmd('1')
			self.__serialRead('>')

		# Changing speed to 921600 bps.
		#self.__writeSerialCmd('SUP')
		#self.__serialRead('the terminal.')

		#self.__setupSerialPort_SUP()
		#time.sleep(1)
		self.__writeSerialCmd('')
		self.__serialRead('>')

		# Write BL2
		BL2FlashAddress = flashAddress["BL2"]
		self.__writeSerialCmd('EM_W')
		self.__serialRead('Select area')
		self.__writeSerialCmd(BL2FlashAddress[0])

		self.__serialRead('Please Input Start Address in sector')
		self.__writeSerialCmd(BL2FlashAddress[1])

		self.__serialRead('Please Input Program Start Address')
		self.__writeSerialCmd(BL2FlashAddress[2])
		self.__serialRead('please send !')

		print("Writing BL2...")
		self.__writeFileToSerial(self.__args.bl2Image)
		self.__serialRead('EM_W Complete!')
		self.__serialRead('>')

		# Write FIP
		FIPFlashAddress = flashAddress["FIP"]
		self.__writeSerialCmd('EM_W')
		self.__serialRead('Select area')
		self.__writeSerialCmd(FIPFlashAddress[0])

		self.__serialRead('Please Input Start Address in sector')
		self.__writeSerialCmd(FIPFlashAddress[1])

		self.__serialRead('Please Input Program Start Address')
		self.__writeSerialCmd(FIPFlashAddress[2])
		self.__serialRead('please send !')
		print("Writing fip ...")
		self.__writeFileToSerial(self.__args.fipImage)

		self.__serialRead('EM_W Complete!')
		self.__serialRead('>')

		# Write EXT_CSD
		self.__writeSerialCmd('EM_SECSD')
		self.__serialRead('Please Input EXT_CSD Index')
		self.__writeSerialCmd('B1')
		self.__serialRead('Please Input Value')
		self.__writeSerialCmd(FIPFlashAddress[3])
		self.__serialRead(f'EXT_CSD[B1] = 0x{int(FIPFlashAddress[3], 16):02X}')
		self.__serialRead('>')

		self.__writeSerialCmd('EM_SECSD')
		self.__serialRead('Please Input EXT_CSD Index')
		self.__writeSerialCmd('B3')
		self.__serialRead('Please Input Value')
		self.__writeSerialCmd(FIPFlashAddress[4])
		self.__serialRead(f'EXT_CSD[B3] = 0x{int(FIPFlashAddress[4], 16):02X}')
		self.__serialRead('>')

		# Write board identification
		#BIDFlashAddress = flashAddress["BID"]
		#self.__writeSerialCmd('EM_WB')
		#self.__serialRead('Select area')
		#self.__writeSerialCmd(BIDFlashAddress[0])

		#self.__serialRead('Please Input Start Address in sector')
		#self.__writeSerialCmd(BIDFlashAddress[1])

		#self.__serialRead('Please Input File size(byte)')
		#self.__writeSerialCmd(BIDFlashAddress[2])
		#self.__serialRead('please send binary file!')

		#print("Writing board identification...")
		#self.__writeFileToSerial(self.__args.bidImage)
		#self.__serialRead('>')

	def __handle_xspi_flash(self, flashAddress):
		if self.__args.boardName not in (
			"rzv2h-evk",
			"rzg3l-evk",
		):
			self.__writeSerialCmd('XCS')
			self.__wait_for_prompt(60)

		# Changing speed to 921600 bps.
                # bpi board cannot switch to 921600
		#self.__writeSerialCmd('SUP')
		#self.__serialRead('the terminal.')

		#self.__setupSerialPort_SUP()
		#time.sleep(1)
		self.__writeSerialCmd('')
		self.__serialRead('>')

		# Write BL2
		BL2FlashAddress = flashAddress["BL2"]
		self.__writeSerialCmd('XLS2')
		self.__serialRead('Please Input : H')
		self.__writeSerialCmd(BL2FlashAddress[0])

		self.__serialRead('Please Input : H')
		self.__writeSerialCmd(BL2FlashAddress[1])
		self.__serialRead('please send !')

		print("Writing BL2...")
		self.__writeFileToSerial(self.__args.bl2Image)
		self.__wait_for_prompt(120, 'SpiFlashMemory End Address')

		# Write FIP
		FIPFlashAddress = flashAddress["FIP"]
		self.__writeSerialCmd('XLS2')
		self.__serialRead('Please Input : H')
		self.__writeSerialCmd(FIPFlashAddress[0])

		self.__serialRead('Please Input : H')
		self.__writeSerialCmd(FIPFlashAddress[1])
		self.__serialRead('please send !')

		print("Writing fip ...")
		self.__writeFileToSerial(self.__args.fipImage)
		self.__wait_for_prompt(120, 'SpiFlashMemory End Address')

		# Write board identification
		#BIDFlashAddress = flashAddress["BID"]
		#if (self.__args.bidImage.endswith('.srec')):
		#	self.__writeSerialCmd('XLS2')
		#else:
		#	self.__writeSerialCmd('XLS3')
		#self.__serialRead('Please Input : H')
		#self.__writeSerialCmd(BIDFlashAddress[0])

		#self.__serialRead('Please Input : H')
		#self.__writeSerialCmd(BIDFlashAddress[1])
		#self.__serialRead('please send !')

		#print("Writing board identification...")
		#self.__writeFileToSerial(self.__args.bidImage)
		#self.__wait_for_prompt()

	def __writeSerialCmd(self, cmd):
		self.__serialPort.write(f'{cmd}\r'.encode())

	@staticmethod
	def __formatSize(size):
		value = float(size)
		for unit in ('B', 'KiB', 'MiB', 'GiB'):
			if value < 1024 or unit == 'GiB':
				return f'{value:.1f} {unit}'
			value /= 1024

	@staticmethod
	def __formatDuration(seconds):
		seconds = max(0, int(seconds))
		minutes, seconds = divmod(seconds, 60)
		hours, minutes = divmod(minutes, 60)
		if hours:
			return f'{hours:02d}:{minutes:02d}:{seconds:02d}'
		return f'{minutes:02d}:{seconds:02d}'

	def __printTransferProgress(self, sent, total, startTime):
		elapsed = max(time.monotonic() - startTime, 0.001)
		rate = sent / elapsed
		fraction = sent / total
		barWidth = 30
		filled = min(barWidth, int(fraction * barWidth))
		bar = '#' * filled + '-' * (barWidth - filled)
		if rate > 0:
			rateText = f'{self.__formatSize(rate)}/s'
			etaText = self.__formatDuration((total - sent) / rate)
		else:
			rateText = '--'
			etaText = '--:--'
		status = (
			f'  [{bar}] {fraction * 100:6.2f}%  '
			f'{self.__formatSize(sent)}/{self.__formatSize(total)}  '
			f'{rateText}  ETA {etaText}'
		)
		sys.stdout.write(f'\r{status}')
		sys.stdout.flush()

	# Function to write file over serial
	def __writeFileToSerial(self, file):
		total = os.path.getsize(file)
		if total == 0:
			die(msg=f'Cannot send an empty file: {file}')

		chunkSize = 4096
		sent = 0
		startTime = time.monotonic()
		lastUpdate = 0
		print(f'  File: {os.path.basename(file)} ({self.__formatSize(total)})')
		self.__printTransferProgress(sent, total, startTime)

		with open(file, 'rb') as f:
			while True:
				chunk = f.read(chunkSize)
				if not chunk:
					break

				remaining = memoryview(chunk)
				while remaining:
					written = self.__serialPort.write(remaining)
					if not written:
						die(msg=f'Serial write stopped after {sent} of {total} bytes.')
					sent += written
					remaining = remaining[written:]

				now = time.monotonic()
				if now - lastUpdate >= 0.5 or sent == total:
					self.__printTransferProgress(sent, total, startTime)
					lastUpdate = now

			self.__serialPort.flush()

		print()
		print('  Transfer complete. Waiting for target response...')

	# Function to wait and print contents of serial buffer
	def __serialRead(self, cond='\n'):
		buf = self.__serialPort.read_until(cond.encode())

		if cond.encode() not in buf:
			print(f'{buf.decode(errors="ignore")}')
			die(msg=f"Timed out waiting for target output: {cond}")

		print(f'{buf.decode(errors="ignore")}')

# Util function to die with error
def die(msg='', code=1):
	print(f'Error: {msg}')
	exit(code)

def main():
	bootloaderFlashUtil = BootloaderFlashUtil()

	bootloaderFlashUtil.writeBootloader()

if __name__ == '__main__':
	main()
