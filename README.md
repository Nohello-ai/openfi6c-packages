# openfi6c-packages

OpenFi 6C（MT7981B）的 LuCI 插件集合。**独立仓库**，跟固件树解耦 ——
改一个页面不用动固件仓库，编出来的包也能单独装到已经刷好的机器上。

## 包含哪些包

| 包 | 菜单 | 干什么 |
|---|---|---|
| **`luci-app-openfi-modem`** | 移动网络 → 模组信息与卡槽 | 读 5G 模组的 AT 口：型号/固件/IMEI/SIM 状态/卡槽/运营商/制式/信号（CSQ·dBm·RSRP）/模块温度；支持 SIM 卡槽切换、模组软重启 |
| **`luci-app-openfi-fan`** | 散热 → 风扇控制 | **风扇**：四点温度曲线 + 手动转速 + 最低转速 + 紧急全速 + 低温停转 + 采样周期；实时状态与 SVG 曲线预览。**灯光**：不再自带页面，用 LuCI 系统自带的 **系统 → LED 配置**；`openfi-led` 只在开机/保存配置/静默模式下应用一次 |

两个包都是 `Architecture: all`（纯脚本 + 前端），跟 CPU 架构无关。

## 设计原则

- **不依赖额外软件包**：只吃 busybox（`sh` / `awk` / `cat` / `pgrep`）。不用 `lm-sensors`、不用 `picocom`、不用 `sms_tool`。
- **不碰 QModem**：QModem 那套「拨号 + 硬件流量卸载」有已知重启问题，这两个包只读状态 / 控制风扇，不参与拨号。
- **零自定义 CSS**：布局全走 LuCI 标准 class，SVG 用 `currentColor` → **自动跟随主题**（bootstrap / argon / material 都行）。
- **守护进程兜底校验**：页面校验只管体验，真正的安全边界在守护进程里（配置非法就退回默认曲线）。
- **状态灯不需要守护进程**：四盏灯是普通 GPIO 且无 `default-trigger`，开机跑一次 `openfi-led apply`、保存配置再跑一次就够，不用像厂商那样 2 秒轮询。

## 当 feed 用

```
# 固件树里
echo "src-git openfi6c https://github.com/Nohello-ai/openfi6c-packages.git" >> feeds.conf.default
./scripts/feeds update openfi6c
./scripts/feeds install -a -p openfi6c
```

然后在 defconfig 里选：

```
CONFIG_PACKAGE_luci-app-openfi-modem=y
CONFIG_PACKAGE_luci-app-openfi-fan=y
```

## 单独装到已刷好的机器

包是 `all` 架构，不挑 CPU，但要**匹配包管理器**：

| 固件 | 包格式 | 装法 |
|---|---|---|
| OpenWrt/ImmortalWrt **24.10 及更早** | `.ipk` (opkg) | `opkg install ./xxx.ipk` |
| OpenWrt/ImmortalWrt **25.12 及更新** | `.apk` (apk-tools 3) | `apk add --allow-untrusted ./xxx.apk` |

## 注意

- `luci-app-openfi-fan` 用 `/etc/config/openfi`（`config fan`），只依赖 busybox。
- 这块板子两路 PWM 是**反向**的（duty 0 = 全速），且**不由内核 pwm-fan 驱动接管** ——
  设备树里 `pwm-fan` 已置 `disabled`，两路 PWM 由 `openfi-fan` 独占。
- 页面菜单用的是 LuCI 新版的 `menu.d` 格式（`depends.acl` 必须是**数组**），
  24.10 和 25.12 都是。写成对象会让整个 LuCI 500。
