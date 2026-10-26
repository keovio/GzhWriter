// 提示词：和 Mac 版一致。作者是真人，AI 只起草和提建议，不编造事实。
const sys = (c) => ({ role: 'system', content: c })
const usr = (c) => ({ role: 'user', content: c })

const PLATFORMS = [
  { key: 'wechat', name: '公众号', color: '#1AAD19', how: '官方接口存进草稿箱，你在后台点发表', rule: '' },
  { key: 'toutiao', name: '头条号', color: '#F04142', long: true, fill: true, how: '打开发文页自动填好标题正文，你点发布',
    rule: '头条号：标题 20 到 30 字，口语、有具体信息或数字；开头一段两三句直接抛出读者关心的问题；标签 3 到 5 个。' },
  { key: 'baijiahao', name: '百家号', color: '#2B63F0', long: true, fill: true, how: '打开发文页自动填好标题正文，你点发布',
    rule: '百家号：标题规范克制，不夸张不标题党，不用感叹号和问号连用；开头一段交代清楚这篇讲什么；标签 3 到 5 个。' },
  { key: 'zhihu', name: '知乎', color: '#0066FF', long: true, fill: true, how: '打开发文页自动填好标题正文，你点发布',
    rule: '知乎：标题像一个问题或一句明确的判断；开头一段先给结论，再说「下面展开」，少情绪多干货；标签 3 到 5 个话题。' },
  { key: 'xiaohongshu', name: '小红书', color: '#FF2442', short: true, fill: true, how: '打开发布页填好文字，图片你传，你点发布',
    rule: '小红书笔记：标题 20 字以内，带一个关键词和一点情绪；正文 300 到 600 字，口语、分点短句、每段一两句，可以用少量表情符号；结尾一句互动提问；标签 5 到 8 个。' },
  { key: 'weibo', name: '微博', color: '#E6162D', short: true, how: '一键复制，打开微博粘贴发布',
    rule: '微博：正文 140 到 300 字，一个清楚的观点加一两个支撑细节，口语；话题标签 2 到 3 个。不需要标题。' },
]
const P = Object.fromEntries(PLATFORMS.map(p => [p.key, p]))

const KINDS = {
  auto: { name: '自动挑', outline: '', write: '', headings: true },
  guide: { name: '干货清单', outline: '干货清单文：4 到 6 部分，每部分一个具体方法或要点，小标题直接说方法。', write: '这是干货清单文，讲清楚方法和步骤，最好带一个具体例子。', headings: true },
  story: { name: '故事叙事', outline: '故事叙事文：4 到 5 个情节段（起因、经过、转折、结果、感悟），小标题只是给作者看的段落提示，不会出现在文中。', write: '这是故事叙事文，用场景、细节和对话推进，和前文自然衔接，不要写成分点说明。', headings: false },
  opinion: { name: '观点评论', outline: '观点评论文：3 到 5 部分，第一部分亮明观点，中间部分是理由或对反方的回应，最后一部分回到观点并给读者建议。', write: '这是观点评论文，立场鲜明，论证具体，可以正面回应不同意见。', headings: true },
  news: { name: '热点解读', outline: '热点解读文：4 部分左右，依次是发生了什么、为什么重要、对读者有什么影响、读者该怎么做。', write: '这是热点解读文，事实部分克制准确，不确定的写【待核实】，重点讲对读者的影响。', headings: true },
  review: { name: '经验复盘', outline: '经验复盘文：4 到 5 部分，依次是背景和目标、做法、踩过的坑、结果和数据、可以复用的结论。经历和数据只用作者提供的，缺的写【待核实】。', write: '这是经验复盘文，用第一人称，具体到做了什么、结果如何。', headings: true },
}

const Prompts = {
  base: `你是一位资深的微信公众号编辑，正在协助一位真人作者写作。
规则：
1. 作者的观点、经历和取舍优先，你负责把它们写清楚、写好读，不替作者编造经历。
2. 不编造数据、案例、引用、政策条文；需要具体数字或出处时，写成【待核实：说明】占位，让作者自己补。
3. 语言自然口语化，少用"首先/其次/综上所述/在当今社会"这类套话，不用 emoji 堆砌。
4. 去 AI 味：不用「最」「第一」「唯一」「稳赚」「包过」等绝对化和承诺性用语，不写「点赞、在看、转发」之类的诱导语；不用「不是……而是……」「值得一提的是」「总而言之」「让我们」「赋能」「抓手」这类句式和黑话；不用破折号；结尾不拔高、不喊口号；多用具体场景和短句。
5. 严格按要求的格式输出，不要多余解释。`,

  platformRules: `所有平台版本都不能出现「公众号」「关注我」「点击在看」「微信」「加我」等站外引导。
不使用「不是……而是……」句式，不用破折号，不编造原文没有的数据和经历。只输出 JSON。`,

  profile(s) {
    if (!s) return ''
    let t = ''
    if (s.track) t += `公众号赛道：${s.track}\n`
    if (s.audience) t += `读者：${s.audience}\n`
    if (s.avoid) t += `不写的话题：${s.avoid}\n`
    return t
  },

  styleBlock(s) {
    if (!s || !(s.sample || '').trim()) return ''
    return `\n【作者范文，模仿它的口吻、句子长短和用词习惯，不要照抄内容】\n${s.sample.slice(0, 3000)}\n`
  },

  pickTopic(direction, style, existing, avoidSimilar = []) {
    return [sys(this.base), usr(`${this.profile(style)}
${direction ? '作者想写的方向：' + direction : '作者没有指定方向，请按赛道和读者自己挑。'}
${existing.length ? '已经写过的选题（不要重复，也不要换个说法写同一件事）：' + existing.slice(0, 80).join('；') : ''}
${avoidSimilar.length ? '你刚才挑的「' + avoidSimilar.join('」「') + '」和写过的太像了，这次换一个不同的点。' : ''}

挑 1 个最值得写的选题，给出切入角度，并写一段这篇文章要表达的核心观点（3 到 5 句，立场鲜明、具体，像作者本人会说的话）。
只输出 JSON：{"topic":"选题","angle":"切入角度","viewpoint":"核心观点"}`)]
  },

  kindBlock(a) {
    const k = KINDS[a.kind] || KINDS.auto
    if (a.kind && a.kind !== 'auto') return `文章类型：${k.name}。${k.outline}`
    const list = Object.entries(KINDS).filter(([key]) => key !== 'auto').map(([key, v]) => `· ${key}（${v.name}）：${v.outline}`).join('\n')
    return `先按选题和作者观点，从下面的文章类型里挑最合适的一种，按它的结构出大纲（作者没给真实经历时不要选 review）：\n${list}`
  },

  outline(a, style) {
    return [sys(this.base), usr(`选题：${a.topic}
作者的观点 / 想说的话：${a.viewpoint || ''}
${a.material ? '参考素材（只作参考，不要改写搬运）：\n' + a.material.slice(0, 5000) : ''}
${this.profile(style)}

${this.kindBlock(a)}
围绕作者的观点出一份公众号文章大纲，每部分一行，格式「小标题：这部分要讲的要点」。
再给一个不标题党的文章标题。
只输出 JSON：{"title":"文章标题","kind":"${!a.kind || a.kind === 'auto' ? '所选类型英文代号' : a.kind}","outline":["小标题：要点", "..."]}`)]
  },

  section(a, i, style, words = 400) {
    const all = a.outline.map((o, n) => `${n + 1}. ${o}`).join('\n')
    const done = a.sections.slice(0, i).map(s => `· ${s.heading}：${s.body.slice(0, 80)}…`).join('\n')
    return [sys(this.base + this.styleBlock(style)), usr(`文章标题：${a.title}
作者的观点：${a.viewpoint || ''}
${a.material ? '参考素材（只作参考）：\n' + a.material.slice(0, 3000) : ''}

完整大纲：
${all}

${done ? '前面已经写好的部分（保持衔接，不要重复）：\n' + done + '\n' : ''}
现在只写第 ${i + 1} 部分：${a.outline[i]}
${(KINDS[a.kind] || KINDS.auto).write}

要求：${Math.max(200, words - 80)} 到 ${words + 120} 字；段落之间空一行；每段不超过 4 行；可以用 **加粗** 标出一两句关键句，可以用「> 」开头写一句引用。
不要写小标题，只输出这部分的正文。`)]
  },

  revise(a, i, instruction, style) {
    const s = a.sections[i]
    return [sys(this.base + this.styleBlock(style)), usr(`文章标题：${a.title}
这部分的小标题：${s.heading}
这部分原文：
${s.body}

修改要求：${instruction}
格式同原文（段落之间空一行，可用 **加粗** 和「> 」引用）。只输出改好的这部分正文，不要小标题。`)]
  },

  review(text) {
    return [sys(this.base), usr(`请审阅下面这篇公众号文章，像一位严格但友善的主编。

${text.slice(0, 12000)}

按五个维度打分（0-100）：标题、可读性、实用性、合规、人味（是否像真人在表达观点，而不是 AI 套话）。
合规要看：夸大承诺、绝对化用语、医疗/金融等敏感建议、未核实的数据、诱导关注分享。
给出最多 8 条具体修改建议，每条注明是第几部分（全文性问题 section 填 null），说清问题和改法。
列出文中需要作者核实的事实、数字、引用、政策。
再给 3 个备选标题。
只输出 JSON：
{"scores":{"标题":0,"可读性":0,"实用性":0,"合规":0,"人味":0},"total":0,"summary":"一句话总评",
 "suggestions":[{"section":1,"issue":"问题","fix":"改法"}],
 "factChecks":["需要核实的内容"],"titles":["备选标题1","备选标题2","备选标题3"]}`)]
  },

  longVariants(a, plain, targets) {
    const rules = targets.map(k => P[k].rule).join('\n')
    const shape = targets.map(k => `"${k}":{"title":"","intro":"","tags":[""]}`).join(',')
    const first = (a.sections[0]?.body || '').split('\n').map(x => x.trim()).filter(Boolean)[0] || ''
    return [sys(`你帮作者把一篇公众号文章改成其他长文平台的版本。正文主体不变，只改标题、开头一段和标签。
${rules}
${this.platformRules}`), usr(`原标题：${a.title}
原开头：${first}
全文：
${plain.slice(0, 3500)}

输出 JSON：{"digest":"公众号摘要，40 字内"${shape ? ',' + shape : ''}}`)]
  },

  shortVariants(a, plain, targets) {
    const rules = targets.map(k => P[k].rule).join('\n')
    const shape = targets.map(k => k === 'weibo' ? '"weibo":{"body":"","tags":[""]}' : `"${k}":{"title":"","body":"","tags":[""]}`).join(',')
    return [sys(`你帮作者把一篇公众号长文改写成短内容平台的版本。保留原文的核心观点和最有用的一两个细节，按平台习惯重写，不要缩写成摘要腔。
${rules}
正文段落之间空一行；标签不带 # 号。
${this.platformRules}`), usr(`原标题：${a.title}
全文：
${plain.slice(0, 4000)}

输出 JSON：{${shape}}`)]
  },

  short(a, key, style) {
    const shape = key === 'weibo' ? '{"body":"","tags":[""]}' : '{"title":"","body":"","tags":[""]}'
    return [sys(`你帮作者写一篇${P[key].name}内容，作者会自己改完再手动发。
${P[key].rule}
正文段落之间空一行；标签不带 # 号。
写作者本人的观点和经验口吻，具体、有信息量，不说空话套话，不编造数据和作者没提供的亲身经历。
${this.platformRules}
${this.styleBlock(style)}`), usr(`${this.profile(style)}
选题：${a.topic}
${a.viewpoint ? '作者观点：' + a.viewpoint : ''}
${a.material || ''}

输出 JSON：${shape}`)]
  },
}
