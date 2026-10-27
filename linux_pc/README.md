Linux Setup

$ sudo apt install python3 python3-pip python3-venv

$ python3 -m venv .venv

$ source .venv/bin/active

(.venv) pi@bpi-ai2h:~/$ pip3 install -r requirements.txt

(.venv) pi@bpi-ai2h:~/$ source ../env.sh ai2n

(.venv) pi@bpi-ai2h:~/$ ./flash ai2n xspi

For RZ/G3L SMARC, select the G3L bootloader directory and program SPI or eMMC:

    $ source ../env.sh g3l
    $ ./flash.sh g3l xspi
    $ ./flash.sh g3l emmc

    Please power on the board and ensure the DIP switches are set to SCIF Download Mode. Press RESET if available (on EVK boards); otherwise, power-cycle (e.g., toggle the POWER switch or unplug/replug power).

When you see the following message, switch the DIP switches to SCIF Download Mode, then power on or reset the board, and the download process will start automatically and complete by itself.
