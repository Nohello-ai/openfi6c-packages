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
 * GSM 7bit 解包
 * 【坑2】每 7 位一个字符，而且位序是「低位在前」（LSB-first）
 * 【坑3】带 UDH 时正文前面有填充位，必须按 septet 边界对齐，否则整条歪掉
 *   septets：从这个 septet 序号开始取（UDH 占掉的 septet 数）
 */
function gsm7Decode(bytes, septetSkip) {
	let bits = '';
	for (let i = 0; i < length(bytes); i++) {
		let b = bytes[i];
		for (let k = 0; k < 8; k++)
			bits += ((b >> k) & 1) ? '1' : '0';
	}
	bits = substr(bits, septetSkip * 7);

	let out = '';
	for (let i = 0; i + 7 <= length(bits); i += 7) {
		let v = 0;
		for (let k = 0; k < 7; k++)
			if (substr(bits, i + k, 1) == '1')
				v |= (1 << k);
		out += chr(v);
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

	/* 时区：有符号 BCD，单位 15 分钟 */
	let tz = int(substr(d, 12, 2));	/* 【坑8】时区是 BCD 十进制，不是十六进制 */
	let sign = (tz & 0x80) ? '-' : '+';
	tz &= 0x7f;
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
		let skip = 0;
		if (udhi)
			skip = int((((udhLen + 1) * 8) + 6) / 7);	/* 【坑3】向上取整 */
		body = gsm7Decode(payload, skip);
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

	/* 有有效期时（TP-VPF != 0）要跳过对应字节数 */
	let vpf = (fo >> 3) & 0x03;
	if (vpf == 0x01) p += 2;		/* 增强格式 7 字节，极少用，先不处理 */
	else if (vpf == 0x02) p += 2;		/* 相对格式 1 字节 */
	else if (vpf == 0x03) p += 14;		/* 绝对格式 7 字节 */

	let udl = byteAt(h, p / 2); p += 2;
	let ud = hex2bytes(substr(h, p));

	let text;
	if ((dcs & 0x0c) == 0x08) {
		text = '';
		for (let i = 0; i + 1 < length(ud); i += 2)
			text += utf8((ud[i] << 8) | ud[i + 1]);
	}
	else {
		text = gsm7Decode(ud, 0);
	}

	return { smsc: smsc, fo: fo, mr: mr, to: da.value, dcs: dcs, udl: udl, body: text };
}

export { decodePdu, joinConcat, encodeSubmit, decodeSubmit };

