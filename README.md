# CMP 90HX 10GB 临时算力解锁包

本包仅支持下面的组合：

- `PCI device=10de:220d`
- `subsystem=10de:1555`
- 原生显存 `10240 MiB`
- VBIOS `94.02.74.00.01`
- NVIDIA Open Driver `580.159.03`
- x86_64 Linux、systemd、可用 PCIe FLR
- 单 NVIDIA GPU、无图形桌面占用、Secure Boot 已关闭

不支持其他 90HX 子系统、其他驱动版本、多 GPU、170HX、50HX 或显存解锁。
脚本不会安装或替换系统驱动；候选 `nvidia.ko` 只临时加载一次，成功后仍由
系统原厂 `580.159.03` 模块运行。完全断电后通常会恢复锁定，需要重新执行。

## 1. 安装依赖

Ubuntu/Debian：

```bash
sudo apt update
sudo apt install -y build-essential git jq kmod pciutils psmisc python3 \
  linux-headers-$(uname -r)
```

确认当前使用 NVIDIA Open `580.159.03`，并关闭 Secure Boot。

## 2. 构建临时候选模块

在本目录执行：

```bash
./build-candidate.sh
```

脚本会下载 NVIDIA 官方 `580.159.03` Open Kernel Modules、应用本包 V67
补丁并只生成临时候选模块：

```text
artifacts/nvidia-v67-<当前内核>.ko
```

不要执行 `make modules_install`，不要覆盖系统模块。

## 3. 生成本机身份配置

```bash
sudo ./configure.sh
```

只有机器上恰好存在一张 `220d / 10de:1555`、10240 MiB、指定 VBIOS、
驱动 580.159.03 的 GPU 时才会生成 `config.env`。该文件绑定本机 BDF、
UUID、内核及原厂/候选模块 SHA-256。

## 4. 只做预检

先退出所有 CUDA、矿工、桌面和 GPU 监控进程，然后执行：

```bash
sudo ./unlock.sh preflight-only
```

看到下面结果才继续：

```text
PASS_CMP90HX_UNLOCK_PREFLIGHT_ONLY
```

## 5. 解锁

必须从本机控制台或带远程电源控制的终端执行：

```bash
sudo ./unlock.sh run
```

成功结果：

```text
PASS_CMP90HX_COMPUTE_UNLOCK_FULL_SPEED
```

脚本会依次临时打开 `FEAT_OVR_PLM`，写入已验证的两个算力 selector，执行
FLR，重新加载系统原厂模块，并确认 RM 九项 issue rate 全部为 `0/full`。
显存容量和显存配置不变。

## 实际修改的寄存器

解锁过程只修改下面三个 GA102 BAR0 寄存器：

| 地址 | 名称 | 修改前 | 修改后 | 用途 |
|---:|---|---:|---:|---|
| `0x00823804` | `FEAT_OVR_PLM` | `0xffffff8f` | `0xffffffff` | 临时开放 feature override 的受保护写权限；由 V67 候选模块完成 |
| `0x00823820` | `FEAT_OVR_SM_SPD_1` | `0x00000000` | `0x00000008` | 设置第九项 SM issue-rate selector 为 full-speed 编码 |
| `0x0082381c` | `FEAT_OVR_SM_SPD` | `0x23756124` 或 `0x23756134` | `0x88888888` | 设置其余八项 SM issue-rate selector 为 full-speed 编码 |

两个算力 selector 的固定写入顺序为：先 `0x00823820`，再
`0x0082381c`。每次写入都会立即读回、等待 20 ms 后再次读回；任一读数不
一致即停止。随后执行一次 PCIe FLR，再加载系统原厂驱动并通过 RM 确认：

- `DP`、`FFMA`、`FMLA16/32`、`IMLA0–4` 九项全部为 `0/full`；
- `0x00823818 FEAT_READOUT_1` 是联动状态寄存器，脚本不直接写它；
- `0x00504204 SM_ISSUE_RATE_MODIFIER` 仅用于状态观察，不是写入目标。

明确不会修改：

- `0x009a0204 FBPA_CFG1`；
- `0x00100ce0 LOCAL_MEMORY_RANGE`；
- VBIOS、PCI identity、显存容量/profile、ECC、NVLink；
- `FUSE_*` OTP 熔丝。

因此成功后仍为原生 `10240 MiB` 显存，只解除计算 issue-rate 限制。

## 6. 验证

```bash
sudo ./verify.sh
```

成功结果：

```text
PASS_CMP90HX_FULL_SPEED
```

每次执行日志保存在 `runs/`。

## 恢复原生锁定状态

成功解锁跨 FLR 和驱动重载保持，普通重载驱动不能恢复锁定。要恢复原生
状态：

```bash
sudo systemctl poweroff
```

关机后切断整机 AC 电源至少 30 秒，再重新上电。启动后运行：

```bash
sudo ./verify.sh --expect locked
```

## 停止条件

若脚本未输出 PASS，不要重复执行。保留 `runs/`，完全断电恢复。出现 Xid、
GPU 掉总线、Fatal AER、MMU Fault、机器失联或候选身份不匹配时，立即停止。
脚本在改变设备状态前会武装 10 分钟自动关机恢复计时器；成功后自动解除。
