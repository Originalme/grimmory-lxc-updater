# Grimmory LXC Updater

This utility helps update the [Grimmory](https://github.com/grimmory-tools/grimmory) application running in an [Linux Container (LXC)](https://linuxcontainers.org/) under [Proxmox](https://www.proxmox.com/). I take no credit for this, as it was originally spun off the [Booklore "community-scripts.org"](https://community-scripts.org/scripts/booklore) script and has been updated by multiple people since then.

## Usage

### Backup

Before running any of the scripts below, it is recommended to perform a full backup of your LXC configuration and data partitions!

### Quick Start

1. Run the command below to create an "update" script to `/usr/bin/bash` 
   ```bash
   echo 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/Originalme/grimmory-lxc-updater/refs/heads/main/update.sh)"' > '/usr/bin/update'; chmod +x '/usr/bin/update'
   ```

2. Execute `update` command and follow the promts

### Manual Setup

1. Create a file called `update`

2. Add the line below into the file
   ```bash
   echo 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/Originalme/grimmory-lxc-updater/refs/heads/main/update.sh)"'
   ```

3. Mark the file as executable

4. Execute the script, and follow the prompts

## Contributions ( in no particular order)

- [dalenjohnson](https://github.com/dalenjohnson)
- [databoy2k](https://gist.github.com/databoy2k)
- [imnotjames](https://github.com/imnotjames)