const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const probe = fs.readFileSync(path.join(__dirname, '../Resources/PlanProbe.js'), 'utf8');

function runProbe(buttons, dialogs = []) {
  return vm.runInNewContext(probe, {
    innerHeight: 800,
    location: { pathname: '/', hash: '' },
    document: {
      body: { innerText: '' },
      querySelectorAll(selector) {
        return selector === '[role=dialog]' ? dialogs : buttons;
      },
    },
  });
}

function button(label, top = 740) {
  return {
    innerText: label,
    getAttribute() { return label; },
    getBoundingClientRect() { return { left: 12, top, width: 230, height: 42 }; },
  };
}

test('reads the signed-in profile plan shown in the sidebar footer', () => {
  const result = runProbe([button('bucktooth 免费版，打开“个人资料”菜单')]);
  assert.match(result.profile, /免费版/);
  assert.equal(result.details, '');
});

test('ignores upgrade offers and content outside the profile footer', () => {
  const result = runProbe([button('升级到 Plus'), button('Plus', 50)]);
  assert.equal(result.profile, '');
});

test('keeps subscription details separate from the profile label', () => {
  const dialog = { innerText: 'Current plan\nChatGPT Pro\nExpires on October 30, 2026', getClientRects() { return [1]; } };
  const result = runProbe([button('bucktooth Pro，打开个人资料菜单')], [dialog]);
  assert.match(result.profile, /Pro/);
  assert.match(result.details, /Expires on/);
});
