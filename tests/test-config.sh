#!/bin/sh
#
# 包仓库的结构一致性测试
#
# 这几类问题以前都真实发生过，而它们【运行期不报错】—— 只会静默失效：
#   * 配置里同一个命名段出现两次（uci 忍受，但文件是畸形的）
#   * 前端调用的后端脚本没在 ACL 里授权（页面静默失败）
#   * 菜单 path 指向不存在的视图文件（点进去空白）
#   * 脚本没有执行位（装上去跑不了）
#   * JSON / JS 语法错误
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

cd "$ROOT" || exit 1

# ─────────────────────────────────────────────── 1. 配置段不能重复
echo "  -- 配置段唯一性 --"
for cfg in $(find . -path ./.git -prune -o -name 'openfi*' -path '*/etc/config/*' -print 2>/dev/null); do
	dups="$(grep -oE "^config [a-z]+ '[a-z_]+'" "$cfg" 2>/dev/null | sort | uniq -d)"
	if [ -n "$dups" ]; then
		bad "$cfg 里有重复的命名段：$dups"
	else
		ok "$(basename "$cfg") 没有重复段"
	fi
done

# ─────────────────────────────────────────────── 2. ACL 必须覆盖前端要执行的脚本
echo "  -- ACL 覆盖前端 exec 目标 --"
for pkg in luci-app-openfi-fan luci-app-openfi-modem; do
	[ -d "$pkg" ] || continue
	acl="$(find "$pkg" -path '*acl.d*' -name '*.json' | head -1)"
	[ -n "$acl" ] || { bad "$pkg 没有 ACL 文件"; continue; }

	# 从 JS 里抓 xxx_CMD = '/usr/sbin/yyy'
	for js in $(find "$pkg" -name '*.js' 2>/dev/null); do
		for bin in $(grep -oE "'/usr/sbin/[a-z0-9-]+'" "$js" 2>/dev/null | tr -d "'" | sort -u); do
			if grep -qF "\"$bin\"" "$acl"; then
				ok "$(basename "$js") → $(basename "$bin") 已授权"
			else
				bad "$(basename "$js") 调用了 $bin，但 $acl 没授权"
			fi
		done
	done
done

# ─────────────────────────────────────────────── 3. 菜单 path 必须存在对应视图
echo "  -- 菜单 path ↔ 视图文件 --"
for mf in $(find . -path '*menu.d*' -name '*.json' 2>/dev/null); do
	pkg="$(echo "$mf" | cut -d/ -f2)"
	paths="$(grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]+"' "$mf" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')"
	for p in $paths; do
		if [ -f "$pkg/htdocs/luci-static/resources/view/$p.js" ]; then
			ok "$pkg: $p.js 存在"
		else
			bad "$pkg: 菜单指向 $p，但没有 view/$p.js"
		fi
	done
done

# ─────────────────────────────────────────────── 4. JSON 合法
echo "  -- JSON 合法性 --"
for j in $(find . -path ./.git -prune -o -name '*.json' -print 2>/dev/null); do
	case "$j" in
		*.github*) continue ;;
	esac
	if command -v python3 >/dev/null 2>&1; then
		python3 -c "import json,sys;json.load(open('$j'))" 2>/dev/null \
			&& ok "${j#./}" || bad "${j#./} JSON 语法错"
	elif command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$j" >/dev/null 2>&1 && ok "${j#./}" || bad "${j#./}"
	fi
done

# ─────────────────────────────────────────────── 5. 脚本可执行位
echo "  -- 可执行位 --"
for f in $(find . -path ./.git -prune -o -type f -print 2>/dev/null); do
	head -1 "$f" 2>/dev/null | grep -q '^#!' || continue
	mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
	case "$mode" in
		*755|*775|*777) ok "${f#./} ($mode)" ;;
		*) bad "${f#./} 权限是 $mode，应该是 755" ;;
	esac
done

# ─────────────────────────────────────────────── 6. shell 语法
echo "  -- shell 语法 --"
for f in $(find . -path ./.git -prune -o -type f -print 2>/dev/null); do
	head -1 "$f" 2>/dev/null | grep -q '^#!' || continue
	if sh -n "$f" 2>/dev/null; then
		ok "sh -n ${f#./}"
	else
		bad "sh -n ${f#./} 语法错"
	fi
done

# ─────────────────────────────────────────────── 7. JS 语法（有 node 才查）
echo "  -- JS 语法 --"
if command -v node >/dev/null 2>&1; then
	for f in $(find . -path ./.git -prune -o -name '*.js' -print 2>/dev/null); do
		if node --check "$f" 2>/dev/null; then
			ok "node --check ${f#./}"
		else
			bad "node --check ${f#./} 语法错"
		fi
	done
else
	echo "  ⏭  本机没有 node，跳过"
fi

# ─────────────────────────────────────────────── 8. 代码读的 uci 键必须在配置里
echo "  -- 代码读的 uci 键 ↔ 配置文件 --"
check_keys() {
	pkg="$1"; cfg="$2"; prefix="$3"
	[ -f "$cfg" ] || { echo "  ⏭  $cfg 不存在，跳过"; return; }
	# 配置里定义了哪些 段.键
	grep -oE "^config [a-z]+ '[a-z_]+'" "$cfg" | sed "s/^config [a-z]* '//;s/'//" > /tmp/_secs.$$
	: > /tmp/_defined.$$
	cur=""
	while IFS= read -r line; do
		# 注意：option 行是 Tab 缩进的，必须先把前导空白去掉，
		# 否则 case 匹配不上、defined 永远是空的，这个检查就会「撒谎」。
		trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
		case "$trimmed" in
			config\ *) cur="$(printf '%s' "$trimmed" | sed "s/^config [a-z]* '//;s/'//")" ;;
			option\ *) k="$(printf '%s' "$trimmed" | awk '{print $2}')"; [ -n "$cur" ] && echo "$cur.$k" >> /tmp/_defined.$$ ;;
		esac
	done < "$cfg"
	sort -u /tmp/_defined.$$ -o /tmp/_defined.$$

	grep -rhoE "$prefix\.[a-z0-9_]+\.[a-z0-9_]+" "$pkg/root/usr/" 2>/dev/null | sed "s/^$prefix\.//" | sort -u > /tmp/_used.$$

	missing="$(comm -13 /tmp/_defined.$$ /tmp/_used.$$)"
	if [ -n "$missing" ]; then
		echo "     代码读但配置没定义的（会走代码里的默认值，确认是有意的）："
		echo "$missing" | sed 's/^/       /'
	fi
	rm -f /tmp/_secs.$$ /tmp/_defined.$$ /tmp/_used.$$
}
check_keys luci-app-openfi-fan luci-app-openfi-fan/root/etc/config/openfi openfi
check_keys luci-app-openfi-modem luci-app-openfi-modem/root/etc/config/openfi_modem openfi_modem

echo
if [ "$FAIL" -eq 0 ]; then
	echo "  结构一致性：全部通过"
	exit 0
fi
echo "  结构一致性：$FAIL 项失败"
exit 1
