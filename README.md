# CMP90HX 580.159.03 持久化算力解锁

本项目仅适用于 NVIDIA Open Kernel Modules `580.159.03` 上、PCI ID 为
`10de:220d` 且子系统 ID 为 `10de:1555` 的 CMP90HX。支持一张或多张匹配卡。

它不修改 VBIOS、显存容量、FBPA、LMR、ECC 或 OTP 熔丝，只写入已验证的两项
计算 issue-rate selector。

## 工作方式

每次冷启动或热启动时：

1. initramfs 先加载本项目生成的专用 `nvidia.ko.bootstrap`；它在 GSP 的精确
   预启动时点打开 PLM，并为每张匹配卡写入计算 selector。
2. `cmp90hx-persistent.service` 等待内核读回成功标记，自动卸载引导模块、对每张
   卡执行 PCIe FLR。
3. 服务自动加载安装前备份的原厂 `nvidia.ko`，因此运行时保持 NVIDIA 的正常
   GSP 初始化路径，同时保留已写入的算力状态。

这个“专用启动驱动 + 自动 FLR + 原厂运行驱动”的交接，等价于已验证的临时流程，
但无需人工执行候选模块、BAR0 工具、FLR 或重新加载驱动。

## 安装

```bash
cd /root/t1
sudo ./install.sh
sudo reboot
```

安装脚本会：

- 在首次安装时备份当前原厂模块到
  `/lib/modules/$(uname -r)/updates/cmp90hx-persistent/backup/nvidia.ko.stock`；
- 编译并安装引导专用模块、保存其 `nvidia.ko.bootstrap` 副本；
- 写入启动参数、systemd 交接服务、模块依赖和 initramfs；
- 枚举所有匹配卡并保存 BDF 清单。

Secure Boot 开启时，脚本会拒绝安装未签名模块。

## 验证

启动完成后运行：

```bash
sudo ./verify.sh
```

它会确认所有已安装清单中的卡均在线、当次启动存在每张卡的 selector 成功标记，且
交接服务已完成。若需完整 issue-rate 读回，可执行：

```bash
python3 scripts/rm_issue_rate_query.py --bdf 0000:01:00.0 \
  --uuid "$(nvidia-smi --query-gpu=uuid --format=csv,noheader)" \
  --driver 580.159.03 --memory-mib 10240 --expect full
```

## 卸载与回退

```bash
sudo ./remove.sh --yes
sudo reboot
```

`remove.sh` 会停止并删除交接服务、删除本项目的模块覆盖和启动参数、重建
initramfs。发行版原厂模块未被覆盖，因此重启后恢复原生受限状态。

## 支持范围与限制

- 仅 `10de:220d / 10de:1555`、NVIDIA Open `580.159.03`；
- 必须是 x86_64 Linux、systemd，并支持 PCIe FLR；
- 支持多张完全匹配的卡；
- 不提供显存解锁或 170HX 项目的其他附加功能；
- 内核或 NVIDIA 驱动升级后，请在新内核/新版本上重新验证后再运行安装脚本。
