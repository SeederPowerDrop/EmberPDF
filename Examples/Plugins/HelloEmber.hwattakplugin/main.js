// SPDX-License-Identifier: MIT
let count = 0;

async function renderPanel() {
  await ember.ui.render({
    title: 'Hello Ember',
    text: `Ideas recorded in this window: ${count}`,
    actions: [
      { id: 'add-idea', label: 'Record an idea' },
      { id: 'close', label: 'Close panel' }
    ]
  });
}

ember.commands.register({
  id: 'open-hello',
  title: 'Hello Ember',
  run: async () => {
    await renderPanel();
    await ember.ui.open();
  }
});

ember.on('view.action', async ({ id }) => {
  if (id === 'add-idea') {
    count += 1;
    await renderPanel();
  } else if (id === 'close') {
    await ember.ui.close();
  }
});
