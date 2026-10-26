// 排版：公众号可直接粘贴的 HTML（全部行内样式），以及各平台的纯净版本
const Layout = {
  templates: [['magazine', '杂志卡片'], ['plain', '纯文字'], ['highlight', '重点高亮'], ['minimal', '极简留白']],
  accents: [['#3F68A8', '雾蓝'], ['#2F7D5B', '墨绿'], ['#B4532A', '砖红'], ['#7A5BA6', '藕紫'], ['#C48A1C', '琥珀'], ['#333333', '墨黑']],

  esc(s) { return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;') },
  paras(body) { return String(body || '').split(/\r?\n/).map(x => x.trim()).filter(Boolean) },
  inline(s, ac) {
    return this.esc(s)
      .replace(/\*\*(.+?)\*\*/g, `<strong style="color:${ac};font-weight:bold;">$1</strong>`)
      .replace(/【待核实[:：]?(.*?)】/g, '<span style="background:#FFF3B0;color:#8A6200;">【待核实：$1】</span>')
  },

  html(a, signature = '') {
    const ac = a.accent || '#3F68A8', fs = a.fontSize || 15, tpl = a.template || 'magazine'
    const showH = (KINDS[a.kind] || KINDS.auto).headings
    const p = `margin:0 0 1.2em;font-size:${fs}px;line-height:1.9;letter-spacing:0.5px;color:#3a3a3a;text-align:justify;`
    const quote = `margin:0 0 1.2em;padding:12px 16px;border-left:3px solid ${ac};background:#F6F7FA;color:#555;font-size:${fs - 1}px;line-height:1.8;`
    const n2 = i => String(i + 1).padStart(2, '0')
    const heading = (i, text) => {
      const h = this.inline(text, ac)
      if (tpl === 'plain') return `<h3 style="margin:2em 0 1em;font-size:${fs + 2}px;font-weight:bold;color:#222;">${h}</h3>`
      if (tpl === 'highlight') return `<h3 style="margin:2em 0 1em;text-align:center;"><span style="display:inline-block;padding:4px 14px;background:${ac};color:#fff;border-radius:4px;font-size:${fs + 1}px;font-weight:bold;">${h}</span></h3>`
      if (tpl === 'minimal') return `<h3 style="margin:2.4em 0 1.2em;text-align:center;font-size:${fs + 1}px;font-weight:normal;letter-spacing:2px;color:#222;"><span style="color:${ac};">— ${n2(i)} —</span><br>${h}</h3>`
      return `<h3 style="margin:2em 0 1em;padding-left:10px;border-left:4px solid ${ac};font-size:${fs + 2}px;font-weight:bold;color:#222;line-height:1.5;"><span style="color:${ac};margin-right:6px;">${n2(i)}</span>${h}</h3>`
    }
    let out = `<section style="padding:0 4px;font-family:-apple-system,'Microsoft YaHei','PingFang SC',sans-serif;">`
    a.sections.forEach((sec, i) => {
      if (sec.heading && showH) out += heading(i, sec.heading)
      let block = ''
      for (const line of this.paras(sec.body)) {
        if (line.startsWith('>')) block += `<blockquote style="${quote}">${this.inline(line.replace(/^>+\s*/, ''), ac)}</blockquote>`
        else block += `<p style="${p}">${this.inline(line, ac)}</p>`
      }
      out += tpl === 'magazine'
        ? `<section style="margin:0 0 1.5em;padding:18px 16px 2px;background:#FAFBFD;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,0.06);">${block}</section>`
        : block
    })
    if (signature) out += `<p style="margin:2em 0 0;text-align:center;font-size:${fs - 1}px;color:#888;">${this.inline(signature, ac)}</p>`
    if (a.aiNotice) out += `<p style="margin:1.5em 0 0;text-align:center;font-size:12px;color:#aaa;">本文由作者在 AI 辅助下完成</p>`
    return out + '</section>'
  },

  plain(a) {
    const showH = (KINDS[a.kind] || KINDS.auto).headings
    let t = (a.title || '') + '\n\n'
    for (const s of a.sections) {
      if (s.heading && showH) t += s.heading + '\n\n'
      t += this.paras(s.body).map(x => x.replace(/^>+\s*/, '').replace(/\*\*/g, '')).join('\n\n') + '\n\n'
    }
    return t.trim()
  },

  // 平台版本：短内容用自己的正文；长文沿用主稿，换开头
  platformHTML(a, v, key) {
    if (v.body) return this.paras(this.platformFull(a, v, key)).map(x => `<p>${this.esc(x)}</p>`).join('')
    const showH = (KINDS[a.kind] || KINDS.auto).headings
    let out = ''
    a.sections.forEach((s, i) => {
      if (s.heading && showH) out += `<h2>${this.esc(s.heading)}</h2>`
      const ps = this.paras(s.body)
      if (i === 0 && v.intro && ps.length) ps[0] = v.intro
      for (const x of ps) out += `<p>${this.esc(x.replace(/^>+\s*/, '').replace(/\*\*/g, ''))}</p>`
    })
    return out
  },

  platformFull(a, v, key) {
    if (v.body) {
      const tags = (v.tags || []).map(t => '#' + t.replace(/^#/, '') + (key === 'weibo' ? '#' : '')).join(' ')
      return (v.body.trim() + (tags ? '\n\n' + tags : '')).trim()
    }
    const showH = (KINDS[a.kind] || KINDS.auto).headings
    let t = ''
    a.sections.forEach((s, i) => {
      if (s.heading && showH) t += s.heading + '\n\n'
      const ps = this.paras(s.body)
      if (i === 0 && v.intro && ps.length) ps[0] = v.intro
      t += ps.map(x => x.replace(/^>+\s*/, '').replace(/\*\*/g, '')).join('\n\n') + '\n\n'
    })
    return t.trim()
  },
}
