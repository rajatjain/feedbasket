enum ReaderTable {
    static func css(style: BasketStyle) -> String {
        let line = style.css(BasketTokens.line)
        return """
        article .reader-table {
            max-width: 100%; box-sizing: border-box; margin: 1.25em 0;
            overflow-x: auto; border: 1px solid \(line);
            border-radius: \(BasketTokens.radius)px;
        }
        article .reader-table:focus-visible {
            outline: 2px solid \(style.css(style.accentPair)); outline-offset: 2px;
        }
        article .reader-table table {
            width: 100%; border-collapse: collapse; text-align: left;
            font-size: 0.92em; line-height: 1.45;
        }
        article .reader-table :is(th, td) {
            box-sizing: border-box; min-width: 8em; padding: 0.55em 0.75em;
            text-align: left; vertical-align: top; border-bottom: 1px solid \(line);
        }
        article .reader-table thead, article .reader-table th {
            background: \(style.css(BasketTokens.subtle));
        }
        article .reader-table tr:last-child > :is(th, td) { border-bottom: 0; }
        article .reader-table :is(th, td) > :first-child { margin-block-start: 0; }
        article .reader-table :is(th, td) > :last-child { margin-block-end: 0; }
        """
    }

    static let script = """
    (() => {
        for (const table of document.querySelectorAll('article table')) {
            if (table.parentElement.closest('table, .reader-table')) continue;
            const viewport = document.createElement('div');
            viewport.className = 'reader-table';
            table.before(viewport);
            viewport.append(table);

            const update = () => {
                if (viewport.scrollWidth > viewport.clientWidth) {
                    viewport.tabIndex = 0;
                    viewport.setAttribute('role', 'region');
                    viewport.setAttribute('aria-label', 'Scrollable table');
                } else {
                    viewport.removeAttribute('tabindex');
                    viewport.removeAttribute('role');
                    viewport.removeAttribute('aria-label');
                }
            };
            const observer = new ResizeObserver(update);
            observer.observe(viewport);
            observer.observe(table);
            update();
        }
    })();
    """
}
