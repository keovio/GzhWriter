// 数据、模型调用、一键成稿流程
const { reactive } = Vue
const uid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random())
const now = () => new Date().toISOString()

const ROLES = [
  { key: 'topic', title: '选题与大纲', uses: '选题、大纲' },
  { key: 'draft', title: '写正文', uses: '写正文、返修、各平台版本、小红书/微博' },
  { key: 'review', title: '审稿', uses: '审稿打分' },
]

function blankData() {
  return {
    articles: [], styles: [], connections: [], roles: {}, roleModels: {}, accounts: [],
    auto: { passScore: 80, maxRounds: 2, targetWords: 1500, variants: true },
  }
}

const S = reactive({
  data: blankData(),
  loaded: false,
  running: {},       // 稿件 id → 当前步骤
  calling: '',       // 正在调用的模型
  queue: 0,
  toast: '',
})

let saveTimer = null
const Store = {
  async load() {
    const raw = await api.load()
    if (raw) { try { S.data = Object.assign(blankData(), JSON.parse(raw)) } catch {} }
    S.data.auto = Object.assign(blankData().auto, S.data.auto || {})
    if (!S.data.styles.length) S.data.styles.push(this.newStyle('我的公众号'))
    if (!S.data.accounts.length) S.data.accounts.push({ id: uid(), platform: 'wechat', name: S.data.styles[0].name, styleId: S.data.styles[0].id, appId: '' })
    S.loaded = true
  },
  save() {
    clearTimeout(saveTimer)
    saveTimer = setTimeout(() => api.save(JSON.stringify(S.data, null, 1)), 400)
  },
  newStyle(name) { return { id: uid(), name, track: '', audience: '', sample: '', avoid: '', signature: '', author: '' } },
  newArticle(o = {}) {
    const a = Object.assign({
      id: uid(), topic: '', viewpoint: '', material: '', title: '', outline: [], sections: [], kind: 'auto',
      review: null, stage: 'topic', styleId: null, accountId: null, primary: 'wechat', variants: {}, posts: {},
      template: 'magazine', accent: '#3F68A8', fontSize: 15, aiNotice: false, digest: '', log: [], failed: '',
      created: now(), updated: now(),
    }, o)
    S.data.articles.unshift(a)
    this.save()
    return S.data.articles[0]
  },
  article(id) { return S.data.articles.find(a => a.id === id) },
  style(id) { return S.data.styles.find(s => s.id === id) || S.data.styles[0] },
  account(id) { return S.data.accounts.find(a => a.id === id) },
  accountsOn(p) { return S.data.accounts.filter(a => a.platform === p) },
  touch(a) { a.updated = now(); this.save() },
  flash(t) { S.toast = t; setTimeout(() => { if (S.toast === t) S.toast = '' }, 2200) },
}

// ---------- 模型 ----------
function connsFor(role) {
  const ids = (S.data.roles[role] || []).filter(id => S.data.connections.some(c => c.id === id))
  const list = ids.length ? ids.map(id => S.data.connections.find(c => c.id === id)) : S.data.connections
  return list.map(c => ({ ...c, model: S.data.roleModels[role + '.' + c.id] || c.model }))
}
function modelLabel(role) {
  const c = connsFor(role)[0]
  return c ? `${c.name}（${c.model}）` : '还没配模型'
}

class LLMError extends Error { constructor(m, fatal) { super(m); this.fatal = fatal } }

async function run(role, messages, temperature = 0.7) {
  const list = connsFor(role)
  if (!list.length) throw new LLMError('还没有可用的模型。先到「设置 → 模型」添加一个。', true)
  const errs = []
  let fatal = true
  for (const c of list) {
    S.calling = `${c.name}（${c.model}）`
    const r = await api.chat({ connId: c.id, name: c.name, baseURL: c.baseURL, model: c.model, messages, temperature })
    S.calling = ''
    if (r.content) return r.content
    errs.push(`· ${c.name}：${r.error}`)
    if (!r.fatal) fatal = false
  }
  throw new LLMError(list.length === 1 ? errs[0].replace(/^· [^：]+：/, '') : '所有模型都失败了：\n' + errs.join('\n'), fatal)
}

function parseJSON(raw) {
  let s = raw.trim().replace(/^```(json)?/i, '').replace(/```$/, '').trim()
  const i = s.indexOf('{'), j = s.lastIndexOf('}')
  if (i >= 0 && j > i) s = s.slice(i, j + 1)
  return JSON.parse(s)
}
async function runJSON(role, messages) {
  let last
  for (let n = 0; n < 2; n++) {
    const raw = await run(role, messages, 0.6)
    try { return parseJSON(raw) } catch (e) { last = new Error('模型返回的格式没法解析，可以再试一次。') }
  }
  throw last
}

// ---------- 去 AI 味 / 去重 ----------
const clean = s => String(s || '').replace(/——/g, '，').replace(/，，/g, '，').trim()
function bigrams(s) { const t = String(s).replace(/\s/g, ''); const set = new Set(); for (let i = 0; i < t.length - 1; i++) set.add(t.slice(i, i + 2)); return set }
function similar(a, b) {
  const x = bigrams(a), y = bigrams(b)
  if (!x.size || !y.size) return 0
  let n = 0; for (const g of x) if (y.has(g)) n++
  return n / Math.min(x.size, y.size)
}
function closest(t, list) {
  let best = null
  for (const s of list) { const v = similar(t, s); if (!best || v > best[1]) best = [s, v] }
  return best
}

// ---------- 一键成稿 ----------
const Pipeline = {
  q: [],
  busy: false,
  enqueue(direction, account, count = 1) {
    for (let i = 0; i < count; i++) this.q.push({ direction, account })
    S.queue = this.q.length
    this.pump()
  },
  resume(a) { this.q.push({ resume: a.id }); S.queue = this.q.length; this.pump() },
  async pump() {
    if (this.busy) return
    this.busy = true
    while (this.q.length) {
      const job = this.q.shift()
      S.queue = this.q.length
      if (job.resume) await this.work(Store.article(job.resume), '', true)
      else {
        const acc = job.account
        const a = Store.newArticle({
          topic: job.direction || '自动选题中…', primary: acc?.platform || 'wechat',
          accountId: acc?.id || null, styleId: acc?.styleId || S.data.styles[0]?.id, auto: true,
        })
        await this.work(a, job.direction, false)
      }
    }
    this.busy = false
  },
  log(a, msg) {
    S.running[a.id] = msg
    a.log.push(new Date().toTimeString().slice(0, 8) + '  ' + msg)
    Store.save()
  },
  async work(a, direction, resumed) {
    if (!a) return
    let attempt = 0, step = ''
    while (true) {
      try {
        await this.steps(a, direction, resumed || attempt > 0)
        a.failed = ''
        break
      } catch (e) {
        if (attempt === 0) step = S.running[a.id] || ''
        attempt++
        if (attempt <= 2 && !e.fatal) {
          this.log(a, `出错：${e.message}。${attempt * 15} 秒后自动接着写（第 ${attempt} 次）`)
          await new Promise(r => setTimeout(r, attempt * 15000))
          continue
        }
        this.log(a, '停下了：' + e.message)
        a.failed = (step ? `在「${step}」这一步` : '') + '出错：' + e.message
        break
      }
    }
    delete S.running[a.id]
    Store.touch(a)
  },
  async steps(a, direction, resumed) {
    const st = S.data.auto
    const style = Store.style(a.styleId)
    if (resumed) this.log(a, '从断点接着写')
    this.log(a, `模型：选题 ${modelLabel('topic')}；正文 ${modelLabel('draft')}；审稿 ${modelLabel('review')}`)

    // 1 选题
    if (!a.sections.length && !a.viewpoint) {
      this.log(a, '选题')
      const existing = S.data.articles.filter(x => x.id !== a.id).map(x => x.title || x.topic).filter(Boolean)
      const rejected = []
      let t = await runJSON('topic', Prompts.pickTopic(direction, style, existing))
      while (rejected.length < 2) {
        const near = closest(t.topic || '', existing)
        if (!near || near[1] < 0.6) break
        this.log(a, `「${t.topic}」和写过的「${near[0]}」太像，换一个`)
        rejected.push(t.topic)
        t = await runJSON('topic', Prompts.pickTopic(direction, style, existing, rejected))
      }
      a.topic = t.topic || direction
      a.viewpoint = t.viewpoint || ''
      if (t.angle) a.material = '切入角度：' + t.angle
      this.log(a, '选题：' + a.topic)
    }

    // 小红书 / 微博：直接写短内容
    const pf = P[a.primary]
    if (pf && pf.short) {
      if (!a.variants[a.primary]?.body) {
        this.log(a, '写' + pf.name)
        const v = await runJSON('draft', Prompts.short(a, a.primary, style))
        a.variants[a.primary] = { title: v.title || '', intro: '', tags: v.tags || [], body: clean(v.body) }
        if (!a.title) a.title = v.title || a.topic
      }
      a.stage = 'layout'
      this.log(a, '完成，等你过目')
      return
    }

    // 2 大纲
    if (!a.sections.length) {
      this.log(a, '定文章类型、写大纲')
      const o = await runJSON('topic', Prompts.outline(a, style))
      if (o.title) a.title = o.title
      if ((!a.kind || a.kind === 'auto') && KINDS[o.kind] && o.kind !== 'auto') a.kind = o.kind
      a.outline = o.outline || []
      a.sections = a.outline.map(x => ({ heading: x.split(/[:：]/)[0].trim(), body: '' }))
      a.stage = 'draft'
      Store.save()
    }

    // 3 正文
    const n = Math.max(1, a.sections.length)
    const per = Math.max(250, Math.floor(st.targetWords / n))
    for (let i = 0; i < n; i++) {
      if ((a.sections[i].body || '').trim()) continue
      this.log(a, `写第 ${i + 1}/${n} 部分`)
      a.sections[i].body = clean(await run('draft', Prompts.section(a, i, style, per)))
      Store.save()
    }

    // 4 审稿 + 返修，取最高分
    let round = 0, best = null
    while (true) {
      this.log(a, round === 0 ? '审稿' : `第 ${round} 轮返修后重审`)
      const r = await runJSON('review', Prompts.review(Layout.plain(a)))
      r.total = Number(r.total) || 0
      a.review = r; a.stage = 'review'
      if (!best || r.total > best.score) best = { score: r.total, sections: JSON.parse(JSON.stringify(a.sections)), review: r }
      this.log(a, '得分 ' + r.total)
      if (r.total >= st.passScore || round >= st.maxRounds) break
      round++
      const groups = {}
      for (const s of r.suggestions || []) if (s.section >= 1) (groups[s.section - 1] ||= []).push(s)
      for (const idx of Object.keys(groups).map(Number).sort((x, y) => x - y)) {
        if (idx >= a.sections.length) continue
        this.log(a, `返修第 ${idx + 1} 部分`)
        const ins = groups[idx].map(s => `问题：${s.issue}；改法：${s.fix}`).join('\n')
        a.sections[idx].body = clean(await run('draft', Prompts.revise(a, idx, ins, style)))
      }
    }
    if (best && (a.review?.total || 0) < best.score) {
      a.sections = best.sections; a.review = best.review
      this.log(a, `回退到最高分版本（${best.score}）`)
    }
    a.stage = 'layout'

    // 5 平台版本
    if (pf && pf.long) {
      await Variants.make(a, [a.primary])
    } else if (st.variants) {
      const others = [...new Set(S.data.accounts.map(x => x.platform))].filter(k => k !== 'wechat')
      if (others.length) { this.log(a, '出其他平台版本'); try { await Variants.make(a, others) } catch (e) { this.log(a, '平台版本出错：' + e.message) } }
    }
    this.log(a, '完成，等你过目')
  },
}

const Variants = {
  async make(a, targets) {
    const plain = Layout.plain(a)
    const long = targets.filter(k => P[k]?.long), short = targets.filter(k => P[k]?.short)
    if (long.length) {
      const r = await runJSON('draft', Prompts.longVariants(a, plain, long))
      for (const k of long) if (r[k]) a.variants[k] = { title: r[k].title || '', intro: r[k].intro || '', tags: r[k].tags || [], body: '' }
      if (r.digest) a.digest = r.digest
    }
    if (short.length) {
      const r = await runJSON('draft', Prompts.shortVariants(a, plain, short))
      for (const k of short) if (r[k]) a.variants[k] = { title: r[k].title || '', intro: '', tags: r[k].tags || [], body: clean(r[k].body) }
    }
    Store.touch(a)
  },
}
