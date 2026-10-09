/*
 * SMS PDU 编解码 —— 3GPP TS 23.040
 *
 * 为什么用 ucode 而不是 shell：
 *   这块要做的是「十六进制 ↔ 位 ↔ 字节序 ↔ 字符集」的活。shell 干这个
 *   会难查十倍（当初用 Python 随手写的第一版就踩了 4 个坑）。ucode 有
 *   位运算、sprintf("%02x")、chr/ord、substr，而且**是解释型的** ——
 *   包能保持 Architecture: all，CI 不用配交叉工具链。
 *
 * 用 Python 版验证过的坑，全在下面标了【坑N】。
 */

/*
 * 码点 → UTF-8 字节串
 * 【坑7】不要依赖 chr() 处理多字节：不同 ucode 构建行为不一致
 *        （本地构建里 chr(0x533A) 出来是 ?）。
 *        自己按 UTF-8 规则编码，1/2/3 字节都覆盖，反而到处都能跑。
 */
function utf8(cp) {
	if (cp < 0x80)
		return chr(cp);
	if (cp < 0x800)
		return chr(0xc0 | (cp >> 6)) + chr(0x80 | (cp & 0x3f));
	if (cp < 0x10000)
		return chr(0xe0 | (cp >> 12)) + chr(0x80 | ((cp >> 6) & 0x3f)) + chr(0x80 | (cp & 0x3f));
	return chr(0xf0 | (cp >> 18)) + chr(0x80 | ((cp >> 12) & 0x3f))
		+ chr(0x80 | ((cp >> 6) & 0x3f)) + chr(0x80 | (cp & 0x3f));
}

/* 半字节交换。电话号码、时间戳都这么存：32 存成 "23" 【坑1】 */
function swapNibbles(h) {
	let out = '';
	for (let i = 0; i + 1 < length(h); i += 2)
		out += substr(h, i + 1, 1) + substr(h, i, 1);
	return out;
}

/*
 * 十六进制字符串 → 整数
 * 【坑6】ucode 里 int("0xff") 返回 0、int("ff") 返回 NaN —— 它不认十六进制，
 *        也没有 base 参数。必须用一元加号强制走数字解析器：+("0xff") === 255。
 *        这个坑很容易「语法写对了、语义错了」。
 */
function hx(s) {
	return +("0x" + s);
}

function hex2bytes(h) {
	let out = [];
	for (let i = 0; i + 1 < length(h); i += 2)
		push(out, hx(substr(h, i, 2)));
	return out;
}

/* 取第 i 个字节（两位十六进制） */
function byteAt(h, i) {
	return hx(substr(h, i * 2, 2));
}

/*
 * GSM 03.38 默认字母表：GSM 7bit 值（0x00..0x7F）→ Unicode 码点。
 * 存【码点】而不是照抄字符：ucode 的字符串是 UTF-8 字节流，
 * 表里混进 è/Ø/Δ/€ 这类多字节字符后 substr(...,i,1) 会按字节切、索引全乱。
 * 【坑2b】0x1B 是「扩展转义」标记，本身不产出字符，见 GSM7_EXT。
 */
let GSM7_BASIC = [
/* 00 */	0x0040, 0x00A3, 0x0024, 0x00A5, 0x00E8, 0x00E9, 0x00F9, 0x00EC,
/* 08 */	0x00F2, 0x00C7, 0x000A, 0x00D8, 0x00F8, 0x000D, 0x00C5, 0x00E5,
/* 10 */	0x0394, 0x005F, 0x03A6, 0x0393, 0x039B, 0x03A9, 0x03A0, 0x03A8,
/* 18 */	0x03A3, 0x0398, 0x039E, 0x001B, 0x00C6, 0x00E6, 0x00DF, 0x00C9,
/* 20 */	0x0020, 0x0021, 0x0022, 0x0023, 0x00A4, 0x0025, 0x0026, 0x0027,
/* 28 */	0x0028, 0x0029, 0x002A, 0x002B, 0x002C, 0x002D, 0x002E, 0x002F,
/* 30 */	0x0030, 0x0031, 0x0032, 0x0033, 0x0034, 0x0035, 0x0036, 0x0037,
/* 38 */	0x0038, 0x0039, 0x003A, 0x003B, 0x003C, 0x003D, 0x003E, 0x003F,
/* 40 */	0x00A1, 0x0041, 0x0042, 0x0043, 0x0044, 0x0045, 0x0046, 0x0047,
/* 48 */	0x0048, 0x0049, 0x004A, 0x004B, 0x004C, 0x004D, 0x004E, 0x004F,
/* 50 */	0x0050, 0x0051, 0x0052, 0x0053, 0x0054, 0x0055, 0x0056, 0x0057,
/* 58 */	0x0058, 0x0059, 0x005A, 0x00C4, 0x00D6, 0x00D1, 0x00DC, 0x00A7,
/* 60 */	0x00BF, 0x0061, 0x0062, 0x0063, 0x0064, 0x0065, 0x0066, 0x0067,
/* 68 */	0x0068, 0x0069, 0x006A, 0x006B, 0x006C, 0x006D, 0x006E, 0x006F,
/* 70 */	0x0070, 0x0071, 0x0072, 0x0073, 0x0074, 0x0075, 0x0076, 0x0077,
/* 78 */	0x0078, 0x0079, 0x007A, 0x00E4, 0x00F6, 0x00F1, 0x00FC, 0x00E0
];

/* GSM 03.38 扩展表（0x1B 后面的那个 septet）→ Unicode 码点 */
let GSM7_EXT = [
	[ 0x0A, 0x000C ],	/* 换页 */
	[ 0x14, 0x005E ],	/* ^ */
	[ 0x28, 0x007B ],	/* { */
	[ 0x29, 0x007D ],	/* } */
	[ 0x2F, 0x005C ],	/* \ */
	[ 0x3C, 0x005B ],	/* [ */
	[ 0x3D, 0x007E ],	/* ~ */
	[ 0x3E, 0x005D ],	/* ] */
	[ 0x40, 0x007C ],	/* | */
	[ 0x65, 0x20AC ]	/* € */
];

function gsm7Ext(v) {
	for (let i = 0; i < length(GSM7_EXT); i++)
		if (GSM7_EXT[i][0] == v)
			return GSM7_EXT[i][1];
	return null;			/* 未定义的转义：按不可解释丢弃 */
}

/*
 * GSM 7bit 解包
 * 【坑2】每 7 位一个字符，而且位序是「低位在前」（LSB-first）
 * 【坑3】带 UDH 时正文前面有填充位，必须按 septet 边界对齐，否则整条歪掉
 *   septets：从这个 septet 序号开始取（UDH 占掉的 septet 数）
 *   count：正文一共多少个 septet（= UDL），null = 有多少解多少。
 *     【坑2c】7bit 打包末尾会有 0~7 个填充位（凑整到字节）。填充位够 7 个时
 *     会多出「一个全是 0 的 septet」，按 0x00 解出来就是多一个 '@'
 *     （以前 chr(0) 会多一个 NUL，正文长度是 7 的倍数+1 时必现，比如 15 个字符）。
 *     所以调用方要把 UDL 传进来，按它截断。
 * 【坑2d】不能 chr(v) 当 ASCII：GSM 的 0x00 是 '@'、0x11 是 '_'、0x24 是 '¤'、
 *   0x5B 是 'Ä'……还有 0x1B 扩展转义（€、{}、[]、\、~、|、^、换页）。
 *   必须过 GSM7_BASIC / GSM7_EXT 两张表，再用 utf8() 出字节。
 */
function gsm7Decode(bytes, septetSkip, count) {
	let bits = '';
	for (let i = 0; i < length(bytes); i++) {
		let b = bytes[i];
		for (let k = 0; k < 8; k++)
			bits += ((b >> k) & 1) ? '1' : '0';
	}
	bits = substr(bits, septetSkip * 7);

	let out = '';
	let i = 0, used = 0;
	while (i + 7 <= length(bits)) {
		if (count != null && used >= count)
			break;

		let v = 0;
		for (let k = 0; k < 7; k++)
			if (substr(bits, i + k, 1) == '1')
				v |= (1 << k);
		i += 7; used++;

		if (v != 0x1B) {
			out += utf8(GSM7_BASIC[v]);
			continue;
		}

		/* 0x1B = 扩展转义：真正的字符在【下一个】 septet 里；
		 * 落在末尾的孤立 0x1B 没有字符可解，丢掉。 */
		if ((count != null && used >= count) || i + 7 > length(bits))
			break;

		let e = 0;
		for (let k = 0; k < 7; k++)
			if (substr(bits, i + k, 1) == '1')
				e |= (1 << k);
		i += 7; used++;

		let cp = gsm7Ext(e);
		if (cp != null)
			out += utf8(cp);
	}

	return out;
}

/*
 * 地址字段（发件人 / 短信中心）
 * 【坑4】TON 在 bit4~6，不是 bit0~2 —— 判断「是不是字母数字」看这里
 * 返回 { value, ton, consumed }，consumed = 这个字段占了多少个十六进制字符
 */
function parseAddr(h, pos, isSmsc) {
	/*
	 * 【坑9】这两个字段的长度单位不一样，是最阴的一个坑：
	 *   短信中心(SMSC)：len = 【字节数】，含 TOA。8 → TOA(1) + 号码(7 字节) = 14 位
	 *   发件人/收件人 ：len = 【半字节数 / 位数】。8 → 8 位 = 4 字节
	 *   同一个 PDU 里两种规则并存，写错一个不会报错、只会把号码截短或错位。
	 */
	let len = byteAt(h, pos / 2);
	let toa = byteAt(h, pos / 2 + 1);
	let nbytes = isSmsc ? (len - 1) : int((len + 1) / 2);
	let data = substr(h, pos + 4, nbytes * 2);
	let ton = (toa >> 4) & 0x07;
	let value;

	if (ton == 5) {					/* 字母数字：7bit 打包 */
		value = gsm7Decode(hex2bytes(data), 0);
	}
	else {
		value = swapNibbles(data);
		while (length(value) > 0 && substr(value, length(value) - 1, 1) == 'F')
			value = substr(value, 0, length(value) - 1);
		if (value != '' && substr(value, 0, 1) == '+')
			value = substr(value, 1);
		if (ton == 1)				/* 国际号码 */
			value = '+' + value;
	}

	return { value: value, ton: ton, toa: toa, consumed: 4 + nbytes * 2 };
}

/* 时间戳 SCTS：年 月 日 时 分 秒 时区，全 BCD */
function parseScts(h) {
	let d = swapNibbles(h);
	let yy = int(substr(d, 0, 2));
	let year = (yy < 70) ? (2000 + yy) : (1900 + yy);

	/*
	 * 时区：BCD 十进制，单位 15 分钟，编码成两个数字 + 一个符号位。
	 * 【坑8】两个数字是 BCD（十进制），不能拿去当十六进制用。
	 * 【坑8b】符号位是【第一个数字】的 bit3（即那个字符 >= '8' 表示西半球/负），
	 *   不是整个字节的 bit7。对十进制 BCD 值做 & 0x80 永远不成立 ——
	 *   东半球（比如 +08:00 = BCD "32"）看着是对的，负时区才露馅。
	 *   数值 = (第一个数字 & 0x07) * 10 + 第二个数字。
	 */
	let tzs = substr(d, 12, 2);
	let sign = (substr(tzs, 0, 1) >= '8') ? '-' : '+';
	let tz = (hx(substr(tzs, 0, 1)) & 0x07) * 10 + hx(substr(tzs, 1, 1));
	let tzh = int(tz / 4);
	let tzm = (tz % 4) * 15;

	return sprintf("%04d-%s-%s %s:%s:%s UTC%s%02d:%02d",
		year, substr(d, 2, 2), substr(d, 4, 2),
		substr(d, 6, 2), substr(d, 8, 2), substr(d, 10, 2),
		sign, tzh, tzm);
}

/*
 * 解码一条 PDU（目前只做 SMS-DELIVER，也就是「收到的短信」）
 * 【坑5】只有 SMS-SUBMIT（发出的）才用 SMS-SUBMIT 的结构，
 *        用 Python 写的时候把 & 和 == 的优先级搞错过，ucode 里位运算优先级同样要注意。
 */
function decodePdu(pduHex) {
	let h = uc(pduHex);
	let p = 0;

	/* ── 短信中心地址 ── */
	let scaLen = byteAt(h, 0);
	let smsc = '(无)';
	if (scaLen > 0)
		smsc = parseAddr(h, 0, true).value;
	p += 2 + scaLen * 2;

	/* ── 首字节 ── */
	let fo = byteAt(h, p / 2);
	p += 2;
	let mti = fo & 0x03;
	let udhi = (fo & 0x40) ? true : false;

	if (mti != 0)
		return { error: '只实现了 SMS-DELIVER（MTI=' + mti + '）' };

	/* ── 发件人 ── */
	let oa = parseAddr(h, p, false);
	p += oa.consumed;

	/* ── PID / DCS ── */
	let pid = byteAt(h, p / 2); p += 2;
	let dcs = byteAt(h, p / 2); p += 2;

	/* ── 时间戳 ── */
	let scts = parseScts(substr(h, p, 14)); p += 14;

	/* ── 用户数据 ── */
	let udl = byteAt(h, p / 2); p += 2;
	let udHex = substr(h, p);
	let ud = hex2bytes(udHex);

	/* UDH（长短信拼接信息就在这） */
	let udh = null, udhLen = 0;
	if (udhi && length(ud) > 0) {
		udhLen = ud[0];
		udh = [];
		for (let i = 1; i <= udhLen && i < length(ud); i++)
			push(udh, ud[i]);
	}

	let body, enc;
	let payload = [];
	/*
	 * 【坑10】payload 的起点取决于有没有 UDH：
	 *   有 UDH → 跳过「UDH 长度字节 + UDH 本身」= 1 + udhLen
	 *   没 UDH → 从 0 开始！
	 * 这里无条件写 1 + udhLen 的话，没 UDH 的短信会整体错位一个字节 ——
	 * 而 UCS2 错一字节不会报错，只会解出一堆看着像汉字、其实全错的字。
	 * （实测：#1/#15 是 fo=0x24 无 UDH → 全乱；#2/#3 有 UDH → 正常。）
	 */
	let udStart = udhi ? (1 + udhLen) : 0;
	for (let i = udStart; i < length(ud); i++)
		push(payload, ud[i]);

	let dcsClass = dcs & 0x0c;
	if (dcsClass == 0x08) {			/* UCS2（中文走这条） */
		let s = '';
		for (let i = 0; i + 1 < length(payload); i += 2) {
			let cp = (payload[i] << 8) | payload[i + 1];
			if (cp != 0)
				s += utf8(cp);
		}
		body = s;
		enc = 'UCS2';
	}
	else if (dcsClass == 0x00) {	/* GSM 7bit */
		/*
		 * 【坑3b】带 UDH 时，正文从【整个 UD 字段】的第
		 *   ceil((udhLen + 1) * 8 / 7) 个 septet 开始 —— UDH 是字节对齐的，
		 *   后面还要填几个 bit 才对齐到 septet 边界。
		 *   所以不能「先把 UDH 那几个字节切掉、再按 septet 跳」：那是两个坐标系，
		 *   48 bit 的 UDH 按 7bit 算是 7 个 septet，按 8bit 切只等于 6 个字节。
		 *   以前正是这么写的 → GSM7 的多段长短信每段都会整体错位
		 *   （UCS2 不受影响，所以夹具里的拼接短信看着是好的）。
		 */
		let skip = 0;
		if (udhi)
			skip = int((((udhLen + 1) * 8) + 6) / 7);	/* 【坑3】向上取整 */
		/* UDL 是 septet 总数（含 UDH 占掉的），末尾填充位不算正文 */
		let bodySeptets = (udl > skip) ? (udl - skip) : null;
		body = gsm7Decode(ud, skip, bodySeptets);
		enc = 'GSM7';
	}
	else {
		body = '(未实现的编码 DCS=0x' + sprintf('%02x', dcs) + ')';
		enc = '?';
	}

	let r = {
		mti: mti,
		smsc: smsc,
		sender: oa.value,
		scts: scts,
		dcs: dcs,
		enc: enc,
		body: body,
		udh: udh
	};

	/*
	 * 拼接短信：UDH = 05 00 03 <ref> <total> <seq>
	 *            │  │  │
	 *            │  │  └ IE 数据长度
	 *            │  └──── IEI（0x00 = 拼接）
	 *            └─────── UDH 总长度（这一字节已经在上面的 udhLen 里剥掉了）
	 * 所以 udh[] 的内容是 [IEI, IE长度, ref, total, seq]：
	 * 【坑15】判断 IEI 要看 udh[0]，不是 udh[1]。
	 *   写成 udh[1] == 0x00 的话永远不成立（那里是 IE 长度 0x03），
	 *   结果是长短信从不归组、parts 永远为空 —— 而且不报任何错。
	 */
	if (udh && length(udh) >= 5 && udh[0] == 0x00) {
		r.concat = { ref: udh[2], total: udh[3], seq: udh[4] };
	}

	return r;
}

/* 把多段拼接短信合成一条：按 (ref, total) 归组、按 seq 排序 */
function joinConcat(list) {
	let groups = {}, out = [];

	for (let i = 0; i < length(list); i++) {
		let m = list[i];
		if (!m.concat) { push(out, m); continue; }

		let key = m.sender + '#' + m.concat.ref + '#' + m.concat.total;
		if (!groups[key]) groups[key] = [];
		push(groups[key], m);
	}

	for (let key in groups) {
		let parts = groups[key];
		/* 按 seq 排序 */
		for (let i = 0; i < length(parts); i++)
			for (let j = i + 1; j < length(parts); j++)
				if (parts[j].concat.seq < parts[i].concat.seq) {
					let t = parts[i]; parts[i] = parts[j]; parts[j] = t;
				}

		let body = '';
		let seqs = [];
		for (let i = 0; i < length(parts); i++) {
			body += parts[i].body;
			push(seqs, parts[i].concat.seq);
		}

		let m = parts[0];
		m.body = body;
		m.parts = { have: length(parts), total: m.concat.total, seqs: seqs };
		push(out, m);
	}

	return out;
}

/* ================================================================
 * 编码：把「号码 + 正文」变成 SMS-SUBMIT 的 PDU
 *
 *   [SMSC][FO][MR][DA][PID][DCS][UDL][UD]
 *
 * 设计取舍：
 *   · SMSC 用 "00"（长度 0）= 让模组用它自己配好的短信中心，
 *     这样不用去查当前短信中心号码，也不怕换卡。
 *   · 第一字节 0x01 = SMS-SUBMIT + 无有效期 + 无 UDH。
 *     （常见写法 0x11 是带相对有效期的，会多一个 VP 字节，这里用不上。）
 *   · DCS 一律 0x08（UCS2）。中文英文都走这条路，
 *     不用先判断正文里有没有非 GSM 字符 —— 少一个分支就少一类 bug。
 *     代价是一条只能装 70 个字符（UCS2 每字符 2 字节），够用。
 * ================================================================ */

/* ucode 的字符串是 UTF-8：substr(s,i,1) 拿到的是【一个字节】，
 * 所以要先自己解出码点，才能转 UCS2。 */
function utf8Decode(s) {
	let cps = [];
	let i = 0;
	while (i < length(s)) {
		let b = ord(substr(s, i, 1));
		let cp, n;

		if (b < 0x80)       { cp = b;         n = 1; }
		else if (b < 0xe0)  { cp = b & 0x1f;  n = 2; }
		else if (b < 0xf0)  { cp = b & 0x0f;  n = 3; }
		else                { cp = b & 0x07;  n = 4; }

		for (let k = 1; k < n; k++) {
			if (i + k >= length(s)) break;
			cp = (cp << 6) | (ord(substr(s, i + k, 1)) & 0x3f);
		}
		push(cps, cp);
		i += n;
	}
	return cps;
}

/* 号码 → { toa, len, data }（TP-Destination-Address 三段） */
function encodeNumber(num) {
	let s = trim(num);
	let intl = false;

	if (substr(s, 0, 1) == '+') { intl = true; s = substr(s, 1); }
	/* 只留数字：空格、短横线都去掉 */
	let digits = '';
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		if (c >= '0' && c <= '9')
			digits += c;
	}

	/* 奇数位补 F（半字节填充），然后两两交换 */
	let padded = (length(digits) % 2) ? (digits + 'F') : digits;
	let data = swapNibbles(padded);

	return {
		toa: sprintf('%02X', intl ? 0x91 : 0x81),
		len: sprintf('%02X', length(digits)),
		data: data
	};
}

/*
 * 返回 { pdu: '<完整 PDU 十六进制>', tpdu_octets: N }
 * tpdu_octets 是 AT+CMGS= 后面要填的数：**不含 SMSC 部分**的字节数。
 */
function encodeSubmit(number, text) {
	let da = encodeNumber(number);
	let cps = utf8Decode(text);

	/* UCS2：每个码点两个字节，大端 */
	let ud = '';
	for (let i = 0; i < length(cps); i++) {
		let cp = cps[i];
		/* 超出 BMP 的（emoji 等）用代理对 */
		if (cp > 0xffff) {
			cp -= 0x10000;
			ud += sprintf('%04X%04X', 0xd800 | (cp >> 10), 0xdc00 | (cp & 0x3ff));
		}
		else {
			ud += sprintf('%04X', cp);
		}
	}

	let udOctets = length(ud) / 2;
	if (udOctets > 140)
		return { error: 'too_long', max_chars: 70, chars: length(cps) };

	let tpdu =
		'01' +					/* FO: SUBMIT, 无 VP, 无 UDH */
		'00' +					/* MR */
		da.len + da.toa + da.data +		/* DA */
		'00' +					/* PID */
		'08' +					/* DCS: UCS2 */
		sprintf('%02X', udOctets) +		/* UDL（UCS2 时就是字节数） */
		ud;

	return {
		pdu: '00' + tpdu,			/* 前面加 SMSC 长度 0 */
		tpdu_octets: length(tpdu) / 2
	};
}

/*
 * 解码 SMS-SUBMIT（自己发出去的）。用来验证编码器，也用来显示发件箱。
 * 结构： [SMSC][FO][MR][DA][PID][DCS][UDL][UD]
 * 和 DELIVER 的差别：MR 在 DA 之前，没有 SCTS。
 */
function decodeSubmit(pduHex) {
	let h = uc(pduHex);
	let p = 0;

	let scaLen = byteAt(h, 0);
	let smsc = '(用模组默认)';
	if (scaLen > 0)
		smsc = parseAddr(h, 0, true).value;
	p += 2 + scaLen * 2;

	let fo = byteAt(h, p / 2); p += 2;
	let mr = byteAt(h, p / 2); p += 2;

	/* DA 的长度单位是【位数】（和 DELIVER 的发件人一样） */
	let da = parseAddr(h, p, false);
	p += da.consumed;

	let pid = byteAt(h, p / 2); p += 2;
	let dcs = byteAt(h, p / 2); p += 2;

	/*
	 * 有有效期时（TP-VPF != 0）要跳过对应字节数 —— TS 23.040 9.2.3.12：
	 *   01 = 相对格式：1 字节
	 *   10 = 增强格式：7 字节
	 *   11 = 绝对格式：7 字节
	 * 【坑16】以前 10/11 两句的字节数和注释都是错位的：增强格式只跳了 1 字节，
	 *   解析外部 SUBMIT（模组读回自己发的短信、或别的实现发的）会整体错位。
	 *   VPF 只出现在 SMS-SUBMIT 里，所以自家 VPF=0 的路径测不出来。
	 */
	let vpf = (fo >> 3) & 0x03;
	if (vpf == 0x01) p += 2;		/* 相对格式：1 字节 */
	else if (vpf == 0x02) p += 14;		/* 增强格式：7 字节 */
	else if (vpf == 0x03) p += 14;		/* 绝对格式：7 字节 */

	let udl = byteAt(h, p / 2); p += 2;
	let ud = hex2bytes(substr(h, p));

	/* 带 UDH 时（TP-UDHI），UD 开头是「UDH 长度字节 + UDH」，正文在后面。
	 * 和 decodePdu 一样：GSM7 要按 septet 坐标系跳，UCS2 按字节跳。 */
	let udhi = (fo & 0x40) ? true : false;

	let text;
	if ((dcs & 0x0c) == 0x08) {
		let start = (udhi && length(ud) > 0) ? (1 + ud[0]) : 0;
		text = '';
		for (let i = start; i + 1 < length(ud); i += 2)
			text += utf8((ud[i] << 8) | ud[i + 1]);
	}
	else {
		/* GSM7 时 UDL 是 septet 数（含 UDH 占掉的），末尾填充位不是字符 */
		let skip = 0;
		if (udhi && length(ud) > 0)
			skip = int((((ud[0] + 1) * 8) + 6) / 7);
		text = gsm7Decode(ud, skip, (udl > skip) ? (udl - skip) : null);
	}

	return { smsc: smsc, fo: fo, mr: mr, to: da.value, dcs: dcs, udl: udl, body: text };
}

export { decodePdu, joinConcat, encodeSubmit, decodeSubmit };

