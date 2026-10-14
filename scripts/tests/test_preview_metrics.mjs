import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../Sources/IPhoneUseCore/NativePreviewPage.swift', import.meta.url), 'utf8');
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];

const catalog=JSON.parse(readFileSync(new URL('../../assets/preview/catalog.json',import.meta.url),'utf8'));

function fixture(productType='iPhone13,3', navigator={language:'zh-CN'}, appearanceComparisonEnabled=true) {
  let clock = 0;
  const elements = Object.fromEntries(['screen', 'state', 'diagnostics', 'metrics', 'device', 'stage', 'bezel', 'shell', 'hardware', 'cutout', 'speaker', 'device-name', 'connection', 'fullscreen', 'appearance-toggle', 'viewer', 'placeholder-label', 'diagnostics-label', 'identity', 'toolbar', 'chrome'].map(id => [id, { dataset: {}, style: { setProperty(name,value) { this[name]=value; } }, clientWidth: 1000, clientHeight: 700, getBoundingClientRect() { return {left:0,right:0,top:0,bottom:0}; }, events: {}, addEventListener(name, fn) { this.events[name]=fn; }, setAttribute(name,value) { this[name]=value; } }]));
  const document = { documentElement:{}, events:{}, visibilityState: 'visible', getElementById: id => elements[id], addEventListener: (name, fn) => { document.events[name]=fn;if(name==='visibilitychange')document.visibilityChanged = fn; } };
  let report;
  const context = vm.createContext({ document, navigator, URLSearchParams, location: { search: '?diagnostics=1' },
    ResizeObserver: class { observe() {} }, performance: { now: () => clock }, Date: { now: () => clock },
    requestAnimationFrame: fn => fn(), setInterval: fn => { report = fn; }, setTimeout() {},
    AbortSignal: { timeout() {} }, fetch: () => new Promise(() => {}) });
  vm.runInContext(script.replace('\\(appearanceComparisonEnabled ? "true" : "false")', String(appearanceComparisonEnabled)), context);
  const profile=catalog.models[productType]||null;
  vm.runInContext(`setDevice(${JSON.stringify({device:{productType,name:profile?.name||'Unknown iPhone'},bezel:profile})})`,context);
  return {
    elements, document,
    run(code) { return vm.runInContext(code,context); },
    layout(w, h, rotation='rot0') {
      elements.screen.naturalWidth=w;elements.screen.naturalHeight=h;
      vm.runInContext(`rotation=${JSON.stringify(rotation)};layout()`, context);
    },
    frame(at, sequence) { clock = at; vm.runInContext(`presented(${sequence}, 12, ${at - 2})`, context); },
    report(at) { clock = at; report(); return JSON.parse(elements.metrics.textContent); },
    visibility(value) { document.visibilityState = value; document.visibilityChanged(); },
  };
}

test('duplicate JPEGs do not inflate FPS and a terminal freeze remains visible', () => {
  const probe = fixture();
  probe.frame(0, 1); probe.frame(100, 1); probe.frame(200, 2); probe.frame(600, 3);
  const report = probe.report(1600);
  assert.equal(report.visibleNewFrames, 3);
  assert.equal(report.duplicates, 1);
  assert.equal(report.gapsOver250ms, 1);
  assert.equal(report.maxGapMs, 400);
  assert.equal(report.lastNewFrameAgeMs, 1000);
  assert.equal(report.fps, 2 * 1000 / 600);
});

test('background visibility resets the window instead of reporting browser throttling as a stall', () => {
  const probe = fixture(); probe.frame(0, 1);
  probe.visibility('hidden'); probe.frame(1000, 2);
  assert.equal(probe.report(1000).visibleNewFrames, 0);
  probe.visibility('visible'); probe.frame(2000, 3); probe.frame(2100, 4);
  assert.equal(probe.report(2200).fps, 10);
  assert.equal(probe.report(2200).maxGapMs, 100);
});

test('measurement storage is bounded during long runs', () => {
  const probe = fixture();
  for (let i = 0; i < 2000; i++) probe.frame(i * 100, i);
  const report = probe.report(200000);
  assert.equal(report.visibleNewFrames, 1800);
  assert.equal(report.total.frames, 2000);
  assert.equal(report.total.fps, 10);
});


test('slow-frame diagnostics remain bounded and retain stage timings', () => {
  const probe = fixture();
  for (let i = 0; i < 200; i++) probe.frame(i * 150, i);
  const report = probe.report(30000);
  assert.equal(report.total.slowFrames.length, 120);
  assert.equal(report.total.slowFrames.at(-1).gapMs, 150);
  assert.equal(report.total.slowFrames.at(-1).rafWaitMs, 0);
});


test('official bezel retains screen aperture and both landscape directions', () => {
  const probe=fixture();probe.layout(444,960);
  assert.equal(probe.elements.bezel.hidden,false);
  assert.equal(probe.elements.shell.hidden,true);
  assert.equal(probe.elements.bezel.src,'bezel');
  probe.layout(960,444,'rot270');
  assert.equal(probe.elements.bezel.style.transform,'translate(-50%,-50%) rotate(-90deg)');
  probe.layout(960,444,'rot90');
  assert.equal(probe.elements.bezel.style.transform,'translate(-50%,-50%) rotate(90deg)');
  probe.layout(768,1024);
  assert.equal(probe.elements.bezel.hidden,true);
  assert.equal(probe.elements.shell.hidden,false);
  assert.equal(probe.elements.cutout.hidden,true);
  assert.equal(probe.elements.device.dataset.appearance,'generic');
});

test('failed official asset uses independent drawing without another image request', () => {
  const probe=fixture();probe.layout(444,960);probe.elements.bezel.events.error();
  assert.equal(probe.elements.bezel.hidden,true);
  assert.equal(probe.elements.shell.hidden,false);
  assert.equal(probe.elements.device.dataset.appearance,'drawn');
  assert.equal(probe.elements.cutout.dataset.shape,'notch');
  assert.ok(parseFloat(probe.elements.screen.style.left)>0);
});

test('portrait and landscape fit a narrow viewport without stretching', () => {
  const probe=fixture();probe.elements.stage.clientWidth=360;probe.elements.stage.clientHeight=380;
  for (const [w,h] of [[444,960],[960,444]]) {
    probe.layout(w,h);
    assert.ok(parseFloat(probe.elements.device.style.width)<=320);
    assert.ok(parseFloat(probe.elements.device.style.height)<=348);
    const ratio=parseFloat(probe.elements.screen.style.width)/parseFloat(probe.elements.screen.style.height);
    assert.ok(Math.abs(ratio-w/h)<.002);
  }
});


test('unknown model never shows another model bezel even with identical frame dimensions', () => {
  const probe=fixture('iPhone99,1');probe.layout(444,960);
  assert.equal(probe.elements.bezel.hidden,true);
  assert.equal(probe.elements.bezel.src,undefined);
  assert.equal(probe.elements.shell.hidden,false);
  assert.equal(probe.elements.cutout.hidden,true);
  assert.equal(probe.elements.device.dataset.appearance,'generic');
  assert.equal(probe.elements['device-name'].textContent,'Unknown iPhone');
});

test('every catalog model keeps the screen aperture aligned through portrait and both landscape rotations', () => {
  for (const [productType,p] of Object.entries(catalog.models)) {
    const probe=fixture(productType);
    for (const rotation of ['rot0','rot90','rot270']) {
      const landscape=rotation!=='rot0';
      const w=landscape?p.screenHeight:p.screenWidth,h=landscape?p.screenWidth:p.screenHeight;
      probe.layout(w,h,rotation);
      const device=probe.elements.device.style,screen=probe.elements.screen.style;
      const scale=parseFloat(screen.width)/w;
      const expectedX=landscape?(rotation==='rot90'?p.canvasHeight-p.screenY-p.screenHeight:p.screenY):p.screenX;
      const expectedY=landscape?(rotation==='rot90'?p.screenX:p.canvasWidth-p.screenX-p.screenWidth):p.screenY;
      assert.ok(Math.abs(parseFloat(screen.left)/scale-expectedX)<.001,productType);
      assert.ok(Math.abs(parseFloat(screen.top)/scale-expectedY)<.001,productType);
      assert.ok(parseFloat(screen.left)+parseFloat(screen.width)<=parseFloat(device.width)+.001);
      assert.ok(parseFloat(screen.top)+parseFloat(screen.height)<=parseFloat(device.height)+.001);
      assert.equal(probe.elements.bezel.hidden,false);
    }
  }
});


test('all exact drawings rotate hardware but never rotate the live image', () => {
  const models=fixture().run('drawnModels');
  for(const [id,model] of Object.entries(models)) {
    const probe=fixture(id);
    if(catalog.models[id])probe.elements.bezel.events.error();
    for(const rotation of ['rot0','rot90','rot270','rot180']) {
      const landscape=rotation==='rot90'||rotation==='rot270';
      const w=landscape?model[2]:model[1],h=landscape?model[1]:model[2];
      probe.layout(w,h,rotation);
      assert.equal(probe.elements.device.dataset.appearance,'drawn',id);
      assert.equal(probe.elements.bezel.hidden,true);
      assert.equal(probe.elements.shell.hidden,false);
      assert.equal(probe.elements.hardware.style.transform,probe.elements.shell.style.transform);
      assert.equal(probe.elements.screen.style.transform,undefined);
      const s=probe.elements.screen.style,d=probe.elements.device.style;
      assert.ok(Math.abs(parseFloat(s.width)/parseFloat(s.height)-w/h)<1e-8);
      assert.ok(parseFloat(s.left)+parseFloat(s.width)<parseFloat(d.width));
      assert.ok(parseFloat(s.top)+parseFloat(s.height)<parseFloat(d.height));
    }
  }
});

test('exact productType distinguishes 17/18 variants without using names or loose keys', () => {
  for(const id of ['iphone18,1',' iPhone18,1','iPhone18,99','__proto__']) {
    const p=fixture(id);p.layout(1206,2622);
    assert.equal(p.elements.device.dataset.appearance,'generic');
    assert.equal(p.elements.bezel.src,undefined);
  }
  const first=fixture('iPhone18,1'),next=fixture('iPhone19,2');
  first.layout(1206,2622);next.layout(1206,2622);
  assert.notEqual(first.elements.cutout.style.width,next.elements.cutout.style.width);
  assert.equal(next.elements.bezel.src,undefined);
});

test('unchanged frames do not write decoration styles and plain controls are removed', () => {
  const probe=fixture('iPhone19,2');probe.layout(444,960);
  for(const id of ['device','screen','shell','hardware','cutout']) {
    probe.elements[id].style=new Proxy(probe.elements[id].style,{set(){throw Error('redundant layout write: '+id);}});
  }
  for(let i=0;i<1800;i++)probe.layout(444,960);
  assert.doesNotMatch(source,/id="(?:plain|framed)"|useBezel|class="segments"/);
});


test('temporary appearance comparison switches only decoration and survives rotation and health refresh', () => {
  const probe=fixture();probe.layout(444,960);
  const toggle=probe.elements['appearance-toggle'];
  assert.equal(toggle.hidden,false);
  probe.elements.screen.src='blob:unchanged-live-frame';
  toggle.events.click();
  assert.equal(probe.elements.device.dataset.appearance,'drawn');
  assert.equal(toggle.title,'切换官方外观');
  assert.equal(toggle['aria-label'],'切换官方外观');
  probe.layout(960,444,'rot90');
  probe.run(`setDevice(${JSON.stringify({device:{productType:'iPhone13,3'},bezel:catalog.models['iPhone13,3']})})`);
  assert.equal(probe.elements.device.dataset.appearance,'drawn');
  assert.equal(probe.elements.screen.src,'blob:unchanged-live-frame');
  toggle.events.click();
  assert.equal(probe.elements.device.dataset.appearance,'official');
  assert.equal(toggle.title,'切换自绘外观');
  assert.equal(toggle['aria-label'],'切换自绘外观');
  assert.equal(probe.elements.bezel.style.transform,'translate(-50%,-50%) rotate(90deg)');
  probe.elements.bezel.events.error();
  assert.equal(toggle.hidden,true);
  assert.equal(probe.elements.device.dataset.appearance,'drawn');
  for(const id of ['iPhone19,2','iPhone99,1']) {
    const fallback=fixture(id);fallback.layout(444,960);
    assert.equal(fallback.elements['appearance-toggle'].hidden,true);
  }
});

test('production hides comparison while preserving official-first selection and drawn fallback', () => {
  for(const [id, profile] of Object.entries(catalog.models)) {
    const probe=fixture(id, {language:'en'}, false), toggle=probe.elements['appearance-toggle'];
    for(const rotation of ['rot0','rot90','rot270']) {
      const landscape=rotation!=='rot0';
      probe.layout(landscape?profile.screenHeight:profile.screenWidth,landscape?profile.screenWidth:profile.screenHeight,rotation);
      assert.equal(toggle.hidden,true,id);
      assert.equal(probe.elements.device.dataset.appearance,'official',id);
      toggle.events.click();
      assert.equal(probe.elements.device.dataset.appearance,'official',id);
    }
    probe.elements.bezel.events.error();
    assert.equal(probe.elements.device.dataset.appearance,'drawn',id);
    assert.equal(toggle.hidden,true,id);
  }
  for(const [id, expected] of [['iPhone18,1','drawn'],['iPhone19,2','drawn'],['iPhone99,1','generic']]) {
    const probe=fixture(id, {language:'en'}, false);probe.layout(1206,2622);
    assert.equal(probe.elements.device.dataset.appearance,expected,id);
    assert.equal(probe.elements['appearance-toggle'].hidden,true,id);
  }
  const missing=fixture('iPhone13,3', {language:'en'}, false);
  missing.run('setDevice({device:{productType:"iPhone13,3"},bezel:null})');missing.layout(1170,2532);
  assert.equal(missing.elements.device.dataset.appearance,'drawn');
  assert.equal(missing.elements['appearance-toggle'].hidden,true);
});

test('appearance comparison preserves video size and centre across models, viewports and rotations', () => {
  for(const id of Object.keys(catalog.models)) {
    const p=catalog.models[id], probe=fixture(id);
    for(const [width,height] of [[1000,700],[360,380],[1400,420]]) {
      probe.elements.stage.clientWidth=width;probe.elements.stage.clientHeight=height;
      for(const rotation of ['rot0','rot90','rot270']) {
        const landscape=rotation!=='rot0';
        probe.layout(landscape?p.screenHeight:p.screenWidth,landscape?p.screenWidth:p.screenHeight,rotation);
        const geometry=()=>{
          const d=probe.elements.device.style,s=probe.elements.screen.style;
          const [tx,ty]=d.transform.match(/-?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?(?=px)/gi).map(Number);
          return [parseFloat(s.width),parseFloat(s.height),
            -parseFloat(d.width)/2+parseFloat(s.left)+parseFloat(s.width)/2+tx,
            -parseFloat(d.height)/2+parseFloat(s.top)+parseFloat(s.height)/2+ty];
        };
        const official=geometry();probe.elements['appearance-toggle'].events.click();
        const drawn=geometry();
        for(let i=0;i<4;i++)assert.ok(Math.abs(official[i]-drawn[i])<1e-8,`${id} ${rotation} geometry ${i}`);
        assert.ok(Math.abs(drawn[2])<1e-8&&Math.abs(drawn[3])<1e-8);
        probe.elements['appearance-toggle'].events.click();
      }
    }
  }
});

const hardwareReferences=JSON.parse(readFileSync(new URL('./fixtures/preview-hardware.json',import.meta.url),'utf8'));

test('every supported identifier has independently checked opening geometry', () => {
  const models=fixture().run('drawnModels');
  assert.deepEqual(Object.keys(models).sort(),Object.keys(hardwareReferences).sort());
  for(const id of Object.keys(catalog.models)) assert.ok(models[id],`${id} must not silently use a generic drawing`);
  for(const [id,ref] of Object.entries(hardwareReferences)) {
    const model=models[id], [x,y,w,h,r,ear]=model[6].cutout;
    if(ref.file) {
      assert.equal(ref.sha256,catalog.models[id].sha256,`${id} reference changed; recalibrate`);
      const f=400/ref.screenWidth;
      assert.ok(Math.abs(y-ref.top*f)<.02,id);
      assert.ok(Math.abs(y+h-ref.bottom*f)<.02,id);
      for(const [nativeY,left,right] of ref.edgeSamples) {
        const dy=nativeY*f-y;
        const lower=r-Math.sqrt(Math.max(0,r*r-Math.max(0,dy-(h-r))**2));
        const upper=model[5]==='notch'
          ?ear-Math.sqrt(Math.max(0,ear*ear-Math.max(0,ear-dy)**2))
          :r-Math.sqrt(Math.max(0,r*r-Math.max(0,r-dy)**2));
        const inset=model[5]==='notch'?lower-upper:lower+upper;
        assert.ok(Math.abs(x+inset-left*f)<3.2,`${id} left opening at ${nativeY}`);
        assert.ok(Math.abs(x+w-inset-right*f)<3.2,`${id} right opening at ${nativeY}`);
      }
    }else{
      const f=400/ref.screenWidth;
      assert.ok(Math.abs(w-ref.width*f)<.01,id);
      assert.ok(Math.abs(h-ref.height*f)<.01,id);
      assert.ok(Math.abs(y-(ref.centerY?(ref.centerY-ref.height/2-ref.inset)*f:0))<.01,id);
    }
  }
});

test('sensor coordinates stay screen-relative through rotations, resizing and model changes', () => {
  const probe=fixture();probe.run('forceDrawing=true');
  const models=probe.run('drawnModels');
  for(const [id,m] of Object.entries(models)) {
    probe.run(`setDevice(${JSON.stringify({device:{productType:id},bezel:catalog.models[id]||null})})`);
    for(const rotation of ['rot0','rot90','rot270','rot180']) {
      const horizontal=rotation==='rot90'||rotation==='rot270';
      probe.layout(horizontal?m[2]:m[1],horizontal?m[1]:m[2],rotation);
      const s=probe.elements.cutout.style,[x,y,w,h,r,ear]=m[6].cutout;
      assert.equal(probe.elements.cutout.hidden,false,id);
      assert.ok(Math.abs(parseFloat(s.left)-m[3]-x)<1e-8,id);
      assert.ok(Math.abs(parseFloat(s.top)-m[3]-y)<1e-8,id);
      assert.equal(parseFloat(s.width),w);assert.equal(parseFloat(s.height),h);
      assert.equal(parseFloat(s['--cutout-radius']),r);assert.equal(parseFloat(s['--shoulder']),ear);
      assert.equal(parseFloat(probe.elements.speaker.style.width),m[6].speaker[2]);
      assert.ok(parseFloat(probe.elements.speaker.style.top)>=0,id);
    }
  }
});

test('preview labels follow the primary browser language with an English fallback', async () => {
  for(const [browser,zh] of [
    [{language:'zh-CN'},true], [{languages:['zh-TW','en-US']},true],
    [{languages:['en-US','zh-CN'],language:'zh-CN'},false],
    [{language:'ja-JP'},false], [{languages:[],language:'zh-HK'},true], [{},false]
  ]) {
    const p=fixture('iPhone13,3',browser), e=p.elements;
    assert.equal(p.document.documentElement.lang,zh?'zh-CN':'en');
    assert.equal(p.document.title,zh?'iPhone-use · 实时预览':'iPhone-use · Live preview');
    assert.equal(e.screen.alt,zh?'iPhone 实时画面':'Live iPhone screen');
    assert.equal(e.connection.title,zh?'正在连接…':'Connecting…');
    assert.equal(e['placeholder-label'].textContent,zh?'等待手机画面':'Waiting for iPhone screen');
    assert.equal(e['diagnostics-label'].textContent,zh?'浏览器显示统计（最近 1800 帧）':'Browser display metrics (last 1,800 frames)');
    e['appearance-toggle'].events.click();
    assert.equal(e['appearance-toggle'].title,zh?'切换官方外观':'Use official frame');
    assert.equal(e['appearance-toggle']['aria-label'],e['appearance-toggle'].title);
    p.document.fullscreenElement={};p.document.events.fullscreenchange();
    assert.equal(e.fullscreen.title,zh?'退出全屏':'Exit fullscreen');
    await e.fullscreen.events.click(); // No fullscreen API in this fixture: exercise failure label.
    assert.equal(e.fullscreen.title,zh?'浏览器未允许全屏':'Fullscreen unavailable in this browser');
    assert.equal(e.fullscreen['aria-label'],e.fullscreen.title);
    await p.run("fetch=async()=>({ok:true,json:async()=>({mediaHealthy:false,error:'native_media_unhealthy'})});health()");
    assert.equal(e.connection.title,(zh?'连接不可用':'Connection unavailable')+': native_media_unhealthy');
    assert.equal(e.state.textContent,e.connection.title);
    await p.run("fetch=async()=>{throw Error()};health()");
    assert.equal(e.connection.title,zh?'预览已停止或连接断开':'Preview stopped or disconnected');
  }
});

test('floating chrome yields room only when it would overlap the device envelope', () => {
  const probe=fixture();
  const cases=[
    {width:1280,height:720,rw:1.08,rh:2.25,controls:[{left:20,right:190,bottom:80},{left:1142,right:1260,bottom:80}],inset:0},
    {width:390,height:844,rw:1.08,rh:2.25,controls:[{left:12,right:180,bottom:64},{left:270,right:378,bottom:64}],inset:76},
    {width:1280,height:720,rw:2.25,rh:1.08,controls:[{left:20,right:190,bottom:80},{left:1142,right:1260,bottom:80}],inset:92},
    {width:320,height:240,rw:2.25,rh:1.08,controls:[{left:12,right:168,bottom:64},{left:200,right:308,bottom:64}],inset:76},
    {width:800,height:1400,rw:1.08,rh:2.25,controls:[{left:20,right:200,bottom:80},{left:662,right:780,bottom:80}],inset:92}
  ];
  for(const c of cases){
    const p=probe.run(`fitPreview(${c.width},${c.height},${c.rw},${c.rh},${JSON.stringify(c.controls)})`);
    assert.equal(p.topInset,c.inset);
    const left=(c.width-c.rw*p.scale)/2,right=c.width-left,top=(c.height-c.rh*p.scale)/2+p.topInset/2,bottom=top+c.rh*p.scale;
    assert.ok(left>=19.99&&right<=c.width-19.99&&bottom<=c.height-19.99);
    for(const control of c.controls)assert.ok(left>=control.right+12||right<=control.left-12||top>=control.bottom+12);
  }
});
