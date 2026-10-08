'use strict';
'require view';
'require fs';
'require ui';
'require poll';
'require uci';

/*
 * OpenFi 6C「短信」页面
 *
 *  · 上面是短信列表，整块可以上下滑（不是页面滚，是列表内部滚）
 *  · 每行显示「发件人 + 时间 + 正文预览」，显示不下就用省略号截断
 *  · 点某一行 → 弹窗（ui.showModal）看完整内容，不跳页面
 *  · 下面是发送区：收件人 + 内容 + 发送
 *
 * 数据全来自 /usr/sbin/openfi-sms list。
 *   后台守护 openfi-smsd 每 refresh 秒读一次 SIM 并缓存，
 *   list 优先返回缓存（纯文件读，不碰串口），所以这个页面可以刷得很快：
 *     · 打开页面瞬间就有数据（用后台已经缓存好的）
 *     · 看着的时候默认每 5 秒刷新一次
 *   缓存过期或守护没起来时，list 会自己读一次 SIM 兜底。
 * 布局只用 LuCI 标准 class，不写死颜色，跟随主题（aurora / bootstrap 都好看）。
 *
 * 手机适配的几个点：
 *   · 列表用 max-height + overflow-y:auto，页面本身不滚
 *   · 整行都是点击热区（不是只有文字可点）
 *   · 不用固定宽度表格 —— 窄屏会挤爆
 *   · 预览用 CSS 裁掉，不靠 JS 截字符串（换行时也好看）
 */

var CMD = '/usr/sbin/openfi-sms';

/* 默认值；真实值从 uci openfi_sms 读（见 load） */
var POLL_SECS = 5;
var MARK_READ = 1;

function confInt(name, dflt) {
	var v = parseInt(uci.get('openfi_sms', 'sms', name), 10);
	return isNaN(v) ? dflt : v;
}

function esc(s) {
	return String(s == null ? '' : s)
		.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

/* "2026-09-25 18:19:06 UTC+08:00" → "09-25 18:19" */
function shortTime(t) {
	if (!t) return '';
	var m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/.exec(t);
	if (!m) return t;
	return m[2] + '-' + m[3] + ' ' + m[4] + ':' + m[5];
}

function call(action, args) {
	return fs.exec(CMD, [ action ].concat(args || [])).then(function (res) {
		try {
			return JSON.parse((res && res.stdout) || '{}') || {};
		} catch (e) {
			return { error: _('后端返回的不是合法 JSON') };
		}
	}).catch(function (e) {
		return { error: String((e && e.message) || e) };
	});
}

return view.extend({
	load: function () {
		return uci.load('openfi_sms').then(function () {
			POLL_SECS = confInt('poll', 5);
			MARK_READ  = confInt('mark_read_on_open', 1);
			return call('list', []);
		});
	},

	/* ── 弹窗看完整内容 ───────────────────────────────── */
	showMessage: function (m) {
		var self = this;
		var body = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-descr' },
				esc(m.sender) + '　' + esc(m.time || '')),
			E('div', {
				'style': 'white-space:pre-wrap; word-break:break-word; ' +
					'max-height:50vh; overflow-y:auto; padding:8px 0;'
			}, m.body || '')
		]);

		if (m.parts)
			body.appendChild(E('div', { 'class': 'cbi-section-descr' },
				_('长短信：收到 %d/%d 段').format(m.parts.have, m.parts.total)));

		var btns = [
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.hideModal
			}, _('关闭')),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-negative',
				'click': function () {
					return call('delete', [ m.idx ]).then(function (r) {
						ui.hideModal();
						if (r.error) ui.addNotification(null, E('p', {}, r.error), 'error');
						else self.refresh();
					});
				}
			}, _('从 SIM 删除'))
		];

		/* 打开就标记已读（AT+CMGR 的副作用，和手机上的行为一致）。
		 * 关掉这个开关就不发 CMGR —— 有些人不希望动 SIM 上的状态位。 */
		if (m.unread && MARK_READ)
			call('mark', [ m.idx ]).then(function () { self.refresh(); });

		ui.showModal(_('短信详情'), [ body, E('div', { 'class': 'right' }, btns) ]);
	},

	/* ── 列表一行 ─────────────────────────────────────── */
	renderRow: function (m) {
		var self = this;

		if (m.error)
			return E('div', { 'class': 'cbi-section-descr' },
				_('第 %s 条解析失败：%s').format(m.idx, m.error));

		return E('div', {
			'style': 'padding:10px 6px; border-bottom:1px solid rgba(128,128,128,.25); ' +
				'cursor:pointer; -webkit-tap-highlight-color:transparent;',
			'click': function () { self.showMessage(m); }
		}, [
			E('div', { 'style': 'display:flex; align-items:baseline; gap:8px;' }, [
				E('strong', {
					'style': 'flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;'
				}, esc(m.sender)),
				E('span', { 'class': 'cbi-section-descr', 'style': 'flex:none;' },
					shortTime(m.time)),
				m.unread ? E('span', {
					'style': 'flex:none; width:8px; height:8px; border-radius:50%; ' +
						'background:currentColor; opacity:.7;'
				}) : ''
			]),
			E('div', {
				/* 两行截断：显示不下自动省略号，点击弹窗看全文 */
				'style': 'margin-top:4px; opacity:.85; ' +
					'display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; ' +
					'overflow:hidden; word-break:break-word;'
			}, esc(m.body))
		]);
	},

	/* ── 发送区 ───────────────────────────────────────── */
	renderCompose: function () {
		var self = this;
		var to = E('input', {
			'type': 'text', 'class': 'cbi-input-text',
			'placeholder': _('收件人号码，如 10086'),
			'style': 'flex:0 0 34%; min-width:110px;'
		});
		var text = E('input', {
			'type': 'text', 'class': 'cbi-input-text',
			'placeholder': _('短信内容'), 'style': 'flex:1; min-width:120px;'
		});

		function doSend() {
			var num = (to.value || '').trim(), msg = (text.value || '').trim();
			if (!num) { ui.addNotification(null, E('p', {}, _('请填收件人')), 'warning'); return; }
			if (!msg) { ui.addNotification(null, E('p', {}, _('请填内容')), 'warning'); return; }

			ui.showModal(_('确认发送'), [
				E('p', {}, _('发给 %s：').format(num)),
				E('p', { 'style': 'word-break:break-word;' }, msg),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, _('取消')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': function () {
							return call('send', [ num, msg ]).then(function (r) {
								ui.hideModal();
								if (r.error)
									ui.addNotification(null, E('p', {}, _('发送失败：') + r.error), 'error');
								else {
									ui.addNotification(null, E('p', {}, _('已发送')), 'info');
									text.value = '';
									self.refresh();
								}
							});
						}
					}, _('发送'))
				])
			]);
		}

		text.addEventListener('keydown', function (ev) {
			if (ev.key === 'Enter') doSend();
		});

		return E('div', {
			'class': 'cbi-section',
			'style': 'position:sticky; bottom:0; background:inherit; padding-top:8px;'
		}, [
			E('div', { 'style': 'display:flex; gap:6px; flex-wrap:wrap;' }, [
				to, text,
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'style': 'flex:none;',
					'click': doSend
				}, _('发送'))
			])
		]);
	},

	/* ── 主渲染 ───────────────────────────────────────── */
	render: function (data) {
		var self = this;
		var listBox = E('div', {
			'id': 'openfi-sms-list',
			'style': 'max-height:60vh; overflow-y:auto; -webkit-overflow-scrolling:touch;'
		});
		var meta = E('div', { 'class': 'cbi-section-descr' });

		var container = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('短信')),
			meta,
			E('div', { 'class': 'cbi-section' }, [ listBox ]),
			this.renderCompose()
		]);

		this.fill = function (d) {
			while (listBox.firstChild) listBox.removeChild(listBox.firstChild);

			if (d.error) {
				meta.textContent = _('错误：') + d.error;
				return;
			}

			var msgs = d.messages || [];
			meta.textContent = _('共 %d 条').format(msgs.length);

			if (!msgs.length) {
				listBox.appendChild(E('div', { 'class': 'cbi-section-descr' },
					_('SIM 卡上还没有短信。')));
				return;
			}

			for (var i = 0; i < msgs.length; i++)
				listBox.appendChild(self.renderRow(msgs[i]));
		};

		this.refresh = function () {
			return call('list', []).then(function (d) { self.fill(d); });
		};

		this.fill(data || {});
		/* 下限 2 秒：这一步只是读缓存文件（不碰串口），可以快一点 */
		if (POLL_SECS < 2) POLL_SECS = 2;
		if (POLL_SECS > 600) POLL_SECS = 600;
		poll.add(function () { return self.refresh(); }, POLL_SECS);

		return container;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
