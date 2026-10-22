import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('../../Sources/IPhoneUseCore/NativePreviewPage.swift', import.meta.url), 'utf8');
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1];

const catalog=JSON.parse(readFileSync(new URL('../../assets/preview/catalog.json',import.meta.url),'utf8'));

function fixture(productType='iPhone13,3', navigator={language:'zh-CN'}, appearanceComparisonEnabled=true) {
  let clock = 0;
  const elements = Object.fromEntries(['notice', 'notice-title', 'notice-message', 'gestures', 'screen', 'state', 'diagnostics', 'metrics', 'device', 'stage', 'bezel', 'shell', 'hardware', 'cutout', 'speaker', 'device-name', 'connection', 'appearance-toggle', 'viewer', 'placeholder-label', 'diagnostics-label', 'identity'].map(id => [id, { dataset: {}, style: { setProperty(name,value) { this[name]=value; } }, clientWidth: 1000, clientHeight: id==='identity'?32:700, getBoundingClientRect() { return {left:0,right:0,top:0,bottom:0}; }, events: {}, addEventListener(name, fn) { this.events[name]=fn; }, setAttribute(name,value) { this[name]=value; } }]));
  const document = { documentElement:{}, events:{}, visibilityState: 'visible', getElementById: id => elements[id], addEventListener: (name, fn) => { document.events[name]=fn;if(name==='visibilitychange'){const previous=document.visibilityChanged;document.visibilityChanged=()=>{previous?.();fn();};} } };
  let report;
  const context = vm.createContext({ document, navigator, URLSearchParams, location: { search: '?diagnostics=1' },
    ResizeObserver: class { observe() {} }, performance: { now: () => clock }, Date: { now: () => clock },
    requestAnimationFrame: fn => fn(), setInterval: fn => { report = fn; }, setTimeout() {}, clearTimeout() {},
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
        assert.ok(Math.abs(drawn[2])<1e-8&&Math.abs(drawn[3]+(probe.elements.identity.clientHeight+16)/2)<1e-8);
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
    await p.run("fetch=async()=>({ok:true,json:async()=>({mediaHealthy:false,error:'native_media_unhealthy'})});health()");
    assert.equal(e.connection.title,(zh?'连接不可用':'Connection unavailable')+': native_media_unhealthy');
    assert.equal(e.state.textContent,e.connection.title);
    await p.run("fetch=async()=>{throw Error()};health()");
    assert.equal(e.connection.title,zh?'预览已停止或连接断开':'Preview stopped or disconnected');
  }
});

test('device and caption fit together without overlap in portrait and landscape', () => {
  const probe=fixture();
  for(const [width,height,rw,rh,captionHeight] of [
    [1280,720,1.08,2.25,32], [390,844,1.08,2.25,32],
    [1280,720,2.25,1.08,32], [320,240,2.25,1.08,32],
    [800,1400,1.08,2.25,48]
  ]) {
    const p=probe.run(`fitPreview(${width},${height},${rw},${rh},${captionHeight})`);
    const left=(width-rw*p.scale)/2,right=width-left;
    const top=(height-rh*p.scale)/2+p.offsetY,bottom=top+rh*p.scale;
    assert.ok(left>=19.99&&right<=width-19.99&&top>=19.99);
    assert.ok(Math.abs(p.captionTop-bottom-16)<1e-8);
    assert.ok(p.captionTop+captionHeight<=height-19.99);
  }
});


test('gesture overlay maps to the actual screen aperture in both appearances and orientations', () => {
  const p=fixture();
  for(const [w,h,rot] of [[444,960,'rot0'],[960,444,'rot90'],[960,444,'rot270']]){
    p.layout(w,h,rot);
    for(const property of ['left','top','width','height','borderRadius']) assert.equal(p.elements.gestures.style[property],p.elements.screen.style[property]);
    p.elements.device.dataset.ready='true';
    const e={kind:'swipe',rotation:rot,aspect:w/h,paths:[[[.2,.8],[.8,.2]]]};
    p.run(`showGestures([${JSON.stringify(e)}])`);
    assert.doesNotMatch(p.elements.gestures.innerHTML,/<path|gesture-line|gesture-ring/);
    assert.match(p.elements.gestures.innerHTML,/gesture-motion/);
    p.run('forceDrawing=true;layoutKey="";layout()');
    assert.equal(p.elements.gestures.style.width,p.elements.screen.style.width);
    assert.equal(p.elements.gestures.innerHTML,'');
  }
});

test('gesture rendering rejects other orientations, invalid points and hidden-page history', () => {
  const p=fixture();p.layout(444,960);p.elements.device.dataset.ready='true';
  const good={kind:'tap',rotation:'rot0',aspect:444/960,paths:[[[.5,.5],[.5,.5]]]};
  p.run(`showGestures([${JSON.stringify(good)}])`);assert.match(p.elements.gestures.innerHTML,/gesture-touch/);
  p.run('clearGestures()');
  for(const e of [{...good,rotation:'rot90'},{...good,paths:[[[2,.5],[.5,.5]]]},{...good,kind:'type'}]){
    p.run(`showGestures([${JSON.stringify(e)}])`);assert.equal(p.elements.gestures.innerHTML,'');
  }
  p.visibility('hidden');p.run(`showGestures([${JSON.stringify(good)}])`);assert.equal(p.elements.gestures.innerHTML,'');
});


test('all gestures use neutral contacts with bounded distinct animation lifetimes', () => {
  const p=fixture();p.layout(444,960);p.elements.device.dataset.ready='true';
  for(const [kind,duration] of Object.entries({'tap':600,'double-tap':850,'long-press':1200,'swipe':900,'drag':1400,'pinch':1000})){
    const paths=kind==='pinch'?[[[.4,.5],[.2,.5]],[[.6,.5],[.8,.5]]]:[[[.2,.8],[.8,.2]]];
    p.run(`showGestures([${JSON.stringify({kind,rotation:'rot0',aspect:444/960,paths})}])`);
    const html=p.elements.gestures.innerHTML;
    assert.match(html,new RegExp('class="gesture-'+kind+'"'));
    assert.ok(html.includes('--gesture-duration:'+duration+'ms'));
    assert.equal((html.match(/<circle /g)||[]).length,paths.length);
    assert.doesNotMatch(html,/<path|gesture-ring|gesture-line/);
  }
  assert.match(source,/fill:rgba\(142,142,147,\.48\)/);
  assert.match(source,/@media\(prefers-reduced-motion:reduce\).*\.gesture-touch\{animation:none/);
});


test('in-flight gesture responses cannot restore history after a visibility change', async () => {
  for(const failed of [false,true]) {
    const p=fixture();p.layout(444,960);p.elements.device.dataset.ready='true';
    const event={kind:'tap',rotation:'rot0',aspect:444/960,paths:[[[.5,.5],[.5,.5]]]};
    p.run(`gestureCursor=10;let pendingResolve,pendingReject;
      fetch=()=>new Promise((resolve,reject)=>{pendingResolve=resolve;pendingReject=reject;});`);
    const pending=p.run('gestures()');
    p.visibility('hidden');p.visibility('visible');
    p.run(failed?'pendingReject(Error())':`pendingResolve({ok:true,json:async()=>({sequence:11,events:[${JSON.stringify(event)}]})})`);
    await pending;
    assert.equal(p.run('gestureCursor'),null);
    assert.equal(p.elements.gestures.innerHTML,'');
    // The first new response establishes a cursor and must not replay old events.
    await p.run(`fetch=async()=>({ok:true,json:async()=>({sequence:12,events:[${JSON.stringify(event)}]})});gestures()`);
    assert.equal(p.run('gestureCursor'),12);
    assert.equal(p.elements.gestures.innerHTML,'');
    // Subsequent live events still render normally.
    await p.run(`fetch=async()=>({ok:true,json:async()=>({sequence:13,events:[${JSON.stringify(event)}]})});gestures()`);
    assert.match(p.elements.gestures.innerHTML,/gesture-touch/);
  }
});


test('gesture long polling renews immediately and backs off only on failure or hiding', async () => {
  const p=fixture();p.layout(444,960);p.elements.device.dataset.ready='true';
  p.run(`let delays=[];setTimeout=(fn,delay)=>{if(fn===gestures)delays.push(delay);};
    fetch=async()=>({ok:true,json:async()=>({sequence:0,events:[]})});`);
  await p.run('gestures()');
  assert.equal(p.run('delays.at(-1)'),0);
  await p.run('fetch=async()=>{throw Error()};gestures()');
  assert.equal(p.run('delays.at(-1)'),200);
  p.visibility('hidden');await p.run('gestures()');
  assert.equal(p.run('delays.at(-1)'),1000);
});

function decodingFixture() {
  const p=fixture();
  p.run(`
    let candidates=[],revoked=[],layoutCalls=0,urlID=0;
    URL={createObjectURL:()=> 'blob:'+ ++urlID,revokeObjectURL:url=>revoked.push(url)};
    layout=()=>{layoutCalls++;};
    screen.naturalWidth=444;screen.naturalHeight=960;screen.style.cssText='width:100px';
    function candidate(){
      const image={naturalWidth:444,naturalHeight:960,style:{},cloneNode:()=>candidate(),replaceWith(next){this.replacement=next;}};
      image.decode=()=>new Promise((resolve,reject)=>{image.resolve=resolve;image.reject=reject;});
      candidates.push(image);return image;
    }
    screen.cloneNode=()=>candidate();screen.replaceWith=function(next){this.replacement=next;};
    let originalScreen=screen;
  `);
  return p;
}

test('pending decode keeps the displayed frame; success releases only the replaced URL', async () => {
  const p=decodingFixture();
  p.run(`objectURL='blob:old';let pendingDisplay=displayFrame({},'rot0');`);
  assert.equal(p.run('screen===originalScreen'),true);
  assert.equal(p.run('revoked.length'),0);
  assert.equal(p.run("candidates[0].decoding"),'async');
  // Resizing while decode is pending must not be overwritten by a stale clone.
  p.run("screen.style.cssText='width:200px';candidates[0].resolve();");
  await p.run('pendingDisplay');
  assert.equal(p.run('screen===candidates[0]'),true);
  assert.equal(p.run('screen.style.cssText'),'width:200px');
  assert.equal(p.run('layoutCalls'),0);
  assert.equal(p.run("revoked.join(',')"),'blob:old');
  assert.equal(p.run('objectURL'),'blob:1');
  assert.equal(p.run('device.dataset.ready'),'true');
});

test('a rejected decode retains good pixels and releases the failed candidate URL', async () => {
  const p=decodingFixture();
  p.run("objectURL='blob:old';let pendingDisplay=displayFrame({},'rot90');candidates[0].reject(Error('bad JPEG'));");
  await assert.rejects(p.run('pendingDisplay'),/bad JPEG/);
  assert.equal(p.run('screen===originalScreen'),true);
  assert.equal(p.run('objectURL'),'blob:old');
  assert.equal(p.run('rotation'),'rot0');
  assert.equal(p.run("revoked.join(',')"),'blob:1');
});

test('decoded dimension and half-turn changes still relayout and update gesture geometry', async () => {
  const p=decodingFixture();
  p.run("let pendingDisplay=displayFrame({},'rot90');candidates[0].naturalWidth=960;candidates[0].naturalHeight=444;candidates[0].resolve();");
  await p.run('pendingDisplay');
  assert.equal(p.run('layoutCalls'),1);
  assert.equal(p.run('rotation'),'rot90');
  p.run("pendingDisplay=displayFrame({},'rot270');candidates[1].naturalWidth=960;candidates[1].naturalHeight=444;candidates[1].resolve();");
  await p.run('pendingDisplay');
  assert.equal(p.run('layoutCalls'),2);
  assert.equal(p.run('rotation'),'rot270');
  assert.equal(p.run("revoked.join(',')"),'blob:1');
});

test('frame polling waits for the bounded candidate and retries a decode error', async () => {
  const p=decodingFixture();
  p.run(`let requested=[],scheduled=[];
    fetch=async url=>{requested.push(url);return {ok:true,headers:{get:key=>({'X-Preview-Sequence':'4','X-Preview-Rotation':'rot0'})[key]||'1'},blob:async()=>({})};};
    setTimeout=(fn,delay)=>scheduled.push({fn,delay});
    let polling=frames();`);
  // Flush the fetch/body awaits, without resolving the image decode.
  await Promise.resolve();await Promise.resolve();await Promise.resolve();
  assert.equal(p.run('requested.length'),1);
  assert.equal(p.run('scheduled.length'),0);
  p.run("candidates[0].reject(Error('bad JPEG'))");
  await p.run('polling');
  assert.equal(p.run('failures'),1);
  assert.equal(p.run('scheduled.length'),1);
  assert.equal(p.run('scheduled[0].delay'),100);
  assert.equal(p.run('screen===originalScreen'),true);
});

test('confirmed authorization updates status without covering healthy live media', () => {
  const p=fixture();p.frame(100,1);p.run('lastFrameAt=100');
  const connection={phase:'ready',authorization:'required',reason:'ui_automation_authorization_required',requiresUserAction:true,monitorAvailable:true,evidence:'device_log_exact_runner_pid'};
  p.run(`renderHealth(${JSON.stringify({connection,mediaHealthy:true,frameAgeSeconds:0})})`);
  assert.equal(p.elements.notice.hidden,true);
  assert.equal(p.elements.state.textContent,'在 iPhone 上授权');
  p.run(`renderHealth(${JSON.stringify({connection:{...connection,authorization:'enabled',requiresUserAction:false},mediaHealthy:true,frameAgeSeconds:0})})`);
  assert.equal(p.elements.notice.hidden,true);
});

test('startup guidance is conditional and ordinary connection failure never claims authorization', async () => {
  const p=fixture();
  p.run(`renderHealth({connection:{phase:'starting',authorization:'unknown',requiresUserAction:false}})`);
  assert.equal(p.elements['notice-title'].textContent,'正在等待 iPhone 就绪');
  assert.match(p.elements['notice-message'].textContent,/如果/);
  p.run(`renderHealth({connection:{phase:'starting',authorization:'authenticated'}})`);
  assert.equal(p.elements['notice-title'].textContent,'授权已完成，正在连接');
  for(const state of [{mediaHealthy:false,error:'timeout'}, {connection:{phase:'failed',authorization:'required',reason:'ui_automation_authorization_required',requiresUserAction:true,monitorAvailable:true,evidence:'device_log_exact_runner_pid'}}, {connection:{phase:'ready',authorization:'required',reason:'ui_automation_authorization_required',requiresUserAction:true,monitorAvailable:false,evidence:'none'},mediaHealthy:false}]){
    p.run(`renderHealth(${JSON.stringify(state)})`);
    assert.equal(p.elements.notice.hidden,false);
    assert.equal(p.elements['notice-title'].textContent,'连接未完成');
    assert.doesNotMatch(p.elements['notice-message'].textContent,/授权|认证/);
    assert.equal(p.elements.notice.dataset.kind,'error');
  }
  await p.run('fetch=async()=>{throw Error()};health()');
  assert.equal(p.elements['notice-title'].textContent,'预览已停止或连接断开');
});

test('lost authorization evidence never silently claims recovery while video remains healthy', () => {
  const p=fixture();p.frame(100,1);p.run('lastFrameAt=100');
  p.run(`renderHealth({connection:{phase:'ready',authorization:'unverified',monitorAvailable:false,requiresUserAction:false},mediaHealthy:true,frameAgeSeconds:0})`);
  assert.equal(p.elements.notice.hidden,true);
  assert.equal(p.elements.state.textContent,'请检查 iPhone 上的认证状态');
});

test('startup and authorization completion keep live video visible, but missing frames retain guidance', () => {
  const p=fixture('iPhone13,3',{language:'en'});p.frame(100,1);p.run('lastFrameAt=100');
  for(const authorization of ['unknown','required','authenticated','enabled']){
    const connection={phase:'starting',authorization,requiresUserAction:authorization==='required',reason:'ui_automation_authorization_required',monitorAvailable:true,evidence:'device_log_exact_runner_pid'};
    const status={device:{productType:'iPhone13,3'},bezel:catalog.models['iPhone13,3'],connection,mediaHealthy:true,frameAgeSeconds:0};
    p.run(`renderHealth(${JSON.stringify(status)})`);
    assert.equal(p.elements.notice.hidden,true);
    assert.equal(p.elements.device.dataset.appearance,'official');
    p.run(`renderHealth(${JSON.stringify({...status,mediaHealthy:false})})`);
    assert.equal(p.elements.notice.hidden,false);
    p.run('lastFrameAt=0');
    p.run(`renderHealth(${JSON.stringify(status)})`);
    assert.equal(p.elements.notice.hidden,false,'Wait until the browser has decoded a real frame');
    p.run('lastFrameAt=100');
  }
});


test('connection screen follows the video aperture for both frames and rotations', () => {
  const p=fixture();
  for(const drawn of [true,false])for(const rotation of ['rot0','rot90','rot270']){
    p.run(`forceDrawing=${drawn}`);
    const landscape=rotation!=='rot0';p.layout(landscape?2532:1170,landscape?1170:2532,rotation);
    for(const property of ['left','top','width','height','borderRadius'])assert.equal(p.elements.notice.style[property],p.elements.screen.style[property]);
    assert.equal(p.elements.notice.dataset.landscape,String(landscape));
  }
});

test('authorization artwork and instructions follow evidence and clear on recovery', () => {
  const p=fixture('iPhone13,3',{language:'en'});p.frame(100,1);p.run('lastFrameAt=100');
  p.run("renderHealth({connection:{phase:'starting',authorization:'required',reason:'ui_automation_authorization_required',requiresUserAction:true,monitorAvailable:true,evidence:'device_log_exact_runner_pid'}})");
  assert.equal(p.elements.notice.dataset.kind,'attention');
  assert.equal(p.elements.device.dataset.notice,'true');
  assert.match(p.elements['notice-message'].textContent,/Approve “Enable UI Automation” on your iPhone/);
  p.run("renderHealth({connection:{phase:'starting',authorization:'enabled'}})");
  assert.equal(p.elements.notice.dataset.kind,'success');
  p.run("renderHealth({connection:{phase:'ready',authorization:'enabled'},mediaHealthy:true,frameAgeSeconds:0})");
  assert.equal(p.elements.notice.hidden,true);
  assert.equal(p.elements.device.dataset.notice,'false');
});


test('other or unknown runtime permission requests never become UI Automation prompts', () => {
  const p=fixture();p.frame(100,1);p.run('lastFrameAt=100');
  const connection={phase:'ready',authorization:'required',requiresUserAction:true,monitorAvailable:true,evidence:'device_log_exact_runner_pid',reason:'ui_automation_authorization_required'};
  // Start with the genuine automation overlay, then ensure changing request type clears it.
  for(const reason of ['camera_permission_required','photos_permission_required','location_permission_required','unknown',undefined]){
    p.run(`renderHealth(${JSON.stringify({connection,mediaHealthy:true,frameAgeSeconds:0})})`);
    p.run(`renderHealth(${JSON.stringify({connection:{...connection,reason},mediaHealthy:true,frameAgeSeconds:0})})`);
    assert.equal(p.elements.notice.hidden,true);
    assert.equal(p.elements.device.dataset.notice,'false');
    assert.equal(p.elements.state.textContent,'实时画面');
  }
});
