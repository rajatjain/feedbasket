enum ReaderCodeBlock {
    static let copyHandler = "copyArticleCode"

    static func css(style: BasketStyle) -> String {
        let fill = style.scheme == .dark
            ? "color-mix(in srgb, " + style.css(style.readingSurface) + " 78%, #000)"
            : "#f3f5f7"
        return """
        article pre {
            overflow-x: auto; text-align: left; white-space: pre-wrap; overflow-wrap: anywhere;
            font: 0.85em/1.5 ui-monospace, Menlo, monospace; tab-size: 4;
        }
        article pre code { font: inherit; }
        article .reader-code {
            margin: 1.25em 0; padding: 8px 12px 12px; max-width: 100%; box-sizing: border-box;
            background: \(fill); border: 1px solid color-mix(in srgb, currentColor 25%, transparent);
            border-radius: \(BasketTokens.radius)px;
        }
        article .reader-code pre { margin: 5px 0 0; }
        article .reader-code pre[data-unwrapped] { white-space: pre; overflow-wrap: normal; }
        .reader-code-actions { display: flex; justify-content: flex-end; gap: 5px; }
        .reader-code-actions button {
            display: grid; place-items: center; width: 26px; height: 24px; padding: 0;
            color: inherit; background: transparent; cursor: pointer;
            border: 1px solid color-mix(in srgb, currentColor 25%, transparent); border-radius: 5px;
        }
        .reader-code-actions button:hover, .reader-code-actions button[aria-pressed="true"] {
            background: color-mix(in srgb, currentColor 10%, transparent);
        }
        .reader-code-actions button:focus-visible { outline: 2px solid \(style.css(style.accentPair)); }
        .reader-code-actions button svg { width: 14px; height: 14px; }
        """
    }

    static let script = """
    (() => {
        const svgNS = 'http://www.w3.org/2000/svg';
        const copyIcon = 'M7 7h7v7H7z M10 4V2H2v8h2';
        const wrapIcon = 'M2 3h12 M2 7h10a2 2 0 0 1 0 4H7 m2-2-2 2 2 2 M2 11h2';
        const checkIcon = 'm3 8 3 3 7-7';

        function button(label, icon) {
            const control = document.createElement('button');
            control.type = 'button';
            control.title = label;
            control.setAttribute('aria-label', label);
            const svg = document.createElementNS(svgNS, 'svg');
            svg.setAttribute('viewBox', '0 0 16 16');
            svg.setAttribute('aria-hidden', 'true');
            svg.setAttribute('fill', 'none');
            svg.setAttribute('stroke', 'currentColor');
            svg.setAttribute('stroke-width', '1.25');
            svg.setAttribute('stroke-linecap', 'round');
            svg.setAttribute('stroke-linejoin', 'round');
            const path = document.createElementNS(svgNS, 'path');
            path.setAttribute('d', icon);
            svg.append(path);
            control.append(svg);
            return { control, path };
        }

        for (const pre of document.querySelectorAll('article pre')) {
            // Some publishers use <br> inside a snippet in place of a newline.
            const source = pre.cloneNode(true);
            for (const br of source.querySelectorAll('br')) br.replaceWith('\\n');
            const code = source.textContent;
            if (!code.trim()) continue;

            const panel = document.createElement('div');
            const actions = document.createElement('div');
            panel.className = 'reader-code';
            actions.className = 'reader-code-actions';

            const { control: wrap } = button('Wrap lines', wrapIcon);
            wrap.setAttribute('aria-pressed', 'true');
            wrap.addEventListener('click', () => {
                const unwrapped = pre.toggleAttribute('data-unwrapped');
                wrap.setAttribute('aria-pressed', String(!unwrapped));
                if (!unwrapped) pre.scrollLeft = 0;
            });

            const { control: copy, path } = button('Copy code', copyIcon);
            let feedback;
            copy.addEventListener('click', () => {
                window.webkit.messageHandlers.\(copyHandler).postMessage(code);
                path.setAttribute('d', checkIcon);
                copy.title = 'Copied';
                copy.setAttribute('aria-label', 'Code copied');
                clearTimeout(feedback);
                feedback = setTimeout(() => {
                    path.setAttribute('d', copyIcon);
                    copy.title = 'Copy code';
                    copy.setAttribute('aria-label', 'Copy code');
                }, 1200);
            });

            // Icon-only controls keep the existing article text offsets intact.
            actions.append(wrap, copy);
            pre.before(panel);
            panel.append(actions, pre);
        }
    })();
    """
}
