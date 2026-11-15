// Builds PROJECT_REPORT_V2.pdf from PROJECT_REPORT_V2.md, with the Mermaid diagrams drawn
// and the screenshots embedded. Run with: npm run report:pdf
// Needs Google Chrome and an internet connection (the Markdown and Mermaid renderers load from a CDN).
import { readFileSync } from 'node:fs';
import { dirname, extname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from '@playwright/test';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const source = process.argv[2] ?? 'PROJECT_REPORT_V2.md';
const target = source.replace(/\.md$/, '.pdf');
const repo = 'https://github.com/Gurkirat164/college-admission-management-system/blob/main/';
const markdown = readFileSync(resolve(root, source), 'utf8');

// Local images become data URIs so the page does not depend on file paths.
const images = {};
for (const [, path] of markdown.matchAll(/!\[[^\]]*\]\(([^)\s]+)\)/g)) {
  if (/^https?:/.test(path)) continue;
  const type = extname(path) === '.png' ? 'image/png' : 'image/jpeg';
  images[path] = `data:${type};base64,${readFileSync(resolve(root, path)).toString('base64')}`;
}

const style = `
  @page { size: A4; margin: 18mm 16mm; }
  * { box-sizing: border-box; }
  body { font: 10.5pt/1.5 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; color: #111; margin: 0; }
  h1 { font-size: 22pt; margin: 0 0 2pt; }
  h1 + h2 { font-size: 13pt; font-weight: 500; color: #555; margin: 0 0 14pt; border: 0; padding: 0; }
  h2 { font-size: 14.5pt; margin: 22pt 0 6pt; padding-bottom: 3pt; border-bottom: 1px solid #ccc; }
  h3 { font-size: 11.5pt; margin: 14pt 0 4pt; }
  h2, h3 { break-after: avoid; }
  p, li { orphans: 3; widows: 3; }
  a { color: #0b4a8f; text-decoration: none; }
  table { border-collapse: collapse; width: 100%; margin: 8pt 0; font-size: 9.5pt; }
  th, td { border: 1px solid #c8c8c8; padding: 4pt 6pt; text-align: left; vertical-align: top; }
  th { background: #f1f1f1; }
  tr, pre, img, .mermaid { break-inside: avoid; }
  code { font: 9pt Menlo, Consolas, monospace; background: #f3f3f3; padding: 0 2pt; border-radius: 2pt; }
  pre { background: #f6f6f6; border: 1px solid #ddd; padding: 8pt; border-radius: 3pt; white-space: pre-wrap; }
  pre code { background: none; padding: 0; font-size: 8.5pt; }
  img { display: block; max-width: 100%; max-height: 215mm; margin: 6pt auto; border: 1px solid #ccc; }
  .mermaid { text-align: center; margin: 6pt 0 10pt; }
  .mermaid svg { max-width: 100%; max-height: 190mm; height: auto; }
  .caption { break-after: avoid; margin-bottom: 2pt; }
`;

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage();
await page.setContent(`<!doctype html><html><head><meta charset="utf-8"><style>${style}</style></head><body><main></main></body></html>`);
await page.addScriptTag({ url: 'https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js' });
await page.addScriptTag({ url: 'https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js' });
await page.evaluate(
  async ({ markdown, images, repo }) => {
    const main = document.querySelector('main');
    main.innerHTML = marked.parse(markdown);
    for (const img of main.querySelectorAll('img')) {
      const src = img.getAttribute('src');
      if (images[src]) img.src = images[src];
    }
    // Relative links point at files in the repository, so send PDF readers to GitHub.
    for (const a of main.querySelectorAll('a')) {
      const href = a.getAttribute('href');
      if (!/^(https?:|#|mailto:)/.test(href)) a.href = repo + href;
    }
    for (const p of main.querySelectorAll('p')) {
      if (/^(Figure|Screen) \d+\./.test(p.textContent)) p.className = 'caption';
    }
    for (const code of main.querySelectorAll('code.language-mermaid')) {
      const div = document.createElement('div');
      div.className = 'mermaid';
      div.textContent = code.textContent;
      code.parentElement.replaceWith(div);
    }
    mermaid.initialize({ startOnLoad: false, theme: 'neutral', securityLevel: 'loose' });
    await mermaid.run({ querySelector: '.mermaid' });
    await Promise.all([...document.images].map((i) => i.decode().catch(() => {})));
  },
  { markdown, images, repo },
);
const drawn = await page.locator('.mermaid svg').count();
const expected = (markdown.match(/```mermaid/g) ?? []).length;
if (drawn !== expected) throw new Error(`Only ${drawn} of ${expected} diagrams were drawn`);
await page.pdf({ path: resolve(root, target), format: 'A4', printBackground: true, preferCSSPageSize: true });
await browser.close();
console.log(`${target}: ${drawn} diagrams, ${Object.keys(images).length} screenshots`);
