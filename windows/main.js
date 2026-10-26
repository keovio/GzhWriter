// 公众号写稿助手 Windows 版：主进程
// 负责：存数据、存密钥（系统加密）、调模型接口、剪贴板、各账号独立登录的网页窗口
const { app, BrowserWindow, ipcMain, clipboard, safeStorage, shell, Menu } = require('electron')
const path = require('path')
const fs = require('fs')

const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
const dir = () => app.getPath('userData')
const dataFile = () => path.join(dir(), 'data.json')
const secretFile = () => path.join(dir(), 'secrets.json')
let win = null

// ---------- 数据 ----------
ipcMain.handle('data:load', () => {
  try { return fs.readFileSync(dataFile(), 'utf8') } catch { return '' }
})
ipcMain.handle('data:save', (_e, json) => {
  fs.mkdirSync(dir(), { recursive: true })
  const f = dataFile()
  if (fs.existsSync(f)) { try { fs.copyFileSync(f, f + '.bak') } catch {} }
  fs.writeFileSync(f + '.tmp', json)
  fs.renameSync(f + '.tmp', f)
  return true
})

// ---------- 密钥：系统加密后存本机 ----------
function loadSecrets() {
  try { return JSON.parse(fs.readFileSync(secretFile(), 'utf8')) } catch { return {} }
}
function getSecret(k) {
  const v = loadSecrets()[k]
  if (!v) return ''
  try {
    return safeStorage.isEncryptionAvailable() ? safeStorage.decryptString(Buffer.from(v, 'base64')) : Buffer.from(v, 'base64').toString('utf8')
  } catch { return '' }
}
function setSecret(k, v) {
  const all = loadSecrets()
  if (!v) delete all[k]
  else all[k] = (safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(v) : Buffer.from(v, 'utf8')).toString('base64')
  fs.mkdirSync(dir(), { recursive: true })
  fs.writeFileSync(secretFile(), JSON.stringify(all))
}
ipcMain.handle('secret:get', (_e, k) => getSecret(k))
ipcMain.handle('secret:set', (_e, k, v) => { setSecret(k, v); return true })

// ---------- 模型：OpenAI 兼容接口 ----------
function endpoint(base, p) {
  let b = (base || '').trim().replace(/\/+$/, '')
  if (b.endsWith('/chat/completions')) b = b.slice(0, -'/chat/completions'.length)
  if (!/^https?:\/\//.test(b)) throw new Error('接口地址不对：' + base)
  return b + p
}
function stripThinking(s) { return s.replace(/<think>[\s\S]*?<\/think>/g, '').trim() }

ipcMain.handle('llm:chat', async (_e, { connId, name, baseURL, model, messages, temperature }) => {
  const key = getSecret('conn.' + connId)
  if (!key) return { error: `「${name}」还没填 API Key。`, fatal: true }
  try {
    const ctl = new AbortController()
    const timer = setTimeout(() => ctl.abort(), 180000)
    const r = await fetch(endpoint(baseURL, '/chat/completions'), {
      method: 'POST', signal: ctl.signal,
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + key },
      body: JSON.stringify({ model, messages, temperature: temperature ?? 0.7, stream: false }),
    })
    clearTimeout(timer)
    const text = await r.text()
    if (!r.ok) return { error: `接口返回 ${r.status}：${text.slice(0, 300)}`, status: r.status }
    const obj = JSON.parse(text)
    const c = obj?.choices?.[0]?.message?.content || ''
    if (!c.trim()) return { error: '模型没有返回内容。' }
    return { content: stripThinking(c) }
  } catch (err) {
    return { error: err.name === 'AbortError' ? '模型超时没有回应。' : String(err.message || err) }
  }
})

ipcMain.handle('llm:models', async (_e, { connId, baseURL }) => {
  const key = getSecret('conn.' + connId)
  try {
    const r = await fetch(endpoint(baseURL, '/models'), { headers: { Authorization: 'Bearer ' + key } })
    if (!r.ok) return []
    const obj = await r.json()
    return (obj.data || []).map(m => m.id).filter(Boolean).sort()
  } catch { return [] }
})

// ---------- 剪贴板 ----------
ipcMain.handle('clip:html', (_e, html, text) => { clipboard.write({ html, text }); return true })
ipcMain.handle('clip:text', (_e, text) => { clipboard.writeText(text); return true })
ipcMain.handle('open:url', (_e, u) => shell.openExternal(u))

// ---------- 各账号独立登录：每个账号一个持久分区 ----------
const PUBLISH = {
  wechat: 'https://mp.weixin.qq.com',
  toutiao: 'https://mp.toutiao.com/profile_v4/graphic/publish',
  baijiahao: 'https://baijiahao.baidu.com/builder/rc/edit?type=news',
  zhihu: 'https://zhuanlan.zhihu.com/write',
  xiaohongshu: 'https://creator.xiaohongshu.com/publish/publish?target=image',
  weibo: 'https://weibo.com',
}
const NAMES = { wechat: '公众号', toutiao: '头条号', baijiahao: '百家号', zhihu: '知乎', xiaohongshu: '小红书', weibo: '微博' }

function accountWindow(acc, title) {
  const w = new BrowserWindow({
    width: 1200, height: 860, title,
    autoHideMenuBar: true,
    webPreferences: { partition: 'persist:acc-' + acc.id, contextIsolation: true },
  })
  w.webContents.setUserAgent(UA)
  w.on('page-title-updated', e => e.preventDefault())
  w.webContents.setWindowOpenHandler(({ url }) => { w.loadURL(url); return { action: 'deny' } })
  return w
}

ipcMain.handle('acc:login', (_e, acc) => {
  const w = accountWindow(acc, `登录${NAMES[acc.platform] || ''}「${acc.name}」（登录后直接关掉这个窗口）`)
  w.loadURL(PUBLISH[acc.platform] || 'about:blank')
  return true
})

// 打开发文页，找到标题框和正文编辑区填进去。只填不发
function fillScript(T, H, P) {
  return `(function(T, H, P) {
    function setVal(el, v) {
      var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
      if (d && d.set) d.set.call(el, v); else el.value = v;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    function docs() {
      var out = [document];
      document.querySelectorAll('iframe').forEach(function(f) { try { if (f.contentDocument) out.push(f.contentDocument); } catch (e) {} });
      return out;
    }
    var title = null, body = null, bodyDoc = null, area = 0;
    docs().forEach(function(d) {
      if (!title) {
        var fs = Array.prototype.slice.call(d.querySelectorAll('textarea, input'));
        title = fs.find(function(e) { return /标题/.test(e.placeholder || ''); }) || null;
      }
      Array.prototype.slice.call(d.querySelectorAll('[contenteditable="true"], .ProseMirror')).forEach(function(e) {
        if (e === title) return;
        var ph = e.getAttribute('placeholder') || e.getAttribute('data-placeholder') || '';
        if (/标题/.test(ph) && !title) { title = e; return; }
        var r = e.getBoundingClientRect(), s = r.width * Math.max(r.height, 60);
        if (s > area) { area = s; body = e; bodyDoc = d; }
      });
      if (!body && d.body && d.body.isContentEditable) { body = d.body; bodyDoc = d; }
    });
    if (!body || (!title && T)) return 'wait';
    if (title && T) {
      if (title.tagName === 'TEXTAREA' || title.tagName === 'INPUT') setVal(title, T);
      else { title.focus(); title.textContent = T; title.dispatchEvent(new InputEvent('input', { bubbles: true })); }
    }
    body.focus();
    var done = false;
    try {
      var dt = new DataTransfer(); dt.setData('text/html', H); dt.setData('text/plain', P);
      var ev = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
      body.dispatchEvent(ev); done = ev.defaultPrevented;
    } catch (e) {}
    if (!done) { try { done = bodyDoc.execCommand('insertHTML', false, H); } catch (e) {} }
    if (!done) { body.innerHTML = H; body.dispatchEvent(new InputEvent('input', { bubbles: true })); }
    return 'ok';
  })(${JSON.stringify(T)}, ${JSON.stringify(H)}, ${JSON.stringify(P)})`
}

ipcMain.handle('acc:fill', (_e, { acc, title, html, plain }) => {
  const w = accountWindow(acc, `${NAMES[acc.platform]}「${acc.name}」· ${title || ''}（填好后检查一下，发布你自己点）`)
  w.loadURL(PUBLISH[acc.platform])
  let tries = 0
  const timer = setInterval(async () => {
    if (w.isDestroyed()) return clearInterval(timer)
    if (++tries > 90) return clearInterval(timer)
    try {
      const r = await w.webContents.executeJavaScript(fillScript(title, html, plain), true)
      if (r === 'ok') { clearInterval(timer); w.setTitle(`${NAMES[acc.platform]}「${acc.name}」· 已填好，检查后自己点发布`) }
    } catch {}
  }, 2000)
  return true
})

// ---------- CI 截图 ----------
ipcMain.handle('env', () => ({ demo: !!process.env.GZH_DEMO, shots: process.env.GZH_SHOTS || '' }))
ipcMain.handle('shot:take', async (_e, name) => {
  const img = await win.webContents.capturePage()
  const out = path.join(process.cwd(), 'shots')
  fs.mkdirSync(out, { recursive: true })
  fs.writeFileSync(path.join(out, name + '.png'), img.toPNG())
  return true
})
ipcMain.handle('shot:done', () => app.quit())

// ---------- 窗口 ----------
function createWindow() {
  win = new BrowserWindow({
    width: 1320, height: 860, minWidth: 1100, minHeight: 700,
    title: '公众号写稿助手',
    backgroundColor: '#F2F4FB',
    autoHideMenuBar: true,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
  })
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'))
  if (process.env.GZH_SHOTS) win.setBounds({ x: 0, y: 0, width: 1320, height: 860 })
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' } })
}

if (process.env.GZH_DEMO) app.setPath('userData', path.join(app.getPath('temp'), 'gzh-demo'))
Menu.setApplicationMenu(null)
app.whenReady().then(createWindow)
app.on('window-all-closed', () => app.quit())
