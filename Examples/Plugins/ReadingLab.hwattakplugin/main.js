// SPDX-License-Identifier: MIT
// All logic below belongs to this plugin, not to the EmberPDF application.
let saved = { visits: 0 };
let current = null;
async function refresh() {
  const info = await ember.call('document.getInfo');
  const page = await ember.call('document.getPageText');
  const words = page.text.toLocaleLowerCase().match(/[\p{L}\p{N}]{3,}/gu) || [];
  const counts = new Map();
  for (const word of words) counts.set(word, (counts.get(word) || 0) + 1);
  const top = [...counts].sort((a, b) => b[1] - a[1]).slice(0, 8);
  current = { info, top, count: words.length };
  await ember.ui.render({
    title: 'Reading Lab · 독서 실험실',
    text: `${info.name}\n${info.pageNumber} / ${info.pageCount} · ${words.length} words${page.truncated ? ' (partial)' : ''}\nA community plugin computes these results using the public API.`,
    items: top.map(([title, count]) => ({ title, detail: `${count} occurrences` })),
    fields: [{ id: 'thought', label: 'A thought about this page · 떠오른 생각', value: '' }],
    actions: [{ id: 'save-thought', label: 'Add to note · 노트에 추가' }, { id: 'refresh', label: 'Refresh · 새로고침' }]
  });
}
ember.on('load', async () => {
  const data = await ember.call('storage.get');
  saved = data.value && typeof data.value.visits === 'number' ? data.value : { visits: 0 };
  saved.visits++;
  await ember.call('storage.set', { value: saved });
  ember.commands.register({ id: 'refresh', title: 'Analyze current page · 현재 페이지 분석', run: refresh });
  await refresh();
});
ember.on('page.changed', refresh);
ember.on('view.action', async ({ id, values }) => {
  if (id === 'refresh') return refresh();
  if (id === 'save-thought' && current && values.thought.trim()) {
    const text = `## Page ${current.info.pageNumber}\n\n${values.thought.trim()}\n\nKeywords: ${current.top.map(([word]) => word).join(', ')}`;
    await ember.call('notes.append', { text });
    await ember.ui.render({ title: 'Saved to this PDF’s note · 노트에 추가했어요', text: 'Open Markdown Notebook to continue writing. · Markdown 노트에서 이어서 작성하세요.',
      actions: [{id: 'refresh', label: 'Continue reading · 계속 읽기'}] });
  }
});
