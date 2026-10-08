#!/bin/sh
# ============================================================
# CI 预检:在本地把 CI 会做的关键检查全部跑一遍
# 目的:不再靠"推上去等 CI 报错"来发现问题
# ============================================================
# 自动定位仓库(不写死本机路径)
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/.." && pwd)"
# 固件仓库:允许用环境变量指定;找不到就跳过那几项
FW="${OPENFI_FW_TREE:-$PKG/../immortalwrt-mt798x-6.6}"
FAIL=0
ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }
warn() { printf '  ⚠️  %s\n' "$1"; }

echo "═══════ ① feed 扫描器会认几个包(这是上次的真因)═══════"
cd "$PKG"
N=$(find . -maxdepth 2 -name Makefile -path './luci-app-openfi-*' 2>/dev/null \
    | xargs grep -lE 'call (BuildTarget|Build/DefaultTargets|BuildPackage|KernelPackage)' 2>/dev/null | wc -l)
find . -maxdepth 2 -name Makefile -path './luci-app-openfi-*' 2>/dev/null \
    | xargs grep -lE 'call (BuildTarget|Build/DefaultTargets|BuildPackage|KernelPackage)' 2>/dev/null | sed 's/^/      /'
[ "$N" -eq 3 ] && ok "三个包全被扫描器识别" || bad "只有 $N 个包被识别(必须 3 个)"

echo
echo "═══════ ② 磁盘上的文件 vs git 跟踪(.gitignore 陷阱)═══════"
for d in luci-app-openfi-fan luci-app-openfi-modem luci-app-openfi-sms; do
  find "$d" -type f 2>/dev/null | sort > /tmp/pf-disk.txt
  git ls-files "$d" 2>/dev/null | sort > /tmp/pf-git.txt
  if diff -q /tmp/pf-disk.txt /tmp/pf-git.txt >/dev/null 2>&1; then
    ok "$d:磁盘文件与 git 完全一致($(wc -l < /tmp/pf-git.txt) 个)"
  else
    bad "$d:有不一致(CI 里会丢文件)"
    diff /tmp/pf-disk.txt /tmp/pf-git.txt 2>/dev/null | sed 's/^/        /'
  fi
done

echo
echo "═══════ ③ 三个 Makefile 的可解析性 + 关键字段 ═══════"
for p in fan modem sms; do
  f="luci-app-openfi-$p/Makefile"
  miss=""
  for k in 'PKG_NAME' 'PKG_VERSION' 'PKG_RELEASE' 'LUCI_TITLE' 'LUCI_DEPENDS' 'LUCI_PKGARCH' 'LUCI_MINIFY_JS' 'include $(INCLUDE_DIR)/package.mk' 'include $(TOPDIR)/feeds/luci/luci.mk' 'call BuildPackage'; do
    grep -qF "$k" "$f" 2>/dev/null || miss="$miss [$k]"
  done
  # 括号检查(标题里不该有 ASCII 括号)
  br=$(grep '^LUCI_TITLE' "$f" | grep -c '[()]')
  [ -n "$miss" ] && bad "$p 缺:$miss" || ok "$p 字段齐全"
  [ "$br" -gt 0 ] && warn "$p 的 LUCI_TITLE 里有括号"
done

echo
echo "═══════ ④ workflow YAML 合法性 ═══════"
for w in "$PKG/.github/workflows/build.yml" "$FW/.github/workflows/build.yml"; do
  python3 -c "import yaml,sys; yaml.safe_load(open('$w')); print('  ✅ $w')" 2>&1 | tail -1
done

echo
echo "═══════ ⑤ 所有 shell 脚本语法 ═══════"
N=0; E=0
for f in $(find "$PKG" -name '*.sh' -o -path '*/usr/sbin/*' -o -path '*/etc/init.d/*' 2>/dev/null | grep -v '\.git'); do
  [ -f "$f" ] || continue
  head -c 2 "$f" 2>/dev/null | grep -q '#!' || continue
  N=$((N+1))
  sh -n "$f" 2>/dev/null || { bad "语法错误: $f"; E=$((E+1)); }
done
[ "$E" -eq 0 ] && ok "$N 个 shell 脚本语法全对"

echo
echo "═══════ ⑥ 回归测试 ═══════"
cd "$PKG" && sh tests/run.sh 2>&1 | tail -3 | sed 's/^/      /'
cd "$FW" && sh tests/test-usbmode.sh 2>&1 | tail -2 | sed 's/^/      /'

echo
echo "═══════ ⑦ 固件仓库:files/ 有没有进 git ═══════"
cd "$FW"
N=$(git ls-files files/ 2>/dev/null | grep -c usbmode)
[ "$N" -eq 3 ] && ok "3 个 usbmode 文件都在 git 里" || bad "只有 $N 个(必须 3 个)"

echo
echo "═══════ ⑧ defconfig 里 CI 会断言的符号 ═══════"
for k in kmod-usb-net-cdc-ncm kmod-usb-net-cdc-mbim kmod-usb-net-rndis kmod-usb-net-cdc-ether umbim; do
  grep -q "^CONFIG_PACKAGE_${k}=y" defconfig/openfi6c.config && ok "$k" || warn "$k 不在 defconfig(CI 只会警告)"
done
grep -q '^# CONFIG_TARGET_ROOTFS_INITRAMFS is not set' defconfig/openfi6c.config && ok "initramfs 已关" || bad "initramfs 又被打开了"
grep -q '^CONFIG_CCACHE=y' defconfig/openfi6c.config && ok "ccache 开着" || warn "ccache 没开"

echo
echo "═══════ ⑨ feed 扫描器模拟:整棵树 + 每个包目录 ═══════"
cd "$PKG"
for p in fan modem sms; do
  # 模拟 scan.mk 的行为:对每个 Makefile 跑一次"能否被 grep 命中"
  if grep -qaE 'call (BuildTarget|Build/DefaultTargets|BuildPackage|KernelPackage)' "luci-app-openfi-$p/Makefile"; then
    ok "luci-app-openfi-$p → 会被索引"
  else
    bad "luci-app-openfi-$p → 不会被索引"
  fi
done

echo
echo "════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ 预检通过 —— 可以推了"
else
  echo "  ❌ 预检发现 $FAIL 个问题 —— 先修再推,别浪费 CI"
fi
