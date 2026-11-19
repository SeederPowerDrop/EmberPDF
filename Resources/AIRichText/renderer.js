// SPDX-License-Identifier: MPL-2.0
(() => {
    'use strict';
    const root = document.getElementById('response');
    const escape = value => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
    let images = [], labels = {}, generation = 0, lastHeight = 0;
    const imageCache = new Map();
    const post = message => window.webkit?.messageHandlers?.richText?.postMessage(message);
    const reportHeight = () => {
        const height = Math.ceil(root.getBoundingClientRect().height);
        if (height !== lastHeight) { lastHeight = height; post({kind: 'height', height}); }
    };
    const publicImage = value => {
        try {
            const url = new URL(value);
            return url.protocol === 'https:' && !url.username && !url.password && (!url.port || url.port === '443');
        } catch { return false; }
    };
    const makeImageMarkup = (source, alt) => {
        if (images.length >= 8) return `<span class="image-info">${escape(labels.unavailable)}</span>`;
        const index = images.length;
        images.push({source: String(source), alt: String(alt || '')});
        return `<span class="image-card" data-image-index="${index}"></span>`;
    };
    const imageCard = index => root.querySelector(`[data-image-index="${index}"]`);
    const showImage = (index, dataURL) => {
        const card = imageCard(index), descriptor = images[index];
        if (!card || !descriptor) return;
        card.replaceChildren();
        const image = document.createElement('img');
        image.alt = descriptor.alt;
        image.src = dataURL;
        image.addEventListener('load', reportHeight);
        image.addEventListener('error', () => { card.textContent = labels.failed; reportHeight(); });
        card.append(image);
        if (descriptor.alt) {
            const caption = document.createElement('span');
            caption.className = 'image-info'; caption.textContent = descriptor.alt; card.append(caption);
        }
        reportHeight();
    };
    const prepareImage = index => {
        const descriptor = images[index], card = imageCard(index);
        if (!card) return;
        const cached = imageCache.get(descriptor.source);
        if (cached) { showImage(index, cached); return; }
        if (/^data:image\/(png|jpeg|webp|gif);base64,/i.test(descriptor.source)) {
            card.textContent = labels.loading;
            post({kind: 'image', index, generation, source: descriptor.source, embedded: true});
            return;
        }
        if (!publicImage(descriptor.source)) { card.textContent = labels.unavailable; return; }
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = labels.load;
        const host = new URL(descriptor.source).hostname;
        button.title = host;
        button.addEventListener('click', () => {
            button.disabled = true; button.textContent = labels.loading;
            post({kind: 'image', index, generation, source: descriptor.source, embedded: false});
        });
        card.append(button);
        const info = document.createElement('span'); info.className = 'image-info';
        info.textContent = [descriptor.alt, host].filter(Boolean).join(' · '); card.append(info);
    };
    const render = payload => {
        generation += 1; images = []; labels = payload.labels || {};
        // One view belongs to one answer. Keep cache only for source URLs
        // that still appear in its current content; no unbounded accumulation.
        imageCache.clear();
        const equationMap = new Map((payload.equations || []).map(item => [item.token, item]));
        const restoreMath = (value, field) => String(value || '').replace(/EMBERMATH[A-F0-9]{32}X\d+X/g, token => equationMap.get(token)?.[field] || token);
        const parser = new marked.Marked({gfm: true, breaks: true});
        parser.use({renderer: {
            // Provider-supplied HTML is displayed literally; only Markdown
            // creates markup. Sanitization below is an independent boundary.
            html: token => escape(token.text),
            image: token => makeImageMarkup(restoreMath(token.href, 'source'), restoreMath(token.text, 'expression')),
            link(token) {
                return `<a href="${escape(restoreMath(token.href, 'source'))}">${this.parser.parseInline(token.tokens)}</a>`;
            }
        }});
        parser.use({extensions: [{
            name: 'emberMath', level: 'inline',
            start(source) { return source.indexOf('EMBERMATH'); },
            tokenizer(source) {
                const match = /^EMBERMATH[A-F0-9]{32}X\d+X/.exec(source);
                if (match && equationMap.has(match[0])) return {type: 'emberMath', raw: match[0], token: match[0]};
            },
            renderer(token) { return `<span data-equation="${escape(token.token)}"></span>`; }
        }]});
        const html = parser.parse(String(payload.markdown || ''));
        root.innerHTML = DOMPurify.sanitize(html, {
            ALLOWED_TAGS: ['p','br','h1','h2','h3','h4','h5','h6','strong','b','em','i','del','s','ul','ol','li','blockquote','pre','code','hr','table','thead','tbody','tr','th','td','a','span','input'],
            ALLOWED_ATTR: ['href','title','start','align','class','type','checked','disabled','data-equation','data-image-index'],
            // These two app-generated identifiers are not URLs. Without this
            // explicit classification the strict URL regexp also strips them.
            ADD_URI_SAFE_ATTR: ['data-equation','data-image-index'],
            ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: false,
            ALLOWED_URI_REGEXP: /^(?:https?:\/\/|#)/i
        });
        for (const element of root.querySelectorAll('[data-equation]')) {
            const equation = equationMap.get(element.dataset.equation);
            if (!equation) continue;
            element.className = equation.display ? 'math-display' : 'math-inline';
            try {
                katex.render(equation.expression, element, {displayMode: equation.display, output: 'htmlAndMathml', throwOnError: true, trust: false, strict: 'ignore', maxSize: 20, maxExpand: 500});
            } catch {
                element.classList.add('math-error'); element.textContent = equation.expression;
            }
        }
        for (const table of root.querySelectorAll('table')) {
            const wrapper = document.createElement('div'); wrapper.className = 'table-scroll';
            table.replaceWith(wrapper); wrapper.append(table);
        }
        for (const descriptor of payload.images || []) {
            const holder = document.createElement('div'); holder.innerHTML = makeImageMarkup(descriptor.source, descriptor.alt); root.append(...holder.childNodes);
        }
        images.forEach((_, index) => prepareImage(index));
        for (const anchor of root.querySelectorAll('a')) {
            anchor.addEventListener('click', event => { event.preventDefault(); post({kind: 'link', url: anchor.getAttribute('href')}); });
        }
        reportHeight(); document.fonts.ready.then(reportHeight);
    };
    window.EmberRichText = {
        render,
        setTheme(theme) { for (const key of ['text','secondary','accent','surface','border']) root.style.setProperty(`--${key}`, theme[key]); },
        acceptImage(index, expectedGeneration, dataURL) {
            if (generation !== expectedGeneration || !images[index]) return;
            if (!dataURL) { const card = imageCard(index); if (card) card.textContent = labels.failed; reportHeight(); return; }
            imageCache.set(images[index].source, dataURL); showImage(index, dataURL);
        }
    };
    new ResizeObserver(reportHeight).observe(root);
    post({kind: 'ready'});
})();
