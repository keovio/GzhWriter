// 界面
const { createApp, computed, ref, watch, nextTick } = Vue

const fmtTime = (iso) => {
  const d = new Date(iso), n = new Date()
  const hm = d.toTimeString().slice(0, 5)
  if (d.toDateString() === n.toDateString()) return '今天 ' + hm
  return `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`
}
const words = (a) => (a.sections || []).reduce((n, s) => n + (s.body || '').replace(/\s/g, '').length, 0) + (a.variants?.[a.primary]?.body || '').length * (P[a.primary]?.short ? 1 : 0)
const status = (a) => S.running[a.id] ? '写作中：' + S.running[a.id] : a.failed ? '停下了' : a.stage === 'layout' ? '已完成，待发布' : '写作中'
const pf = (k) => P[k] || { name: k, color: '#888' }

// ---------- 小组件 ----------
const Switch = {
  props: ['modelValue'], emits: ['update:modelValue'],
  template: `<div class="switch" :class="{on: modelValue}" @click="$emit('update:modelValue', !modelValue)"></div>`,
}
const Menu = {
  props: ['items', 'label', 'cls'], emits: ['pick'],
  data: () => ({ open: false }),
  mounted() { this.off = (e) => { if (!this.$el.contains(e.target)) this.open = false }; document.addEventListener('click', this.off) },
  unmounted() { document.removeEventListener('click', this.off) },
  template: `<span class="menu"><button :class="cls || 'btn ghost sm'" @click="open = !open"><slot>{{ label }}</slot></button>
    <div class="pop" v-if="open"><div v-for="it in items" :key="it[0]" @click="open = false; $emit('pick', it[0])">{{ it[1] }}</div></div></span>`,
}
const ModelTag = {
  props: ['text', 'prefix'],
  template: `<span class="mtag">⚙ {{ prefix || '模型' }}：{{ text }}</span>`,
}
const PTag = {
  props: ['k'],
  template: `<span class="tag" :style="{color: c, background: c + '1A'}">{{ n }}</span>`,
  computed: { c() { return pf(this.k).color }, n() { return pf(this.k).name } },
}

// ---------- 工作台 ----------
const Workbench = {
  components: { ModelTag, PTag },
  emits: ['open'],
  data: () => ({ direction: '', count: 1, accountId: null }),
  computed: {
    S: () => S,
    greet() { const h = new Date().getHours(); return h < 11 ? '早上好' : h < 14 ? '中午好' : h < 18 ? '下午好' : '晚上好' },
    account() { return Store.account(this.accountId) || S.data.accounts[0] },
    target() { return this.account?.platform || 'wechat' },
    hint() {
      const t = this.target, w = S.data.auto.targetWords
      if (t === 'xiaohongshu') return '300 到 600 字小红书笔记，不写长文'
      if (t === 'weibo') return '140 到 300 字微博，不写长文'
      if (t === 'wechat') return `约 ${w} 字长文，写完顺带出其他平台版`
      return `约 ${w} 字长文，按${pf(t).name}的规则出标题和标签`
    },
    models() { const l = ROLES.map(r => modelLabel(r.key)); return new Set(l).size === 1 ? [['用', l[0]]] : ROLES.map((r, i) => [r.title + '用', l[i]]) },
    stats() {
      const arts = S.data.articles, d0 = new Date(); d0.setHours(0, 0, 0, 0)
      const w0 = new Date(d0); w0.setDate(w0.getDate() - ((w0.getDay() + 6) % 7))
      const today = arts.filter(a => new Date(a.created) >= d0), week = arts.filter(a => new Date(a.created) >= w0)
      const scored = arts.filter(a => a.review?.total)
      const avg = scored.length ? Math.round(scored.reduce((n, a) => n + a.review.total, 0) / scored.length) : 0
      return [
        ['#4361EE', '✎', '今日成稿', today.length, '篇', today.reduce((n, a) => n + words(a), 0) + ' 字'],
        ['#7B5CF0', '▦', '本周', week.length, '篇', week.reduce((n, a) => n + words(a), 0) + ' 字'],
        ['#1F9D6B', '★', '平均分', scored.length ? avg : '—', scored.length ? '分' : '', '及格线 ' + S.data.auto.passScore],
        ['#E8590C', '➤', '待发布', arts.filter(a => a.stage === 'layout').length, '篇', '已排好版'],
      ]
    },
    running() { return S.data.articles.filter(a => S.running[a.id]) },
    failed() { return S.data.articles.filter(a => a.failed && !S.running[a.id]).slice(0, 5) },
    recent() { return S.data.articles.slice(0, 6) },
  },
  methods: {
    pf, status, words, fmtTime,
    go() { Pipeline.enqueue(this.direction.trim(), this.account, this.count); this.direction = ''; Store.flash('开始写了，进度在下面') },
    resume(a) { Pipeline.resume(a) },
  },
  template: `<div class="page">
    <div class="ph"><div><h1>{{ greet }}</h1><p>{{ S.data.connections.length ? '看看今天写到哪了。' : '先到「设置 → 模型」接一个模型，就能开始一键成稿。' }}</p></div>
      <div class="sp"></div><span v-if="S.queue || running.length" class="tag" style="background:var(--blueBg);color:var(--blue)">后台在写 {{ running.length + S.queue }} 篇</span></div>
    <div class="stats"><div class="stat" v-for="s in stats" :style="{'--c': s[0]}">
      <div class="lb"><span class="ic">{{ s[1] }}</span>{{ s[2] }}</div><div class="v">{{ s[3] }}<small>{{ s[4] }}</small></div><div class="faint">{{ s[5] }}</div></div></div>

    <div class="card compose">
      <div class="st">写一篇 <small>留空自动选题</small><span class="sp"></span><ModelTag v-for="m in models" :prefix="m[0]" :text="m[1]" style="margin-left:6px"/></div>
      <div class="chips"><span class="muted" style="align-self:center;margin-right:4px">发到</span>
        <button v-for="acc in S.data.accounts" class="chip" :class="{on: account && account.id === acc.id}" @click="accountId = acc.id">
          <span class="pf" :style="{color: pf(acc.platform).color}">{{ pf(acc.platform).name }}</span>{{ acc.name }}</button></div>
      <textarea v-model="direction" placeholder="想写什么？比如：在职备考公务员，每天两小时怎么安排" @keydown.ctrl.enter="go"></textarea>
      <div class="row" style="margin-top:12px"><span class="muted">篇数</span>
        <span class="seg"><button v-for="n in [1,3,5]" :class="{on: count === n}" @click="count = n">{{ n }}</button></span>
        <span class="muted" style="margin-left:8px">{{ hint }}</span><span class="sp"></span>
        <button class="btn primary" :disabled="!S.data.connections.length" @click="go">✦ 开始写</button></div>
    </div>

    <div class="card" v-if="running.length || S.queue"><div class="st">正在写</div>
      <div class="runline" v-for="a in running"><span class="spin"></span><b style="flex:1">{{ a.title || a.topic }}</b><span class="muted">{{ S.running[a.id] }}</span><ModelTag v-if="S.calling" :text="S.calling"/></div>
      <div class="faint" v-if="S.queue">还有 {{ S.queue }} 篇排队</div></div>

    <div class="card" v-if="failed.length"><div class="st">停下来的稿件 <small>出错了，可以从断点接着写</small></div>
      <div class="runline" v-for="a in failed"><b style="flex:1;cursor:pointer" @click="$emit('open', a.id)">{{ a.title || a.topic }}</b><span class="muted" style="max-width:420px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{ a.failed }}</span><button class="btn ghost sm" @click="resume(a)">接着写</button></div></div>

    <div class="card"><div class="st">最近稿件</div>
      <div class="list" v-if="recent.length"><div class="it" v-for="a in recent" @click="$emit('open', a.id)">
        <div class="ico">{{ a.stage === 'layout' ? '✓' : '…' }}</div>
        <div style="flex:1;min-width:0"><div class="tt">{{ a.title || a.topic || '未命名' }}</div><div class="meta"><PTag :k="a.primary"/> {{ status(a) }} · {{ words(a) }} 字 · {{ fmtTime(a.created) }}</div></div>
        <span class="score" v-if="a.review" :style="{color: a.review.total >= S.data.auto.passScore ? 'var(--green)' : 'var(--orange)'}">{{ a.review.total }}</span></div></div>
      <div class="empty" v-else>还没有稿件，在上面写一篇试试。</div></div>
  </div>`,
}

// ---------- 稿件库 ----------
const Library = {
  components: { PTag },
  emits: ['open'],
  data: () => ({ q: '', f: 0, acc: '' }),
  computed: {
    S: () => S,
    items() {
      return S.data.articles.filter(a => (!this.q || (a.title + a.topic).includes(this.q))
        && (this.f === 0 || (this.f === 1 ? a.stage === 'layout' : a.stage !== 'layout'))
        && (!this.acc || a.accountId === this.acc))
    },
  },
  methods: {
    status, words, fmtTime, pf,
    newOne() { this.$emit('open', Store.newArticle({ styleId: S.data.styles[0]?.id, accountId: S.data.accounts[0]?.id }).id) },
    del(a) { if (confirm('删除《' + (a.title || a.topic) + '》？')) { S.data.articles.splice(S.data.articles.indexOf(a), 1); Store.save() } },
  },
  template: `<div class="page">
    <div class="ph"><div><h1>稿件库</h1><p>写过的文章都在这里，自动选题会避开这些题目。</p></div><div class="sp"></div><button class="btn ghost" @click="newOne">＋ 自己写</button></div>
    <div class="row" style="margin-bottom:14px"><input class="field" v-model="q" placeholder="搜索标题或选题" style="width:280px">
      <button v-for="(t, i) in ['全部','待发布','写作中']" class="chip" :class="{on: f === i}" @click="f = i">{{ t }}</button>
      <select class="field" v-model="acc" v-if="S.data.accounts.length > 1"><option value="">全部账号</option>
        <option v-for="x in S.data.accounts" :value="x.id">{{ pf(x.platform).name }}·{{ x.name }}</option></select>
      <span class="sp"></span><span class="faint">{{ items.length }} 篇</span></div>
    <div class="card list"><div class="it" v-for="a in items" @click="$emit('open', a.id)">
      <div class="ico">{{ a.stage === 'layout' ? '✓' : '…' }}</div>
      <div style="flex:1;min-width:0"><div class="tt">{{ a.title || a.topic || '未命名' }}</div><div class="meta"><PTag :k="a.primary"/> {{ status(a) }} · {{ words(a) }} 字 · {{ fmtTime(a.created) }}</div></div>
      <span class="score" v-if="a.review">{{ a.review.total }}</span>
      <button class="btn danger sm" @click.stop="del(a)">删除</button></div>
      <div class="empty" v-if="!items.length">没有符合条件的稿件</div></div>
  </div>`,
}

// ---------- 编辑器 ----------
const Editor = {
  components: { PTag, ModelTag, Menu },
  props: ['id'], emits: ['back'],
  data: () => ({ tab: 'main', busy: '' }),
  computed: {
    S: () => S,
    a() { return Store.article(this.id) },
    style() { return Store.style(this.a?.styleId) },
    acc() { return Store.account(this.a?.accountId) },
    isShort() { return !!P[this.a.primary]?.short },
    html() { return Layout.html(this.a, this.style?.signature) },
    variantKeys() { return Object.keys(this.a.variants || {}).filter(k => P[k]) },
    others() { return [...new Set(S.data.accounts.map(x => x.platform))].filter(k => k !== 'wechat') },
    steps() { const o = ['topic', 'draft', 'review', 'layout']; return [['选题', 'topic'], ['正文', 'draft'], ['审稿', 'review'], ['排版', 'layout']].map(s => [s[0], o.indexOf(s[1]) <= o.indexOf(this.a.stage)]) },
  },
  watch: { a: { deep: true, handler(a) { if (a) Store.save() } } },
  methods: {
    pf,
    copyRich() { api.copyHTML(this.html, Layout.plain(this.a)); Store.flash('已复制，到公众号编辑器里粘贴') },
    copyPlain() { api.copyText(Layout.plain(this.a)); Store.flash('已复制纯文本') },
    async makeVariants(keys) {
      this.busy = '正在出平台版本…'
      try { await Variants.make(this.a, keys) } catch (e) { alert(e.message) }
      this.busy = ''
    },
    async rereview() {
      this.busy = '审稿中…'
      try { const r = await runJSON('review', Prompts.review(Layout.plain(this.a))); r.total = Number(r.total) || 0; this.a.review = r } catch (e) { alert(e.message) }
      this.busy = ''
    },
    async op(i, how) {
      const ins = { rewrite: '换一种写法重写，意思不变，更好读。', expand: '在不编造事实的前提下扩写到原来的 1.5 倍左右，补充解释或作者视角的细节。', shrink: '精简到原来的 60% 左右，保留关键信息。', plain: '改得更口语、更像一个人在聊天，去掉书面套话。' }[how]
      this.busy = `改第 ${i + 1} 部分…`
      try { this.a.sections[i].body = clean(await run('draft', Prompts.revise(this.a, i, ins, this.style))) } catch (e) { alert(e.message) }
      this.busy = ''
    },
    full(k) { return Layout.platformFull(this.a, this.a.variants[k], k) },
    copyV(k, what) {
      const v = this.a.variants[k]
      if (what === 'title') api.copyText(v.title || this.a.title)
      else if (what === 'tags') api.copyText((v.tags || []).join(' '))
      else api.copyHTML(Layout.platformHTML(this.a, v, k), this.full(k))
      Store.flash('已复制')
    },
    fill(k, acc) {
      const v = this.a.variants[k]
      api.fill({ acc: { id: acc.id, platform: acc.platform, name: acc.name }, title: v.title || this.a.title, html: Layout.platformHTML(this.a, v, k), plain: this.full(k) })
    },
    weibo(k) { api.copyText(this.full(k)); api.openURL('https://weibo.com'); Store.flash('已复制，粘贴到微博发布') },
    posted(k, acc) { return !!this.a.posts?.[acc.id] },
    togglePost(k, acc) { this.a.posts ||= {}; if (this.a.posts[acc.id]) delete this.a.posts[acc.id]; else this.a.posts[acc.id] = new Date().toISOString() },
  },
  template: `<div class="page" v-if="a" style="max-width:1240px">
    <div class="row" style="margin-bottom:16px"><button class="btn link" @click="$emit('back')">‹ 返回</button><PTag :k="a.primary"/><span class="muted" v-if="acc">{{ acc.name }}</span>
      <span class="sp"></span><div class="steps"><span v-for="s in steps" :class="{on: s[1]}">{{ s[0] }}</span></div></div>
    <div class="card" v-if="S.running[a.id]"><div class="runline"><span class="spin"></span><b style="flex:1">{{ S.running[a.id] }}</b><ModelTag v-if="S.calling" :text="S.calling"/></div></div>
    <div class="card" v-if="a.failed && !S.running[a.id]" style="background:var(--orangeBg)"><div class="row"><b style="flex:1">{{ a.failed }}</b><button class="btn ghost sm" @click="Pipeline.resume(a)">接着写</button></div></div>

    <div class="row" style="margin-bottom:12px" v-if="!isShort"><button class="chip" :class="{on: tab==='main'}" @click="tab='main'">公众号正文</button>
      <button class="chip" :class="{on: tab==='plat'}" @click="tab='plat'">各平台版本</button><span class="sp"></span><span class="muted" v-if="busy">{{ busy }}</span></div>

    <!-- 短内容 -->
    <div v-if="isShort" class="card">
      <div class="st">{{ pf(a.primary).name }}内容<span class="sp"></span><span class="muted" v-if="busy">{{ busy }}</span></div>
      <template v-if="a.variants[a.primary]">
        <input class="titlein" v-if="a.primary !== 'weibo'" v-model="a.variants[a.primary].title" placeholder="标题">
        <textarea class="field" v-model="a.variants[a.primary].body" rows="14" style="margin-top:8px"></textarea>
        <div class="faint" style="margin:8px 0">标签：{{ (a.variants[a.primary].tags || []).join('  ') }}</div>
        <div class="row">
          <button class="btn ghost sm" @click="copyV(a.primary)">复制全文</button>
          <template v-if="P[a.primary].fill"><button v-for="x in Store.accountsOn(a.primary)" class="btn primary sm" @click="fill(a.primary, x)">打开「{{ x.name }}」自动填入</button></template>
          <button v-else class="btn primary sm" @click="weibo(a.primary)">复制并打开微博</button>
          <span class="sp"></span>
          <button v-for="x in Store.accountsOn(a.primary)" class="btn ghost sm" @click="togglePost(a.primary, x)">{{ posted(a.primary, x) ? '✓ ' + x.name + ' 已发' : x.name + ' 我发了' }}</button>
        </div>
      </template>
      <div class="empty" v-else>还在写…</div>
    </div>

    <!-- 公众号正文 -->
    <div class="ed" v-else-if="tab === 'main'">
      <div>
        <div class="card">
          <input class="titlein" v-model="a.title" placeholder="文章标题">
          <div class="faint" style="margin-bottom:8px">选题：{{ a.topic }}</div>
          <div class="sec" v-for="(s, i) in a.sections">
            <div class="row"><input v-model="s.heading" placeholder="小标题"><Menu :items="[['rewrite','重写'],['expand','扩写'],['shrink','精简'],['plain','更口语']]" label="AI 改" @pick="op(i, $event)"/></div>
            <textarea class="field" v-model="s.body"></textarea>
          </div>
          <div class="empty" v-if="!a.sections.length">{{ S.running[a.id] ? '正在写…' : '还没有正文' }}</div>
        </div>
        <div class="card" v-if="a.review"><div class="st">审稿<span class="sp"></span><span class="score" :style="{color: a.review.total >= S.data.auto.passScore ? 'var(--green)' : 'var(--orange)'}">{{ a.review.total }} 分</span></div>
          <div class="muted" style="margin:-4px 0 10px">{{ a.review.summary }}</div>
          <div class="row wrap" style="margin-bottom:10px"><span class="mtag" v-for="(v, k) in a.review.scores">{{ k }} {{ v }}</span><span class="sp"></span><button class="btn link" @click="rereview">重新审稿</button></div>
          <div v-for="s in a.review.suggestions" style="padding:6px 0;border-top:1px solid var(--rule)"><b>{{ s.section ? '第 ' + s.section + ' 部分' : '全文' }}</b>：{{ s.issue }} <span class="muted">→ {{ s.fix }}</span></div>
          <div v-if="a.review.factChecks && a.review.factChecks.length" style="margin-top:10px"><b>要核实：</b><span class="muted">{{ a.review.factChecks.join('；') }}</span></div>
          <div v-if="a.review.titles && a.review.titles.length" class="row wrap" style="margin-top:10px"><b>备选标题：</b><button class="chip" v-for="t in a.review.titles" @click="a.title = t">{{ t }}</button></div>
        </div>
        <div class="card" v-if="a.log.length"><div class="st">运行记录</div><div class="log">{{ a.log.slice(-40).join('\\n') }}</div></div>
      </div>
      <div>
        <div class="card">
          <div class="row" style="margin-bottom:12px"><button class="btn primary" @click="copyRich">复制到公众号</button><button class="btn ghost" @click="copyPlain">纯文本</button></div>
          <div class="row wrap" style="margin-bottom:12px">
            <select class="field" v-model="a.template"><option v-for="t in Layout.templates" :value="t[0]">{{ t[1] }}</option></select>
            <select class="field" v-model="a.accent"><option v-for="t in Layout.accents" :value="t[0]">{{ t[1] }}</option></select>
            <select class="field" v-model.number="a.fontSize"><option v-for="n in [14,15,16,17]" :value="n">{{ n }} 号字</option></select></div>
          <div class="phone"><h2>{{ a.title }}</h2><div class="by">{{ style?.author || acc?.name || '' }}</div><div v-html="html"></div></div>
        </div>
      </div>
    </div>

    <!-- 各平台版本 -->
    <div v-else>
      <div class="card" v-if="!others.length"><div class="empty">在「我的账号」里添加头条、知乎、小红书等账号，这里就会出对应的版本。</div></div>
      <div class="card" v-for="k in others">
        <div class="st"><PTag :k="k"/> <small>{{ pf(k).how }}</small><span class="sp"></span>
          <button class="btn link" :disabled="!!busy" @click="makeVariants([k])">{{ a.variants[k] ? '重写' : '生成' }}</button></div>
        <template v-if="a.variants[k]">
          <div v-if="a.variants[k].title"><b>{{ a.variants[k].title }}</b></div>
          <div class="pv" style="margin:8px 0">{{ full(k) }}</div>
          <div class="row wrap">
            <button class="btn ghost sm" v-if="a.variants[k].title" @click="copyV(k, 'title')">复制标题</button>
            <button class="btn ghost sm" @click="copyV(k)">复制正文</button>
            <button class="btn ghost sm" v-if="P[k].long && (a.variants[k].tags||[]).length" @click="copyV(k, 'tags')">复制标签</button>
            <span class="sp"></span>
            <template v-if="P[k].fill"><button v-for="x in Store.accountsOn(k)" class="btn primary sm" @click="fill(k, x)">打开「{{ x.name }}」自动填入</button></template>
            <button v-else class="btn primary sm" @click="weibo(k)">复制并打开微博</button>
            <button v-for="x in Store.accountsOn(k)" class="btn ghost sm" @click="togglePost(k, x)">{{ posted(k, x) ? '✓ ' + x.name + ' 已发' : x.name + ' 我发了' }}</button>
          </div>
        </template>
      </div>
      <div class="row" v-if="others.length"><button class="btn ghost" :disabled="!!busy || !a.sections.length" @click="makeVariants(others)">全部重新生成</button></div>
    </div>
  </div>`,
}

// ---------- 我的账号 ----------
const Accounts = {
  components: { PTag, Menu },
  computed: { S: () => S, groups() { return PLATFORMS.map(p => [p, Store.accountsOn(p.key)]).filter(g => g[1].length) } },
  methods: {
    pf,
    add(k) {
      const s = S.data.styles[0], same = Store.accountsOn(k).length
      S.data.accounts.push({ id: uid(), platform: k, name: same ? pf(k).name + (same + 1) : (s?.name || pf(k).name), styleId: s?.id, appId: '' })
      Store.save()
    },
    del(x) { if (confirm('删除账号「' + x.name + '」？写过的稿件不受影响。')) { S.data.accounts.splice(S.data.accounts.indexOf(x), 1); Store.save() } },
    login(x) { api.login({ id: x.id, platform: x.platform, name: x.name }) },
  },
  template: `<div class="page narrow">
    <div class="ph"><div><h1>我的账号</h1><p>每个平台可以有几个号。同一个领域的号选同一套风格就行，不用重复填范文。</p></div><div class="sp"></div>
      <Menu :items="PLATFORMS.map(p => [p.key, p.name])" label="＋ 添加账号" cls="btn ghost" @pick="add"/></div>
    <div class="card" v-for="g in groups">
      <div class="row" style="margin-bottom:6px"><PTag :k="g[0].key"/><span class="muted">{{ g[0].how }}</span></div>
      <div class="row" v-for="x in g[1]" style="padding:10px 0;border-top:1px solid var(--rule)">
        <div class="av" :style="{background: g[0].color}">{{ (x.name || '?').slice(0, 1) }}</div>
        <input class="field" v-model="x.name" @input="Store.save()" style="width:200px">
        <span class="muted">风格</span>
        <select class="field" v-model="x.styleId" @change="Store.save()" style="width:160px"><option v-for="s in S.data.styles" :value="s.id">{{ s.name }}</option></select>
        <span class="sp"></span>
        <button class="btn ghost sm" v-if="x.platform !== 'wechat'" @click="login(x)">登录</button>
        <button class="btn danger sm" v-if="S.data.accounts.length > 1" @click="del(x)">删除</button>
      </div>
    </div>
  </div>`,
}

// ---------- 风格 ----------
const Styles = {
  data: () => ({ sel: null }),
  computed: { S: () => S, s() { return S.data.styles.find(x => x.id === this.sel) || S.data.styles[0] } },
  methods: {
    add() { const s = Store.newStyle('新风格'); S.data.styles.push(s); this.sel = s.id; Store.save() },
    del() { if (S.data.styles.length > 1 && confirm('删除这套风格？')) { S.data.styles.splice(S.data.styles.indexOf(this.s), 1); this.sel = null; Store.save() } },
  },
  template: `<div class="page narrow">
    <div class="ph"><div><h1>风格</h1><p>一个领域一套：赛道、读者、范文。同领域的几个号共用一套，在「账号」里选。</p></div><div class="sp"></div><button class="btn ghost" @click="add">＋ 添加风格</button></div>
    <div class="row wrap" style="margin-bottom:16px"><button v-for="x in S.data.styles" class="chip" :class="{on: s && s.id === x.id}" @click="sel = x.id">{{ x.name }}</button></div>
    <div class="card" v-if="s" @input="Store.save()">
      <div class="setrow"><div class="lb"><b>风格名称</b></div><input class="field" v-model="s.name" style="width:380px"></div>
      <div class="setrow"><div class="lb"><b>赛道</b><span>写什么领域，比如：公务员考试备考</span></div><input class="field" v-model="s.track" style="width:380px"></div>
      <div class="setrow"><div class="lb"><b>读者</b><span>写给谁看</span></div><input class="field" v-model="s.audience" style="width:380px"></div>
      <div class="setrow"><div class="lb"><b>不写的话题</b></div><input class="field" v-model="s.avoid" style="width:380px"></div>
      <div class="setrow"><div class="lb"><b>文末一句话</b><span>每篇结尾自动带上</span></div><input class="field" v-model="s.signature" style="width:380px"></div>
      <div class="setrow"><div class="lb"><b>作者名</b></div><input class="field" v-model="s.author" style="width:380px"></div>
      <div style="padding-top:12px;border-top:1px solid var(--rule)"><b>范文</b> <span class="faint">贴一两篇你自己写的文章，AI 会模仿口吻</span>
        <textarea class="field" v-model="s.sample" rows="10" style="margin-top:8px"></textarea></div>
      <div class="row" style="margin-top:10px"><span class="sp"></span><button class="btn danger sm" v-if="S.data.styles.length > 1" @click="del">删除这套风格</button></div>
    </div>
  </div>`,
}

// ---------- 模型 ----------
const PRESETS = [
  { name: 'DeepSeek', baseURL: 'https://api.deepseek.com', model: 'deepseek-chat' },
  { name: '智谱 GLM', baseURL: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-4-flash' },
]
const Models = {
  components: { Menu },
  data: () => ({ sel: null, key: '', lists: {}, msg: '' }),
  computed: {
    S: () => S,
    c() { return S.data.connections.find(x => x.id === this.sel) || S.data.connections[0] },
    single() { return S.data.connections.length === 1 },
  },
  watch: { c: { immediate: true, async handler(c) { this.key = c ? await api.getSecret('conn.' + c.id) : ''; this.msg = '' } } },
  async mounted() { for (const c of S.data.connections) this.fetch(c) },
  methods: {
    add(p) { const c = { id: uid(), ...p }; S.data.connections.push(c); this.sel = c.id; Store.save() },
    del() {
      const c = this.c; if (!confirm('删除连接「' + c.name + '」？')) return
      api.setSecret('conn.' + c.id, '')
      S.data.connections.splice(S.data.connections.indexOf(c), 1)
      for (const k in S.data.roles) S.data.roles[k] = S.data.roles[k].filter(x => x !== c.id)
      this.sel = null; Store.save()
    },
    async saveKey() { await api.setSecret('conn.' + this.c.id, this.key.trim()); this.msg = '已保存'; this.fetch(this.c) },
    async fetch(c) { const l = await api.models({ connId: c.id, baseURL: c.baseURL }); if (l.length) this.lists[c.id] = l },
    async test() {
      await api.setSecret('conn.' + this.c.id, this.key.trim())
      this.msg = '测试中…'
      const r = await api.chat({ connId: this.c.id, name: this.c.name, baseURL: this.c.baseURL, model: this.c.model, messages: [{ role: 'user', content: '回复：好的' }], temperature: 0 })
      this.msg = r.content ? '✓ 连上了：' + r.content.slice(0, 20) : '没连上：' + r.error
    },
    picked(role) { const ids = (S.data.roles[role] || []).filter(id => S.data.connections.some(c => c.id === id)); return ids.length ? ids : S.data.connections.map(c => c.id) },
    conn(id) { return S.data.connections.find(c => c.id === id) },
    cur(role, c) { return S.data.roleModels[role + '.' + c.id] || c.model },
    opts(role, c) { const l = [...(this.lists[c.id] || [])]; for (const m of [c.model, this.cur(role, c)]) if (!l.includes(m)) l.unshift(m); return l.map(m => [m, m]) },
    setModel(role, c, m) { S.data.roleModels[role + '.' + c.id] = m; Store.save() },
    addTo(role, id) { S.data.roles[role] = [...this.picked(role), id]; Store.save() },
    remove(role, id) { S.data.roles[role] = this.picked(role).filter(x => x !== id); Store.save() },
    up(role, i) { const l = this.picked(role); [l[i - 1], l[i]] = [l[i], l[i - 1]]; S.data.roles[role] = l; Store.save() },
  },
  template: `<div class="page narrow">
    <div class="ph"><div><h1>模型</h1><p>每个连接是一个平台加一个 Key，Key 加密存在本机。下面再安排每一步用哪个模型。</p></div><div class="sp"></div>
      <Menu :items="PRESETS.map((p, i) => [i, '添加 ' + p.name]).concat([[-1, '其他（OpenAI 兼容）']])" label="＋ 添加连接" cls="btn ghost" @pick="i => add(i >= 0 ? PRESETS[i] : {name: '新连接', baseURL: 'https://', model: ''})"/></div>
    <div class="card" v-if="!S.data.connections.length"><div class="empty"><b>还没有模型连接</b><p>选 DeepSeek 或智谱 GLM，填上 API Key 就能用。兼容 OpenAI 接口的服务都能接。</p>
      <button class="btn primary" @click="add(PRESETS[0])">添加 DeepSeek</button> <button class="btn ghost" @click="add(PRESETS[1])">添加智谱 GLM</button></div></div>
    <div class="row wrap" style="margin-bottom:16px" v-if="S.data.connections.length > 1"><button v-for="x in S.data.connections" class="chip" :class="{on: c && c.id === x.id}" @click="sel = x.id">{{ x.name }}</button></div>
    <div class="card" v-if="c">
      <div class="st">连接设置<span class="sp"></span><button class="btn danger sm" @click="del">删除连接</button></div>
      <div class="setrow"><div class="lb"><b>名称</b></div><input class="field" v-model="c.name" @input="Store.save()" style="width:380px"></div>
      <div class="setrow"><div class="lb"><b>接口地址</b><span>Base URL</span></div><input class="field" v-model="c.baseURL" @input="Store.save()" style="width:380px"></div>
      <div class="setrow"><div class="lb"><b>API Key</b><span>加密保存在本机</span></div><input class="field" type="password" v-model="key" placeholder="sk-…" style="width:380px"></div>
      <div class="setrow"><div class="lb"><b>默认模型</b><span>每一步用哪个，在下面「角色分工」里换</span></div><input class="field" v-model="c.model" @input="Store.save()" style="width:380px"></div>
      <div class="row" style="margin-top:12px"><button class="btn primary" @click="saveKey">保存 Key</button><button class="btn ghost" @click="test">测试一下</button><span class="muted">{{ msg }}</span></div>
    </div>
    <div class="card" v-if="S.data.connections.length">
      <div class="st">角色分工 <small>{{ single ? '同一个平台，每一步可以用不同的模型' : '每一步选平台和模型；排第一的出错（限流、余额不足）自动换下一个' }}</small></div>
      <div class="setrow" v-for="r in ROLES"><div class="lb"><b>{{ r.title }}</b><span>用于：{{ r.uses }}</span></div>
        <div class="row">
          <span class="chip" v-for="(id, i) in picked(r.key)" :key="id" style="background:var(--blueBg);cursor:default">
            <b v-if="picked(r.key).length > 1" style="color:var(--blue);font-size:10px">{{ i + 1 }}</b>
            <span class="muted">{{ conn(id).name }}</span>
            <Menu :items="opts(r.key, conn(id))" cls="btn link sm" @pick="m => setModel(r.key, conn(id), m)">{{ cur(r.key, conn(id)) }} ▾</Menu>
            <template v-if="picked(r.key).length > 1"><button class="btn link sm" v-if="i > 0" @click="up(r.key, i)">←</button><button class="btn link sm" @click="remove(r.key, id)">✕</button></template>
          </span>
          <Menu v-if="S.data.connections.some(c => !picked(r.key).includes(c.id))" :items="S.data.connections.filter(c => !picked(r.key).includes(c.id)).map(c => [c.id, '备用：' + c.name])" label="＋" @pick="id => addTo(r.key, id)"/>
        </div></div>
    </div>
  </div>`,
}

// ---------- 写作设置 ----------
const Writing = {
  components: { Switch },
  computed: { S: () => S, au() { return S.data.auto } },
  watch: { au: { deep: true, handler() { Store.save() } } },
  template: `<div class="page narrow">
    <div class="ph"><div><h1>写作</h1><p>一键成稿怎么写。</p></div></div>
    <div class="card">
      <div class="setrow"><div class="lb"><b>文章字数</b><span>公众号长文大约写多少字</span></div><input class="field" type="number" step="100" min="600" max="4000" v-model.number="au.targetWords" style="width:120px"></div>
      <div class="setrow"><div class="lb"><b>审稿及格线</b><span>低于这个分数自动返修</span></div><input class="field" type="number" min="50" max="95" v-model.number="au.passScore" style="width:120px"></div>
      <div class="setrow"><div class="lb"><b>最多返修几轮</b><span>最后用分数最高的一版</span></div><input class="field" type="number" min="0" max="4" v-model.number="au.maxRounds" style="width:120px"></div>
      <div class="setrow"><div class="lb"><b>写完顺带出其他平台版本</b><span>按「我的账号」里的平台出</span></div><Switch v-model="au.variants"/></div>
    </div>
  </div>`,
}

// ---------- 外框 ----------
const GROUPS = [
  { key: 'work', name: '工作台', ic: '▦', tabs: [['工作台', 'workbench']] },
  { key: 'arts', name: '稿件', ic: '▤', tabs: [['全部稿件', 'library']] },
  { key: 'acc', name: '我的账号', ic: '☺', tabs: [['账号', 'accounts'], ['风格', 'styles']] },
  { key: 'set', name: '设置', ic: '⚙', tabs: [['模型', 'models'], ['写作', 'writing']] },
]

const App = {
  components: { Workbench, Library, Editor, Accounts, Styles, Models, Writing },
  data: () => ({ pane: 'workbench', editing: null }),
  computed: {
    S: () => S,
    group() { return GROUPS.find(g => g.tabs.some(t => t[1] === this.pane)) || GROUPS[0] },
    recent() { return S.data.articles.slice(0, 6) },
  },
  methods: {
    open(id) { this.editing = id },
    go(g) { this.editing = null; this.pane = g.tabs[0][1] },
  },
  async mounted() {
    await Store.load()
    const env = await api.env()
    if (env.demo && !S.data.articles.length) demo()
    if (!S.data.connections.length && !env.shots) this.pane = 'models'
    if (env.shots) {
      for (const p of env.shots.split(',')) {
        if (p === 'editor') { this.editing = (S.data.articles.find(x => x.primary === 'wechat') || S.data.articles[0])?.id } else { this.editing = null; this.pane = p }
        await nextTick(); await new Promise(r => setTimeout(r, 900))
        await api.shot(p)
      }
      api.shotDone()
    }
  },
  template: `<template v-if="S.loaded">
    <aside class="side">
      <div class="brand"><div class="logo">稿</div><div><b>公众号写稿助手</b><small>AI 起草 · 你来定稿</small></div></div>
      <div v-for="g in GROUPS" class="nav" :class="{on: !editing && group.key === g.key}" @click="go(g)"><span class="ic">{{ g.ic }}</span>{{ g.name }}</div>
      <div class="recent-h" v-if="recent.length">最近</div>
      <div class="recent" v-for="a in recent" @click="open(a.id)">▫ {{ a.title || a.topic || '未命名' }}</div>
      <div class="foot">{{ S.data.connections.length ? '已接 ' + S.data.connections.length + ' 个模型' : '还没接模型' }}</div>
    </aside>
    <main class="main">
      <Editor v-if="editing" :id="editing" @back="editing = null"/>
      <template v-else>
        <div class="tabs" v-if="group.tabs.length > 1"><div v-for="t in group.tabs" class="tab" :class="{on: pane === t[1]}" @click="pane = t[1]">{{ t[0] }}</div></div>
        <Workbench v-if="pane === 'workbench'" @open="open"/>
        <Library v-if="pane === 'library'" @open="open"/>
        <Accounts v-if="pane === 'accounts'"/>
        <Styles v-if="pane === 'styles'"/>
        <Models v-if="pane === 'models'"/>
        <Writing v-if="pane === 'writing'"/>
      </template>
    </main>
    <div class="toast" v-if="S.toast">{{ S.toast }}</div>
  </template>`,
}

// CI 截图用的示例数据
function demo() {
  S.data.connections = [{ id: uid(), name: '智谱 GLM', baseURL: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-4-flash' }]
  const st = S.data.styles[0]; st.name = '考公小助手'; st.track = '公务员考试备考'
  S.data.accounts = [
    { id: uid(), platform: 'wechat', name: '考公小助手', styleId: st.id, appId: '' },
    { id: uid(), platform: 'toutiao', name: '考公小助手', styleId: st.id, appId: '' },
    { id: uid(), platform: 'xiaohongshu', name: '上岸学姐', styleId: st.id, appId: '' },
  ]
  const titles = ['在职备考公务员，每天两小时怎么安排', '申论大作文，开头三句话定生死', '行测刷题十年，我只信这三个方法']
  titles.forEach((t, i) => {
    const a = Store.newArticle({ title: t, topic: t, stage: 'layout', styleId: st.id, accountId: S.data.accounts[0].id,
      outline: ['先说结论：节奏比时长重要', '早上一小时：行测'], kind: 'guide',
      sections: [{ heading: '先说结论：节奏比时长重要', body: '备考最怕的不是时间少，而是**没有节奏**。\n\n> 每天两小时，坚持四个月，比周末突击强得多。\n\n很多在职考生一开始雄心勃勃，三周后就断了。' },
        { heading: '早上一小时：行测', body: '早上脑子最清楚，留给行测。数量关系和资料分析各 30 分钟，计时做题。' }],
      review: { total: 86 - i * 4, summary: '结构清楚，例子再具体一点更好', scores: { 标题: 85, 可读性: 88, 实用性: 84, 合规: 95, 人味: 80 }, suggestions: [{ section: 2, issue: '方法偏泛', fix: '加一个具体时间表' }], factChecks: [], titles: [] },
      created: new Date(Date.now() - i * 20 * 3600e3).toISOString() })
    a.variants.toutiao = { title: '在职考公每天只有两小时？这样安排最省力', intro: '每天下班只剩两小时，还能考上吗？', tags: ['考公', '在职备考'], body: '' }
  })
  Store.newArticle({ primary: 'xiaohongshu', topic: '上岸学姐的申论笔记本', title: '上岸学姐的申论笔记本', stage: 'layout', accountId: S.data.accounts[2].id,
    variants: { xiaohongshu: { title: '上岸学姐的申论笔记本', intro: '', tags: ['考公', '申论'], body: '三个月从 52 到 71 分，我只做了这几件事……' } } })
  Store.save()
}

const app = createApp(App)
app.config.globalProperties.P = P
app.config.globalProperties.PLATFORMS = PLATFORMS
app.config.globalProperties.PRESETS = PRESETS
app.config.globalProperties.ROLES = ROLES
app.config.globalProperties.GROUPS = GROUPS
app.config.globalProperties.Layout = Layout
app.config.globalProperties.Store = Store
app.config.globalProperties.Pipeline = Pipeline
app.mount('#app')
