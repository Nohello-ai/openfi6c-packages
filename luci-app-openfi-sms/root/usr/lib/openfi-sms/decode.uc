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

import { decodePdu, joinConcat } from '/usr/lib/openfi-sms/pdu.uc';
import * as fs from 'fs';

function readInput() {
	/* 优先用命令行给的文件；没有就从 stdin 读 */
	if (length(ARGV) > 1 && ARGV[1] != '-')
		return fs.readfile(ARGV[1]);

	return fs.readfile('/dev/stdin');
}

function main() {
	let text;
	try {
		text = readInput();
	} catch (e) {
		print(json({ error: 'read_failed: ' + e }));
		return;
	}

	if (text == null) {
		print(json({ error: 'no_input' }));
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
		if (index(line, '+CMGL:') == 0) {
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

		/* 其余的非空行当作 PDU（十六进制） */
		if (cur != null && length(line) > 10 && !index(line, '+CME') == 0) {
			if (cur.pdu == '')
				cur.pdu = line;
		}
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

	print(json({ messages: out, error: '' }));
}

main();
