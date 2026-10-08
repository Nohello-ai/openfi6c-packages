/*
 * openfi-sms 解码驱动
 *
 *   输入：AT+CMGL=4 的原始输出（从 argv[1] 指定的文件读，或 stdin）
 *   输出：一行 JSON —— {"messages":[...],"error":""}
 *
 * 为什么要单独一个驱动、而不是在 shell 里解析：
 *   +CMGL 的输出里，每条短信占两行（一行 "+CMGL: idx,stat,,len" + 一行 PDU），
 *   而长短信还会按 UDH 拆成好几条 —— 归组、排序、拼接这些活儿放在
 *   shell 里写会非常难读；ucode 有数组和 JSON，天生适合。
 *
 * AT 那部分（含串口互斥锁）由 shell 侧的 openfi-sms 负责，
 * 这里只处理「已经拿到的文本」。
 */

/*
 * 【坑11】ucode 的模块解析有两条规矩，都踩过：
 *   · 用 -L <目录> 找模块时，名字【不能带 .uc 后缀】（'pdu' 能解析，'pdu.uc' 不能）
 *   · 写绝对路径的话必须带到 .uc（但那样就把安装路径写死了，本地没法测）
 * 所以这里用裸名字 'pdu'，由调用方（后端脚本）用 -L 指到 /usr/lib/openfi-sms。
 * fs 是插件模块：设备上 ucode-mod-fs 装在 /usr/lib/ucode/ 里，直接 import 就行。
 */
import { decodePdu, joinConcat } from 'pdu';
import * as fs from 'fs';

/*
 * 【坑12】不要用 json() 序列化普通对象。
 *   本地从源码构建的 ucode 上，json({a:1}) 直接抛
 *   "Input object does not implement read() method"。
 *   设备上的 ucode（2025.05）没这个问题，但为了同一份代码在
 *   两个版本上都能跑，这里手写序列化 —— 也就顺带保证了转义是对的。
 */
function jesc(s) {
	let out = '';
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		let n = ord(c);
		if (c == '"' || c == '\\')
			out += '\\' + c;
		else if (n < 0x20)
			out += sprintf('\\u%04x', n);
		else
			out += c;
	}
	return out;
}

/* 一条消息 → JSON 对象片段 */
function msgJson(m) {
	let parts = '';
	if (m.parts)
		parts = sprintf(',"parts":{"have":%d,"total":%d}', m.parts.have, m.parts.total);

	if (m.error)
		return sprintf('{"idx":%d,"error":"%s"}', m.idx, jesc(m.error));

	return sprintf('{"idx":%d,"sender":"%s","time":"%s","unread":%s,"enc":"%s","body":"%s"%s}',
		m.idx, jesc(m.sender), jesc(m.time),
		m.unread ? 'true' : 'false', jesc(m.enc || ''), jesc(m.body), parts);
}

function messagesJson(list) {
	let out = '';
	for (let i = 0; i < length(list); i++) {
		if (i > 0) out += ',';
		out += msgJson(list[i]);
	}
	return '{"messages":[' + out + '],"error":""}';
}

function errJson(msg) {
	return '{"error":"' + jesc(msg) + '"}';
}

/*
 * 【坑13】别用 !index(line,'x')==0 这种写法判断「不包含」。
 *   ucode 里 index() 找不到时返回 null，!null == 0 会算成 true，
 *   结果「不包含 +CME」这个条件永远为真、永远为假，取决于写法，
 *   非常容易把 PDU 行整批丢掉（实测就丢了，解出 0 条）。
 * 这里改成直接看字符集 —— 没有歧义。
 */
function isHexLine(s) {
	if (length(s) < 10)
		return false;
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		let ok = (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f');
		if (!ok)
			return false;
	}
	return true;
}

function readInput() {
	/* 优先用命令行给的文件；没有就从 stdin 读 */
	/*
	 * 【坑14】ucode 的 ARGV 里【没有脚本名】—— 第一个参数就是 ARGV[0]。
	 *   （C 语言里 argv[0] 是程序名，习惯性写成 ARGV[1] 就永远取到空，
	 *     于是静默回退去读 stdin、解出 0 条，还不报错。）
	 */
	if (length(ARGV) > 0 && ARGV[0] != '-')
		return fs.readfile(ARGV[0]);

	return fs.readfile('/dev/stdin');
}

function main() {
	let text;
	try {
		text = readInput();
	} catch (e) {
		print(errJson('read_failed: ' + e));
		return;
	}

	if (text == null) {
		print(errJson('no_input'));
		return;
	}

	let lines = split(trim(text), '\n');
	let msgs = [];
	let cur = null;

	for (let i = 0; i < length(lines); i++) {
		let line = trim(lines[i]);

		/* 回显的那行（模块把指令原样回给我们）—— 跳过 */
		if (line == 'AT+CMGL=4' || line == 'AT+CMGL=0' || line == 'OK')
			continue;

		/* "+CMGL: <idx>,<stat>,<alpha>,<len>" 开头一条新短信 */
		if (substr(line, 0, 6) == '+CMGL:') {
			let f = split(substr(line, 6), ',');
			cur = {
				idx: int(trim(f[0])),
				/* 0 = 未读，1 = 已读，其余状态（未发送/已发送）也原样带出去 */
				status: int(trim(f[1])),
				pdu: ''
			};
			push(msgs, cur);
			continue;
		}

		/* 其余的行：只有「纯十六进制且够长」的才算 PDU */
		if (cur != null && cur.pdu == '' && isHexLine(line))
			cur.pdu = line;
	}

	/* 逐条解码 */
	let decoded = [];
	for (let i = 0; i < length(msgs); i++) {
		let m = msgs[i];
		if (m.pdu == '')
			continue;

		let d;
		try {
			d = decodePdu(m.pdu);
		} catch (e) {
			push(decoded, { idx: m.idx, error: 'decode_failed' });
			continue;
		}
		if (d.error) {
			push(decoded, { idx: m.idx, error: d.error });
			continue;
		}

		d.idx = m.idx;
		d.status = m.status;
		push(decoded, d);
	}

	/* 长短信按 (发件人, ref, 总段数) 归组、按段号排序后拼起来 */
	let joined = joinConcat(decoded);

	/* 整理成前端要的形状 */
	let out = [];
	for (let i = 0; i < length(joined); i++) {
		let m = joined[i];
		if (m.error) {
			push(out, { idx: m.idx, error: m.error });
			continue;
		}

		let item = {
			idx: m.idx,
			sender: m.sender,
			time: m.scts,
			unread: (m.status === 0),
			body: m.body,
			enc: m.enc
		};
		if (m.parts)
			item.parts = m.parts;

		push(out, item);
	}

	/* 最新的排前面 */
	for (let i = 0; i < length(out); i++)
		for (let j = i + 1; j < length(out); j++)
			if ((out[j].idx || 0) > (out[i].idx || 0)) {
				let t = out[i]; out[i] = out[j]; out[j] = t;
			}

	print(messagesJson(out));
}

main();
