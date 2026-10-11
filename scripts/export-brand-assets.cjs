#!/usr/bin/env node
// Export the approved geometry without changing its paths. Requires sharp.
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const sharp = require('sharp');

const root = path.resolve(__dirname, '..');
const brand = path.join(root, 'assets/brand');
const source = path.join(brand, 'iphone-use-final');
const sha256 = data => crypto.createHash('sha256').update(data).digest('hex');

// ICO directory entries point to PNG images (including the 256 px entry).
function ico(images) {
  const header = Buffer.alloc(6 + images.length * 16);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(images.length, 4);
  let offset = header.length;
  images.forEach(({size, data}, index) => {
    const entry = 6 + index * 16;
    header[entry] = header[entry + 1] = size === 256 ? 0 : size;
    header.writeUInt16LE(1, entry + 4);
    header.writeUInt16LE(32, entry + 6);
    header.writeUInt32LE(data.length, entry + 8);
    header.writeUInt32LE(offset, entry + 12);
    offset += data.length;
  });
  return Buffer.concat([header, ...images.map(image => image.data)]);
}

async function main() {
  const files = [];
  async function save(name, data, metadata) {
    await fs.writeFile(path.join(brand, name), data);
    files.push({path: name, bytes: data.length, sha256: sha256(data), ...metadata});
  }
  for (const [input, output, viewBox] of [
    ['mark.svg', 'iphone-use-mark.svg', [0, 0, 160, 160]],
    ['inverse.svg', 'iphone-use-mark-dark.svg', [0, 0, 160, 160]],
    ['wordmark.svg', 'iphone-use-wordmark.svg', [0, 0, 350, 112]],
    ['wordmark-inverse.svg', 'iphone-use-wordmark-dark.svg', [0, 0, 350, 112]],
  ]) {
    await save(output, await fs.readFile(path.join(source, input)), {format: 'SVG', viewBox});
  }
  async function png(input, size, opaque = false) {
    let pipeline = sharp(input, {density: 288}).resize({width: size});
    if (opaque) pipeline = pipeline.flatten({background: '#FFFFFF'}).removeAlpha();
    return pipeline.png().toBuffer();
  }
  const mark = await fs.readFile(path.join(source, 'mark.svg'));
  for (const size of [1024, 256]) {
    await save(size === 1024 ? 'iphone-use-mark.png' : 'iphone-use-mark-256.png',
      await png(mark, size), {format: 'PNG', dimensions: [size, size], mode: 'RGBA'});
  }
  for (const [input, output] of [
    ['wordmark.svg', 'iphone-use-wordmark.png'],
    ['wordmark-inverse.svg', 'iphone-use-wordmark-dark.png'],
  ]) {
    await save(output, await png(await fs.readFile(path.join(source, input)), 1400),
      {format: 'PNG', dimensions: [1400, 448], mode: 'RGBA'});
  }
  const appIcon = await png(mark, 1024, true);
  await save('iphone-use-app-icon.png', appIcon,
    {format: 'PNG', dimensions: [1024, 1024], mode: 'RGB'});
  const runnerIcon = 'Runner/Assets.xcassets/AppIcon.appiconset/AppIcon.png';
  await fs.writeFile(path.join(root, runnerIcon), appIcon);

  // Tighter square framing keeps the 16 px gesture continuous. Geometry is
  // unchanged, with 10 units of top/bottom clear space (master: 18 units).
  const faviconSVG = mark.toString().replace('viewBox="0 0 160 160"', 'viewBox="8 8 144 144"');
  if (faviconSVG === mark.toString()) throw new Error('Unexpected master viewBox');
  const icons = [];
  for (const size of [16, 32, 48, 64, 256]) {
    const data = await png(Buffer.from(faviconSVG), size, true);
    icons.push({size, data});
    if (size !== 256) await save(`favicon-${size}.png`, data,
      {format: 'PNG', dimensions: [size, size], mode: 'RGB'});
  }
  await save('favicon.ico', ico(icons), {
    format: 'ICO', dimensions: [256, 256], mode: 'RGB',
    embedded_sizes: icons.map(({size}) => [size, size]),
  });
  await fs.mkdir(path.join(brand, 'licenses'), {recursive: true});
  await save('licenses/geist-OFL.txt', await fs.readFile(path.join(source, 'reference/geist-OFL.txt')),
    {format: 'text'});
  const manifest = {
    brand: 'iphone-use', direction: 'Phone silhouette + continuous swipe', date: '2026-10-11',
    formats: ['SVG', 'PNG', 'ICO'],
    provenance: {
      approved_design: 'iphone-use-final/',
      generator: 'scripts/export-brand-assets.cjs',
      rasterizer: {sharp: sharp.versions.sharp, librsvg: sharp.versions.rsvg, density: 288},
      wordmark: {font: 'Geist', weight: 500, license: 'licenses/geist-OFL.txt', outlines: true},
      favicon: {viewBox: [8, 8, 144, 144], note: 'Same approved path; tighter framing only.'},
    },
    app_icon: {path: runnerIcon, source: 'iphone-use-app-icon.png', sha256: sha256(appIcon)},
    files,
  };
  await fs.writeFile(path.join(brand, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  console.log(`Exported ${files.length} brand assets and the Runner App Icon.`);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
