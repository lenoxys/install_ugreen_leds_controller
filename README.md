## Ugreen LED Controller Installer

This repository contains a bash script to install the necessary software for controlling Ugreen LED controllers.

## Quick Installation
**Always validate what the script does before running**</br>

⚠️ **Important:** The script must be run from a directory under `/mnt/<POOL_NAME>/`. It will not work if run from `/home` or other locations.

Run the following command to download and install in one step:</br>
```bash
cd /mnt/<YOUR_POOL_NAME>
curl -fsSL https://raw.githubusercontent.com/lenoxys/install_ugreen_leds_controller/main/install_ugreen_leds_controller.sh | sudo bash -s
```
**What This Installer does:**

- Clones the [ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) repository
- Copies the files to the required locations and loads the kernel modules
- Starts the service

## Key Features

- **Configuration Updates**: On re-installation, the script properly applies new configurations by stopping and restarting services
- **Service Management**: Automatically stops old services before replacing them with updated versions
- **Network Detection**: Automatically detects available network interfaces and allows user selection for network device monitoring
- **Conditional Service Setup**: 
  - `ugreen-diskiomon` - Always enabled (disk activity monitoring)
  - `ugreen-netdevmon` - Always enabled on selected interface (network activity monitoring)
  - `ugreen-power-led` - Conditionally enabled based on configuration (power LED control)

## Usage

⚠️ **Important:** The script must be run from a directory under `/mnt/<POOL_NAME>/`. It will not work if run from `/home` or other locations.

**Run the Script:**
```bash
cd /mnt/<YOUR_POOL_NAME>
./install_ugreen_leds_controller.sh
```
**Show Help:**
```bash
./install_ugreen_leds_controller.sh -h
```
**Define your TrueNAS version:**</br>
This is helpful in cases like this [issue](https://github.com/0x556c79/install_ugreen_leds_controller/issues/1) where the kernel headers have not changed, but there is no packages index to give us the headers' version.
```bash
./install_ugreen_leds_controller.sh -v 24.10.0.2
```

## Manual installation

There are two ways to use this script:

**1. Clone the repository:**

```bash
git clone https://github.com/0x556c79/install_ugreen_leds_controller.git
cd install-ugreen-leds-controller
```

**2. Copy the script:**

* Visit the raw script URL: [https://raw.githubusercontent.com/.../install_ugreen_leds_controller.sh](https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/refs/heads/main/install_ugreen_leds_controller.sh)
* Copy the entire script content.
* Paste the content into a new file named `install_ugreen_leds_controller.sh`.
* Or use curl
```bash
  curl https://raw.githubusercontent.com/0x556c79/install_ugreen_leds_controller/refs/heads/main/install_ugreen_leds_controller.sh -o install_ugreen_leds_controller.sh
```

**Make the script executable:**

```bash
chmod +x install_ugreen_leds_controller.sh
```

**Run the script from a pool directory:**

⚠️ **Important:** Navigate to a directory under `/mnt/<POOL_NAME>/` before running the script. The script will not work if run from `/home` or other locations.

```bash
cd /mnt/<YOUR_POOL_NAME>
./install_ugreen_leds_controller.sh
```

**Note:** This script might require administrative privileges (sudo) depending on your system configuration. 

**Important Directory Requirement:** The script must be executed from a pool directory (`/mnt/<POOL_NAME>/`). Running from other locations like `/home` will result in an error and the script will not proceed. 

This script will download and install the necessary software from [https://github.com/miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) to control your Ugreen LED controller.

**Disclaimer:** 

Createt and tested on a Ugreen DXP8800 Plus NAS.
Use this script at your own risk. The author is not responsible for any damage caused by running this script.
