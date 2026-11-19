// SPDX-License-Identifier: MIT
// This extension's behavior is entirely developer-owned. EmberPDF supplies
// scoped events, metadata, commands, persistence and a native view surface.
let visits = [];
let lastKey = null;
let queue = Promise.resolve();
let status = '';

function sequential(operation) {
  queue = queue.then(operation).catch(error => {
    // A tab/page change can invalidate an in-flight native call. The next
    // context event will record the new page without stopping this extension.
    if (error && error.code === 'CONTEXT_CHANGED') return;
    throw error;
  });
  return queue;
}

function sanitized(value) {
  return Array.isArray(value) ? value.filter(item =>
    item && typeof item.name === 'string' && item.name.length <= 256 &&
    Number.isInteger(item.pageNumber) && item.pageNumber > 0 &&
    typeof item.visitedAt === 'string' && item.visitedAt.length <= 32
  ).slice(0, 50) : [];
}

async function refreshSavedVisits() {
  const saved = await ember.call('storage.get');
  visits = sanitized(saved.value);
}

async function updateVisits(transform) {
  // Other app windows share this plugin's storage. Conditional replacement is
  // atomic in the host; a conflict re-reads instead of overwriting their visits.
  for (let attempt = 0; attempt < 8; attempt++) {
    const saved = await ember.call('storage.get');
    const replacement = transform(sanitized(saved.value));
    const result = await ember.call('storage.compareAndSet', {
      expected: saved.value, value: replacement
    });
    if (result.saved) {
      visits = replacement;
      status = '';
      return true;
    }
  }
  await refreshSavedVisits();
  status = 'Another window is updating the trail. Please retry. · 다른 창에서 기록을 갱신하고 있어요. 다시 시도해 주세요.';
  return false;
}

async function render() {
  await ember.ui.render({
    title: 'Research Trail · 읽기 여정',
    text: (visits.length
      ? 'A developer extension remembers the pages you visit. Close this panel and keep reading; its command stays available.\n패널을 닫고 다른 문서를 읽어도 기록과 명령이 이어집니다.'
      : 'Open a PDF and move between pages to start your trail.\nPDF를 열고 페이지를 넘기면 읽기 여정이 쌓입니다.') + (status ? `\n\n${status}` : ''),
    items: visits.map(visit => ({
      title: `${visit.name} · p. ${visit.pageNumber}`,
      detail: visit.visitedAt
    })),
    actions: [
      { id: 'retry', label: 'Refresh trail · 기록 새로고침' },
      { id: 'clear', label: 'Clear trail · 기록 지우기' },
      { id: 'close', label: 'Keep reading · 계속 읽기' }
    ]
  });
}

async function recordCurrentPage() {
  const context = await ember.call('app.getContext');
  if (!context.hasDocument) {
    lastKey = null;
    await refreshSavedVisits();
    return render();
  }
  const info = await ember.call('document.getInfo');
  const latest = await ember.call('app.getContext');
  if (latest.tabID !== context.tabID || latest.workspaceID !== context.workspaceID) return;
  const key = `${context.workspaceID}/${context.tabID}/${info.pageNumber}`;
  if (key !== lastKey) {
    // Keep the visit itself stable across retries; retrying must not fabricate
    // a later visit time or duplicate the same successful write.
    const visit = { name: info.name, pageNumber: info.pageNumber, visitedAt: new Date().toISOString() };
    if (await updateVisits(current => [visit, ...current].slice(0, 50))) lastKey = key;
  } else await refreshSavedVisits();
  await render();
}

ember.commands.register({
  id: 'show-trail',
  title: 'Show reading trail · 읽기 여정 보기',
  run: () => sequential(async () => {
    await refreshSavedVisits();
    await render();
    await ember.ui.open();
  })
});

for (const event of ['app.ready', 'document.changed', 'page.changed']) {
  ember.on(event, () => sequential(recordCurrentPage));
}

ember.on('view.action', ({ id }) => sequential(async () => {
  if (id === 'clear') {
    if (await updateVisits(() => [])) lastKey = null;
    await render();
  }
  if (id === 'retry') await recordCurrentPage();
  if (id === 'close') await ember.ui.close();
}));

// Cleanup is best-effort; the host authoritatively removes commands and handlers.
ember.dispose(() => { visits = []; lastKey = null; });
