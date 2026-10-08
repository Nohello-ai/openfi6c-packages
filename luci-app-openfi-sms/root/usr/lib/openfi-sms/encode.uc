/*
 * openfi-sms 编码驱动
 *
 *   ucode encode.uc <号码> <正文文件>
 *
 * 正文走【文件】而不是命令行参数：中文、引号、星号、换行都可能有，
 * 塞进 shell 参数要处理一堆转义，走文件就没这些事。
 */
import { encodeSubmit } from 'pdu';
import * as fs from 'fs';

function jesc(s) {
	let out = '';
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		let n = ord(c);
		if (c == '"' || c == '\\') out += '\\' + c;
		else if (n < 0x20) out += sprintf('\\u%04x', n);
		else out += c;
	}
	return out;
}

let num = (length(ARGV) > 0) ? ARGV[0] : '';
let file = (length(ARGV) > 1) ? ARGV[1] : '';

if (num == '' || file == '') {
	print('{"error":"usage"}');
	exit(1);
}

let text;
try {
	text = trim(fs.readfile(file));
} catch (e) {
	print('{"error":"read_failed"}');
	exit(1);
}

let e;
try {
	e = encodeSubmit(num, text);
} catch (err) {
	print('{"error":"encode_failed"}');
	exit(1);
}

if (e.error) {
	print('{"error":"' + jesc(e.error) + '","max_chars":' + (e.max_chars || 0) + ',"chars":' + (e.chars || 0) + '}');
	exit(1);
}

print('{"pdu":"' + e.pdu + '","octets":' + e.tpdu_octets + ',"chars":' + length(text) + '}');
