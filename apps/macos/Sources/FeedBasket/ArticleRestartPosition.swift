import WebKit

@MainActor
enum ArticleRestartPosition {
    static func capture(in view: WKWebView) async -> RestartSnapshot.ArticlePosition? {
        do {
            let result = try await view.callAsyncJavaScript(ArticleSelection.textIndex + captureScript,
                arguments: [:], in: nil, contentWorld: .defaultClient)
            guard let result = result as? [String: Any] else { return nil }
            let data = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(RestartSnapshot.ArticlePosition.self, from: data)
        } catch {
            return nil
        }
    }

    static func restore(_ position: RestartSnapshot.ArticlePosition, in view: WKWebView) {
        var arguments: [String: Any] = ["scrollY": position.scrollY, "anchor": NSNull()]
        if let anchor = position.anchor {
            arguments["anchor"] = ["index": anchor.index, "context": anchor.context,
                                   "before": anchor.before, "top": anchor.top]
        }
        view.callAsyncJavaScript(ArticleSelection.textIndex + restoreScript, arguments: arguments,
                                 in: nil, in: .defaultClient, completionHandler: nil)
    }

    private static let captureScript = """
        const scrollY = window.scrollY;
        const viewport = article.getBoundingClientRect();
        const left = Math.max(0, Math.ceil(viewport.left));
        const right = Math.min(window.innerWidth, Math.floor(viewport.right));
        const range = document.createRange();
        for (let y = 1; y < Math.min(160, window.innerHeight); y += 4) {
            for (let x = left + 12; x < right; x += 20) {
                const hit = document.caretRangeFromPoint(x, y);
                if (!hit || hit.startContainer.nodeType !== Node.TEXT_NODE) continue;
                const node = hit.startContainer;
                const offset = Math.min(hit.startOffset, node.length - 1);
                if (offset < 0) continue;
                range.setStart(node, offset);
                range.setEnd(node, offset + 1);
                const rect = range.getBoundingClientRect();
                if (rect.width <= 0 || rect.top > y || rect.bottom < y || rect.left > x + 20 || rect.right < x - 20) continue;
                const entry = nodes.find(entry => entry.node === node);
                if (!entry) continue;
                const index = entry.start + offset;
                let start = Math.max(0, index - 36);
                let end = Math.min(text.length, index + 36);
                const first = text.charCodeAt(start);
                const after = text.charCodeAt(end);
                if (start > 0 && first >= 0xDC00 && first <= 0xDFFF) start--;
                if (end < text.length && after >= 0xDC00 && after <= 0xDFFF) end++;
                const context = text.slice(start, end);
                return { scrollY, anchor: { index, context, before: index - start, top: rect.top } };
            }
        }
        return { scrollY };
        """

    private static let restoreScript = """
        let y = scrollY;
        if (anchor?.context) {
            let index = -1;
            let closest = Infinity;
            for (let start = text.indexOf(anchor.context); start !== -1; start = text.indexOf(anchor.context, start + 1)) {
                const candidate = start + anchor.before;
                const distance = Math.abs(candidate - anchor.index);
                if (distance < closest) { index = candidate; closest = distance; }
                if (!distance) break;
            }
            const entry = nodes.find(entry => entry.start <= index && index < entry.end);
            if (entry) {
                const offset = index - entry.start;
                const range = document.createRange();
                range.setStart(entry.node, offset);
                range.setEnd(entry.node, offset + 1);
                y = window.scrollY + range.getBoundingClientRect().top - anchor.top;
            }
        }
        window.scrollTo(0, y);
        """
}
