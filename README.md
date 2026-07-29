# CMP90HX Persistent Compute Unlock

This is the production branch for CMP90HX \`10de:220d / 10de:1555\` with NVIDIA
Open Kernel Modules \`580.159.03\`. It provides only compute unlocking; it does
not change memory capacity, PCIe speed, or CMP170HX-specific features.

This branch contains the audited NVIDIA source with the direct compute patch already
applied. \`install.sh\` compiles it directly: it does not use Git, network access,
or the \`patch\` command.

## Boot flow

The service first confirms that the stock driver sees every exact CMP90HX. It
temporarily defers \`hive.service\` and \`os-core.service\` when present, processes
one target at a time, writes and reads back the compute-only selectors inside the
candidate driver, performs two PCIe \`bus\` resets across all exact cards, and
hands back to the untouched stock driver. The deferred services are restored on
either success or failure.

The runtime \`nvidia.ko\` is never overwritten. The installer saves it at
\`/lib/modules/$(uname -r)/updates/cmp90hx-persistent/backup/nvidia.ko.stock\`.
Expect about two minutes per card. The standalone \`check.sh\` is not part of boot.

## Requirements

- systemd x86_64 Linux, exact CMP90HX IDs, NVIDIA **Open** \`580.159.03\`;
- matching headers at \`/lib/modules/$(uname -r)/build\`, Secure Boot disabled;
- PCIe \`bus\` available in each target GPU's \`reset_method\`;
- \`bash\`, GNU coreutils, \`make\`, \`gcc\`, \`ld\`, \`objcopy\`, \`sha256sum\`,
  \`strings\`, \`install\`, \`modinfo\`, \`modprobe\`, \`insmod\`, \`depmod\`,
  \`nproc\`, \`python3\`, and \`timeout\`.

Debian/Ubuntu example: \`apt-get install -y build-essential python3 linux-headers-$(uname -r)\`.
HiveOS can package its headers differently; the installer checks prerequisites.

## Install / verify / remove

\`\`\`bash
git clone https://github.com/bendy2/cmp90hx.git
cd cmp90hx
sudo ./install.sh
sudo reboot
sudo ./verify.sh
sudo ./check.sh       # optional nine-field RM check
sudo ./remove.sh --yes  # then reboot to return to stock only
\`\`\`

\`check.sh\` prints \`INCONCLUSIVE\` if a private RM read times out; that does not
change the completed service result or affect Hive/os-core services.

## Validated result

On the six-card HiveOS validation host, a formal reboot completed
\`PASS all 6 CMP90HX GPUs completed\`; every card handed back to stock with all
six GPUs enumerated, then \`os-core.service\` was restored.

## Development branch

Use \`dev\` only when you want to download the exact official source and strictly
apply the auditable patch before compilation. It requires Git, network access,
and the \`patch\` utility.
