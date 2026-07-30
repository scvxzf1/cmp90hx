# CMP90HX 580.159.03 持久化算力解锁

本项目适用于同时满足下列条件的 CMP90HX：

- NVIDIA PCI ID：`10de:220d / 10de:1555`；
- NVIDIA **Open Kernel Modules** 驱动版本：`580.159.03`；
- x86_64 Linux、systemd 和 root 权限。

项目只处理**算力限制**，不修改显存容量、FBPA、LMR、ECC、VBIOS、OTP 或 PCIe 链路速率，也不移植 CMP170HX 的功能。它会自动识别所有符合条件的卡，因此可用于单卡或多卡机器。

> 这是内核驱动和 GPU 复位相关操作。仅应在符合上述硬件与驱动版本的机器上使用；升级 NVIDIA 驱动或内核后，必须重新编译并验证。

## 分支说明

### `main`：日常安装分支

`main` 内含已审核、已应用算力补丁的 NVIDIA `580.159.03` 源码。`install.sh` 直接编译，不会在安装过程中下载源码、执行 Git 操作或应用补丁。

因此，复制完整项目目录到目标机器后可离线安装；Git 和网络仅在你选择用 `git clone` 获取本项目时才需要。

### `dev`：补丁复现与开发分支

`dev` 不携带已修改源码。安装时会下载官方指定的 `580.159.03` 源码提交，并以严格校验方式应用 `patches/0001-58015903-cmp90hx-direct-compute.patch`，随后编译。

该分支需要 `git`、`patch` 与可访问 GitHub 的网络。若需审计或修改补丁，请使用此分支；常规部署请使用 `main`。

## 开机工作流程

安装完成后，`cmp90hx-persistent.service` 会在每次冷启动或热重启时，在 `multi-user.target` 以及可能存在的 `hive.service`、`os-core.service` 之前运行。

服务会按顺序完成以下操作：

1. 使用原始 NVIDIA 驱动确认所有目标 CMP90HX 都可枚举；
2. 暂停 HiveOS 的 `hive.service` / `os-core.service`（若存在且此前处于运行或启用状态）；
3. 每次只处理一张卡：临时加载专用的引导 `nvidia.ko`，在已验证的初始化窗口内写入并回读仅与算力有关的选择器；
4. 对所有目标卡执行两次明确的 PCIe `bus` reset；
5. 重新加载未改动的原始 NVIDIA 驱动，确认所有目标卡恢复在线；
6. 无论批处理成功还是失败，恢复之前暂停的 HiveOS 服务。

正常运行时不会用候选驱动覆盖发行版或 DKMS 的 `nvidia.ko`。安装程序会备份原始模块到：

```text
/lib/modules/$(uname -r)/updates/cmp90hx-persistent/backup/nvidia.ko.stock
```

引导候选模块单独保存为 `nvidia.ko.bootstrap`。多卡按串行方式处理：单卡约需 2 分钟，每增加一张卡通常再增加约 2 分钟；已验证的六卡机器完整开机流程约需 11 分钟。请为多卡机器预留足够的启动时间。

> **重要：** 从 `cmp90hx-persistent.service` 开始运行到批处理完成之前，不要启动任何 GPU 工作负载，也不要手动执行 `nvidia-smi`、矿工、CUDA 程序、GPU 容器或监控程序。请等待 `/run/cmp90hx-persistent-batch.status` 显示所有卡已完成、原始 NVIDIA 驱动恢复上线后，再使用 GPU。启动服务不会调用 `check.sh`，其诊断结果也不会影响 HiveOS / os-core 服务的恢复。

## 安装条件

安装程序会在写入文件前检查环境。目标机器必须具备：

- 已正常工作的 NVIDIA **Open** `580.159.03` 内核模块；
- 至少一张匹配 `10de:220d / 10de:1555` 的 CMP90HX；
- 每张目标卡的 sysfs `reset_method` 中均包含 PCIe `bus`；
- 与正在运行内核匹配的头文件：`/lib/modules/$(uname -r)/build`；
- Secure Boot 已关闭。项目不会为候选模块签名，检测到启用时会拒绝安装；
- `bash`、GNU coreutils、`make`、`gcc`、`ld`、`objcopy`、`sha256sum`、`strings`、`install`、`nproc`、`timeout`、`python3`；
- `kmod` 工具：`modinfo`、`modprobe`、`insmod`、`depmod`；
- `systemctl`。

在 Debian / Ubuntu 上，常见依赖包为：

```bash
sudo apt-get update
sudo apt-get install -y build-essential binutils kmod python3 \
  linux-headers-$(uname -r)
```

HiveOS 的内核头文件包名称可能不同；以安装程序对真实命令和头文件目录的检查结果为准。

`dev` 分支还需要：

```bash
sudo apt-get install -y git patch
```

并要求在安装时能访问 GitHub。可以通过 `CMP90_SOURCE_DIR=/path/to/open-gpu-kernel-modules-580.159.03` 提供未修改的离线官方源码副本。

## 安装

### 使用 `main`（推荐）

```bash
git clone https://github.com/bendy2/cmp90hx.git
cd cmp90hx
sudo ./install.sh
sudo reboot
```

如果项目目录已通过 U 盘、内网文件服务或其他方式完整复制到机器上，从 `cd cmp90hx` 开始即可；`main` 的安装过程本身不需要 Git 或网络。

安装程序会核对驱动版本、GPU ID、`bus` reset 支持和 Secure Boot 状态，备份原始 `nvidia.ko`，编译引导候选模块，安装服务并设置开机启动。它不会替换正在使用的原始驱动。

### 使用 `dev`

```bash
git clone --branch dev https://github.com/bendy2/cmp90hx.git
cd cmp90hx
sudo ./install.sh
sudo reboot
```

`dev` 会下载官方 `580.159.03` 源码提交 `4dbb564094c7a73fe222b9b010d7782638643c65`，先执行 `git apply --check`，再应用补丁和编译。补丁上下文不完全匹配时安装会停止，不会模糊应用。

## 验证

重启完成、正常 NVIDIA 驱动已上线后，先查看服务、批处理状态和 GPU 枚举：

```bash
systemctl status cmp90hx-persistent.service
cat /run/cmp90hx-persistent-batch.status
nvidia-smi -L
sudo ./verify.sh
```

期望看到服务为 `active (exited)`，并且批处理状态包含所有检测到的 CMP90HX 均已完成的记录。

### 可选：检查九项 RM issue-rate 限制

`check.sh` 是独立、只读的诊断工具。它会向 NVIDIA RM 查询每张目标卡的九个 SM issue-rate 字段：`DP`、`FFMA`、`FMLA16`、`FMLA32`、`IMLA0`–`IMLA4`。

```bash
sudo CMP90_CHECK_TIMEOUT_SECONDS=15 ./check.sh
```

每张卡都有超时上限。若私有 RM 查询超时，脚本会输出 `INCONCLUSIVE`；这表示无法在限时内获得诊断数据，**不是**“仍被限制”的结论，也不会改变已完成的开机服务结果。

## 卸载并恢复为原始驱动运行

```bash
sudo ./remove.sh --yes
sudo reboot
```

卸载脚本只删除本项目安装的 systemd 服务、辅助脚本和引导候选模块。由于常规安装从未覆盖厂商的运行时 `nvidia.ko`，重启后将回到仅使用原始驱动的状态。若检测到历史版本曾由本项目替换过驱动模块，脚本会使用已记录的备份恢复它。

## 兼容性与限制

- 支持任意数量的匹配 CMP90HX，但所有卡必须使用相同的 NVIDIA Open `580.159.03` 驱动环境；
- 支持 HiveOS 和非 HiveOS systemd Linux。非 HiveOS 系统没有 `hive.service` / `os-core.service` 时会自动跳过；
- 所有复位操作固定为 PCIe `bus` reset，不使用 FLR 回退；
- 不支持专有 NVIDIA 内核模块、其他驱动版本、其他 GPU 型号或 Secure Boot 已启用且未自行签名的环境；
- 请勿在引导候选驱动尚未完成初始化时运行 `nvidia-smi` 或让其他程序占用 GPU。服务会在完成后才恢复普通 GPU 使用方。
