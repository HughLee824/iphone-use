const path = require('node:path');
const sharp = require('sharp');
const root = process.argv[2] || __dirname;
async function main() {
  for (const name of ['mark', 'inverse', 'wordmark', 'wordmark-inverse', 'preview', 'construction']) {
    const width = name.includes('wordmark') ? 1400 : name === 'preview' ? 1400 : name === 'construction' ? 1500 : 1024;
    await sharp(path.join(root, `${name}.svg`), {density: 300}).resize({width}).png().toFile(path.join(root, `${name}.png`));
  }
  const samples = [];
  for (let i = 0; i < 4; i++) {
    const size = [16,24,32,48][i];
    const file = path.join(root, `mark-${size}.png`);
    await sharp(path.join(root, 'mark.svg'), {density: 300}).resize(size, size).png().toFile(file);
    samples.push({input: await sharp(file).resize(size*8, size*8, {kernel: 'nearest'}).toBuffer(), left: 30+i*400, top: 30});
  }
  await sharp({create: {width: 1640, height: 450, channels: 4, background: '#E0EAE2'}}).composite(samples).png().toFile(path.join(root, 'size-check.png'));
  await sharp(path.join(root, 'mark.svg'), {density: 300}).resize(64,64).png().toFile(path.join(root, 'mark-64.png'));
  console.log('Rendered previews, transparent masters and size checks.');
}
main().catch(e => { console.error(e); process.exitCode = 1; });
