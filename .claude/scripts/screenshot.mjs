#!/usr/bin/env node
// Fidelity-gate screenshot capture for the `ui` skill.
//
//   node .claude/scripts/screenshot.mjs <url> <out.png> [--width 1280]
//        [--height 800] [--selector "#app"] [--wait "text=Loaded"] [--full]
//
// Requires Playwright:  npx playwright install chromium
// Deterministic by construction: fixed viewport, animations disabled, fonts
// settled before capture. A screenshot that moves between runs cannot be
// diffed against a mockup.
//
// If Playwright is not available in this project, do not improvise a capture —
// say so in your report. The `ui` skill lists the other accepted proof paths.

import { chromium } from 'playwright';

const [, , url, out, ...rest] = process.argv;
if (!url || !out) {
  console.error('usage: screenshot.mjs <url> <out.png> [--width N] [--height N] [--selector S] [--wait S] [--full]');
  process.exit(2);
}

const flag = (name, fallback) => {
  const i = rest.indexOf(`--${name}`);
  return i === -1 ? fallback : rest[i + 1];
};
const has = (name) => rest.includes(`--${name}`);

const browser = await chromium.launch();
try {
  const page = await browser.newPage({
    viewport: { width: Number(flag('width', 1280)), height: Number(flag('height', 800)) },
    deviceScaleFactor: 2,
  });

  // Kill motion: a mid-transition capture is a false fidelity failure.
  await page.addStyleTag({
    content: `*, *::before, *::after {
      animation: none !important;
      transition: none !important;
      caret-color: transparent !important;
    }`,
  }).catch(() => {});

  await page.goto(url, { waitUntil: 'networkidle' });

  const wait = flag('wait', null);
  if (wait) await page.locator(wait).first().waitFor({ state: 'visible', timeout: 15000 });

  await page.evaluate(() => document.fonts?.ready);

  const selector = flag('selector', null);
  const target = selector ? page.locator(selector).first() : page;
  await target.screenshot({ path: out, fullPage: !selector && has('full') });

  console.log(`screenshot: ${out}`);
} finally {
  await browser.close();
}
