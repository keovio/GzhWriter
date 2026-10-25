import AppKit
import Foundation

/// 把稿件排成公众号能直接粘贴的 HTML（全部用行内样式，公众号编辑器会保留）
enum Layout {
    struct Template: Identifiable { let id: String; let name: String }
    static let templates: [Template] = [
        .init(id: "magazine", name: "杂志卡片"),
        .init(id: "plain", name: "纯文字"),
        .init(id: "highlight", name: "重点高亮"),
        .init(id: "minimal", name: "极简留白"),
    ]
    static let accents: [(String, String)] = [
        ("#3F68A8", "雾蓝"), ("#2F7D5B", "墨绿"), ("#B4532A", "砖红"),
        ("#7A5BA6", "藕紫"), ("#C48A1C", "琥珀"), ("#333333", "墨黑"),
    ]

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// **加粗** → 强调色加粗；【待核实：…】→ 黄底提醒（复制前记得删掉）
    static func inline(_ s: String, accent: String) -> String {
        var t = esc(s)
        t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#,
                                   with: "<strong style=\"color:\(accent);font-weight:bold;\">$1</strong>",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: #"【待核实[:：]?(.*?)】"#,
                                   with: "<span style=\"background:#FFF3B0;color:#8A6200;\">【待核实：$1】</span>",
                                   options: .regularExpression)
        return t
    }

    static func paragraphs(_ body: String) -> [String] {
        body.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func html(_ a: Article) -> String {
        let ac = a.accent
        let fs = a.fontSize
        let p = "margin:0 0 1.2em;font-size:\(fs)px;line-height:1.9;letter-spacing:0.5px;color:#3a3a3a;text-align:justify;"
        let quote = "margin:0 0 1.2em;padding:12px 16px;border-left:3px solid \(ac);background:#F6F7FA;color:#555;font-size:\(fs - 1)px;line-height:1.8;"

        func heading(_ i: Int, _ text: String) -> String {
            let h = inline(text, accent: ac)
            switch a.template {
            case "plain":
                return "<h3 style=\"margin:2em 0 1em;font-size:\(fs + 2)px;font-weight:bold;color:#222;\">\(h)</h3>"
            case "highlight":
                return "<h3 style=\"margin:2em 0 1em;text-align:center;\"><span style=\"display:inline-block;padding:4px 14px;background:\(ac);color:#fff;border-radius:4px;font-size:\(fs + 1)px;font-weight:bold;\">\(h)</span></h3>"
            case "minimal":
                return "<h3 style=\"margin:2.4em 0 1.2em;text-align:center;font-size:\(fs + 1)px;font-weight:normal;letter-spacing:2px;color:#222;\"><span style=\"color:\(ac);\">— \(String(format: "%02d", i + 1)) —</span><br>\(h)</h3>"
            default: // magazine
                return "<h3 style=\"margin:2em 0 1em;padding-left:10px;border-left:4px solid \(ac);font-size:\(fs + 2)px;font-weight:bold;color:#222;line-height:1.5;\"><span style=\"color:\(ac);margin-right:6px;\">\(String(format: "%02d", i + 1))</span>\(h)</h3>"
            }
        }

        var out = "<section style=\"padding:0 4px;font-family:-apple-system,BlinkMacSystemFont,'PingFang SC','Helvetica Neue',sans-serif;\">"
        for (i, sec) in a.sections.enumerated() {
            if !sec.heading.isEmpty { out += heading(i, sec.heading) }
            var block = ""
            for line in paragraphs(sec.body) {
                if line.hasPrefix(">") {
                    let q = line.drop(while: { $0 == ">" || $0 == " " })
                    block += "<blockquote style=\"\(quote)\">\(inline(String(q), accent: ac))</blockquote>"
                } else {
                    block += "<p style=\"\(p)\">\(inline(line, accent: ac))</p>"
                }
            }
            if a.template == "magazine" {
                out += "<section style=\"margin:0 0 1.5em;padding:18px 16px 2px;background:#FAFBFD;border-radius:8px;box-shadow:0 1px 4px rgba(0,0,0,0.06);\">\(block)</section>"
            } else {
                out += block
            }
        }
        if a.aiNotice {
            out += "<p style=\"margin:2em 0 0;font-size:12px;color:#999;text-align:center;\">本文由作者在 AI 辅助下完成，观点与内容经作者审定。</p>"
        }
        out += "</section>"
        return out
    }

    /// 预览页：模拟手机宽度
    static func previewPage(_ a: Article) -> String {
        let title = a.title.isEmpty ? "" :
            "<h1 style=\"font-size:22px;line-height:1.4;margin:0 0 14px;color:#111;\">\(esc(a.title))</h1>"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0;background:#EDEFF3;} .phone{max-width:375px;margin:16px auto;background:#fff;padding:22px 16px 40px;border-radius:12px;box-shadow:0 2px 12px rgba(0,0,0,.08);}</style>
        </head><body><div class="phone">\(title)\(html(a))</div></body></html>
        """
    }

    /// 复制为富文本，直接粘到公众号编辑器
    static func copyRichText(_ a: Article) {
        let body = html(a)
        let pb = NSPasteboard.general
        pb.clearContents()
        let full = "<html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
        if let data = full.data(using: .utf8),
           let attr = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
           let rtf = attr.rtf(from: NSRange(location: 0, length: attr.length), documentAttributes: [:]) {
            pb.setData(rtf, forType: .rtf)
        }
        pb.setString(body, forType: .html)
        pb.setString(plain(a), forType: .string)
    }

    static func plain(_ a: Article) -> String {
        var s = a.title.isEmpty ? "" : a.title + "\n\n"
        for sec in a.sections {
            s += sec.heading + "\n\n" + sec.body.replacingOccurrences(of: "**", with: "") + "\n\n"
        }
        return s
    }

    static func copyMarkdown(_ a: Article) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(a.plainText, forType: .string)
    }
}
