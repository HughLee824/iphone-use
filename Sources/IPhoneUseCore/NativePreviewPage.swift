import Foundation

private final class NativePreviewAssetAnchor: NSObject {}

// Artwork is loaded once, outside the video encoder. No network fetch, source
// path embedded in the binary, or dependency on the caller's working directory.
enum NativePreviewPage {
    // A symlink-launched CLI can have no executable URL on its class bundle.
    // Keep the class bundle for XCTest, then resolve the CLI's main entry point.
    static func assetDirectory(executable: URL? = Bundle(for: NativePreviewAssetAnchor.self).executableURL ?? Bundle.main.executableURL) -> URL? {
        guard let executable else { return nil }
        let binary = executable.resolvingSymlinksInPath()
        let installed = binary.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/iphone-use/preview")
        if FileManager.default.fileExists(atPath: installed.appendingPathComponent("catalog.json").path) {
            return installed
        }
        var directory = binary.deletingLastPathComponent()
        // SwiftPM CLI and XCTest layouts have different depths under .build.
        for _ in 0..<8 {
            if directory.lastPathComponent == ".build" {
                return directory.deletingLastPathComponent().appendingPathComponent("assets/preview")
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    #if DEBUG
    static let appearanceComparisonEnabled = true
    #else
    static let appearanceComparisonEnabled = false
    #endif

    // Byte-for-byte copy of assets/brand/favicon-64.png, embedded for relocatable/offline previews.
    static let faviconPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAACXBIWXMAACxLAAAsSwGlPZapAAADBUlEQVRoge2aMU/qUBTH+Ral9A1icCCyaAuExMWJyRg/gYaErYsgkcUokjCU/RJGYTAhUpPOBJqYOOnAwNSFvZSWAIJK6EseyU3zfEItXMt99rdyzj/nV24bSI9LxxyXjjkuHXNc+k8WkGW5UqlwHHdtCY7jKpVKp9OxQUCW5UQi4fF4iKXxeDzJZNKyhhUBSZIYhiFWCsMwkiR9h4CmaaFQiEBAOBxWVRW5wMXFBYGMq6srtAIvLy8bGxsL5zg5OeF5XjDA8/zx8fHCRq/XOxqNEArU63UzF7LX633sVVXVTK8oiggFSqWSmSFKpdJkMjE2TiaTm5sbM73lchmhAACAQAwAwBH4HOcbWAxwjtA8nCO0GOAcoXk4R+h/OUK//oCrAMuy4/F4NBqxLIulAPz3KMsyfgKbm5swbTwe4ydA0zRM0zQNP4FoNArTJEnCTyAWi8E0URTxEygUCjCtWCziJ/D8/AzT8HuM+ny+9/d3mEbTNGYC5+fn8+9gYs0FWq0WjMrlcpgJHB4ewpy3t7dAIICTgNvtfnp6gjmCIHxWCdZT4PT01JhzcHCAk0AgEJBlGYbc39/PKQbrJkBR1OPjI0wYDoe7u7s4Cdze3hoTstns/HqwPgJut7tYLBrba7UaSZJ4CFAUVa1Wjb2SJG1tbS1sBOsgwDCM8dzrut7tdiORiJleYLtAMpns9/vGLk3TotGomekJGwVIkozH481m86+Wdru9t7dncnrCFgGSJFOpVLvd/ljfaDT8fr/56QlbBDiO+1g5GAysvc8E3y/w8PBgrJlOp4Ig7OzsWJiesEUgnU7PPn19feV5fn9/39rodt7ER0dHLMtub28TSwNsf4w6AsD+F93LUEb6otvkqsEyiEhXDUwue1jGi3rZQ9f1y8tLdAKZTOar83xZQFXVcDiMYvpIJPLPNZcVC8x+2QeDwdVOHwqFvmnlbIaiKGdnZytZ+qMoKpVKdbtdG9YuFUW5u7vL5/PW1i7z+Xy1WlUUZZkZfvbi6zrg0jHHZfcAy/Ib2Fmu6PHCFAAAAAAASUVORK5CYII=")!

    static let html = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <link rel="icon" type="image/png" sizes="64x64" href="favicon.png">
    <meta name="color-scheme" content="light dark"><title>iPhone-use · Live preview</title>
    <style>
    *{box-sizing:border-box} [hidden]{display:none!important}
    :root{color-scheme:light dark;--bg:#f5f5f7;--text:#1d1d1f;--muted:#68686d;--secondary:#515158;--glass:#ffffff40;--solid:#fafafb;--glass-line:#ffffffd9;--glass-edge:#2126370b;--glass-shadow:#1b243518;--button:#ffffff80;--hover:#fff;--pressed:#e8e9ed;--button-line:#2830440d;--separator:#282b330c;--focus:#0067db;--live:#168447;--waiting:#96601d;--error:#c33630;--shadow:#1e304329;font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:var(--text);background:var(--bg)}
    @media(prefers-color-scheme:dark){:root{--bg:#161619;--text:#f5f5f7;--muted:#a1a1a9;--secondary:#c3c3ca;--glass:#29292ec9;--solid:#29292e;--glass-line:#ffffff20;--glass-edge:#0005;--glass-shadow:#0003;--button:#ffffff09;--hover:#ffffff18;--pressed:#ffffff23;--button-line:#ffffff09;--separator:#ffffff12;--focus:#91bdff;--live:#80d7a5;--waiting:#e4b670;--error:#ff9b95;--shadow:#0005}}
    body{margin:0}button{font:inherit;color:inherit;cursor:pointer;touch-action:manipulation}button:focus-visible,summary:focus-visible{outline:2px solid var(--focus);outline-offset:4px}
    button:disabled{opacity:.4;cursor:default}
    .viewer{position:relative;height:100dvh;display:flex;flex-direction:column;background:var(--bg)}
    header{position:absolute;z-index:4;top:20px;left:20px;right:20px;display:flex;align-items:flex-start;justify-content:space-between;gap:16px;pointer-events:none}
    .glass{border:1px solid var(--glass-line);border-radius:32px;background:var(--solid);box-shadow:inset 0 0 0 1px var(--glass-edge),0 8px 28px var(--glass-shadow);pointer-events:auto}
    @supports ((backdrop-filter:blur(12px)) or (-webkit-backdrop-filter:blur(12px))){.glass{background:var(--glass);-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}}
    .identity{min-width:0;max-width:320px;height:60px;padding:0 18px;display:flex;align-items:center;gap:10px}
    .mark{width:26px;height:26px}#device-name{min-width:0;margin:0;font-size:14px;line-height:20px;font-weight:500;letter-spacing:-.15px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .toolbar{flex:none;display:flex;align-items:center;gap:12px;height:60px;padding:8px 12px}
    .toolbar button{flex:none;width:40px;height:40px;padding:9px;display:grid;place-items:center;border:1px solid var(--button-line);border-radius:50%;background:var(--button);transition:background-color 120ms ease,transform 120ms ease}
    .toolbar button:hover{background:var(--hover)}.toolbar button:active{background:var(--pressed);transform:scale(.94)}
    #appearance-toggle:not([hidden])+#fullscreen:not([hidden])::before{content:"";position:absolute;width:1px;height:24px;left:-7px;top:7px;background:var(--separator)}
    #fullscreen{position:relative}svg{display:block}.toolbar svg{width:20px;height:20px}#fullscreen .exit-icon{display:none}#fullscreen[data-active="true"] .enter-icon{display:none}#fullscreen[data-active="true"] .exit-icon{display:block}
    .connection{display:grid;place-items:center;width:26px;height:28px;flex:none;color:var(--waiting)}
    .connection[data-kind="live"]{color:var(--live)}.connection[data-kind="error"]{color:var(--error)}
    @media(prefers-reduced-motion:reduce){.toolbar button{transition:none}.toolbar button:active{transform:none}}
    @media(prefers-reduced-transparency:reduce),(prefers-contrast:more){.glass{background:var(--solid);-webkit-backdrop-filter:none;backdrop-filter:none}}
    @media(prefers-contrast:more){.glass,.toolbar button{border-color:var(--secondary)}.connection{outline:1px solid currentColor;outline-offset:2px;border-radius:5px}}
    .sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap;border:0}
    main{min-height:0;width:100%;flex:1;display:flex;flex-direction:column;align-items:center}
    #stage{position:relative;width:100%;flex:1;min-height:0;display:grid;place-items:center;overflow:hidden}
    #device{position:relative;flex:none}#screen{position:absolute;z-index:1;display:block;object-fit:contain;background:#08090b;visibility:hidden}
    #device[data-ready="true"] #screen{visibility:visible}
    #gestures{position:absolute;z-index:5;pointer-events:none;overflow:hidden;isolation:isolate}
    #gestures svg{position:absolute;inset:0;width:100%;height:100%;overflow:hidden}
    .gesture-touch{fill:rgba(142,142,147,.48);stroke:rgba(255,255,255,.72);stroke-width:1;transform-box:fill-box;transform-origin:center;animation:touch-press var(--gesture-duration) ease-out both}
    .gesture-motion{animation:touch-move var(--gesture-duration) cubic-bezier(.25,.1,.25,1) both}
    .gesture-double-tap .gesture-touch{animation-name:touch-double}
    .gesture-long-press .gesture-touch,.gesture-drag .gesture-touch{animation-name:touch-hold}
    .gesture-drag .gesture-motion{animation-name:touch-drag}
    @keyframes touch-press{0%{opacity:0;transform:scale(1.12)}12%{opacity:1;transform:scale(.92)}25%,70%{opacity:1;transform:scale(1)}100%{opacity:0;transform:scale(1.12)}}
    @keyframes touch-double{0%,42%{opacity:0;transform:scale(1.12)}12%,54%{opacity:1;transform:scale(.88)}25%,68%{opacity:1;transform:scale(1)}38%,100%{opacity:0;transform:scale(1.12)}}
    @keyframes touch-hold{0%{opacity:0;transform:scale(1.12)}10%,25%{opacity:1;transform:scale(.9)}35%,82%{opacity:1;transform:scale(1)}100%{opacity:0;transform:scale(1.12)}}
    @keyframes touch-move{0%,15%{transform:translate(0,0)}75%,100%{transform:translate(var(--dx),var(--dy))}}
    @keyframes touch-drag{0%,35%{transform:translate(0,0)}82%,100%{transform:translate(var(--dx),var(--dy))}}
    @media(prefers-reduced-motion:reduce){#gestures .gesture-touch{animation:none;opacity:1;transform:none}#gestures .gesture-motion{animation:none;transform:translate(var(--dx),var(--dy))}}
    #bezel{z-index:3;position:absolute;left:50%;top:50%;pointer-events:none;user-select:none}
    /* Static, independently authored materials. No blur, animation, canvas or per-frame drawing. */
    #shell,#hardware{position:absolute;left:50%;top:50%;pointer-events:none;user-select:none}
    #shell{border-radius:var(--outer-radius);background:linear-gradient(112deg,#8d9298 0%,#d1d5d8 4%,#5a6068 10%,#2b3036 35%,#949ba2 52%,#d9dde0 76%,#646b73 91%,#afb5bb 100%);box-shadow:0 0 0 1em #0a0b0d,0 10em 28em var(--shadow),inset 0 0 0 1em #eff2f47a}
    #shell[data-finish="polished"]{background:linear-gradient(105deg,#e6e8e9,#656b72 8%,#e3e5e6 17%,#8c949b 38%,#f7f8f8 68%,#727980 86%,#d5dadd);box-shadow:0 0 0 1em #353a40,0 10em 28em var(--shadow),inset 0 0 0 1em #fff9}
    #shell::before{content:"";position:absolute;inset:2.5em;border-radius:calc(var(--outer-radius) - 2.5em);background:#08090b;box-shadow:0 0 0 .8em #171a1d,inset 0 0 0 1em #565b6270}
    #shell::after{content:"";position:absolute;inset:1em;border-radius:calc(var(--outer-radius) - 1em);border:1em solid #ffffff24;pointer-events:none}
    .side-key{position:absolute;width:3em;border-radius:2em;background:linear-gradient(90deg,#33383e,#b2b8be 65%,#737b83);box-shadow:0 0 0 .5em #17191b}
    .action-key{left:-2.5em;top:19%;height:27em}.volume-up{left:-2.5em;top:27%;height:49em}.volume-down{left:-2.5em;top:35%;height:49em}.power-key{right:-2.5em;top:30%;height:73em}.camera-key{right:-1.5em;top:64%;height:49em;width:2em;background:#676d74}
    .antenna{position:absolute;width:3em;height:5em;background:#858990b0}.antenna.a{left:0;top:12%}.antenna.b{right:0;top:12%}.antenna.c{left:0;bottom:12%}.antenna.d{right:0;bottom:12%}
    #shell[data-generic="true"] .side-key,#shell[data-generic="true"] .antenna,#shell[data-camera="false"] .camera-key{display:none}
    #hardware{z-index:3}#cutout{position:absolute;background:#000;border-radius:var(--cutout-radius)}
    #cutout[data-shape="notch"]{border-radius:0 0 var(--cutout-radius) var(--cutout-radius)}
    #cutout[data-shape="notch"]::before{content:"";position:absolute;left:calc(0em - var(--shoulder));top:0;width:calc(100% + 2 * var(--shoulder));height:var(--shoulder);background:radial-gradient(circle var(--shoulder) at 0 100%,transparent calc(100% - .3em),#000 100%) left top,radial-gradient(circle var(--shoulder) at 100% 100%,transparent calc(100% - .3em),#000 100%) right top;background-size:var(--shoulder) var(--shoulder);background-repeat:no-repeat}
    #cutout::after{content:"";position:absolute;left:var(--camera-x);top:var(--camera-y);width:var(--camera-size);height:var(--camera-size);transform:translate(-50%,-50%);border-radius:50%;background:radial-gradient(circle at 37% 32%,#293d50 0%,#122130 23%,#080d15 48%,#151e2c 65%,#040609 75%);box-shadow:0 0 0 1em #090b10}
    #speaker{position:absolute;z-index:1;border-radius:8em;background:linear-gradient(#080a0d,#24272b 50%,#090b0e);box-shadow:inset 0 0 0 .6em #33373c}
    #placeholder{z-index:2;position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;color:var(--muted);font-size:12px}
    #placeholder svg{color:var(--muted)}#device[data-ready="true"] #placeholder{display:none}
    #diagnostics{padding:18px 28px;background:var(--bg);color:var(--secondary);font:12px ui-monospace,monospace}#metrics{white-space:pre-wrap;overflow-wrap:anywhere}summary{cursor:pointer}
    @media(max-width:600px),(max-height:450px){header{top:12px;left:12px;right:12px;gap:12px}.identity,.toolbar{height:52px}.identity{padding:0 12px;gap:7px}.toolbar{padding:5px 7px;gap:10px}#appearance-toggle:not([hidden])+#fullscreen:not([hidden])::before{left:-6px}}
    </style></head>
    <body><div class="viewer" id="viewer">
    <!-- Heroicons v2.2.0 (https://github.com/tailwindlabs/heroicons), embedded paths unchanged.
    MIT License

    Copyright (c) Tailwind Labs, Inc.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    -->
    <header id="chrome"><div class="identity glass" id="identity"><div class="connection" id="connection" data-kind="waiting" role="status" title="Connecting…"><svg aria-hidden="true" class="mark" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" data-slot="icon">  <path stroke-linecap="round" stroke-linejoin="round" d="M10.5 1.5H8.25A2.25 2.25 0 0 0 6 3.75v16.5a2.25 2.25 0 0 0 2.25 2.25h7.5A2.25 2.25 0 0 0 18 20.25V3.75a2.25 2.25 0 0 0-2.25-2.25H13.5m-3 0V3h3V1.5m-3 0h3m-3 18.75h3"/></svg><span id="state" class="sr-only">Connecting…</span></div><h1 id="device-name">iPhone</h1></div>
    <div class="toolbar glass" id="toolbar" role="group" aria-label="Preview controls"><button id="appearance-toggle" hidden title="Use drawn frame" aria-label="Use drawn frame"><svg aria-hidden="true" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" data-slot="icon">  <path stroke-linecap="round" stroke-linejoin="round" d="M16.5 8.25V6a2.25 2.25 0 0 0-2.25-2.25H6A2.25 2.25 0 0 0 3.75 6v8.25A2.25 2.25 0 0 0 6 16.5h2.25m8.25-8.25H18a2.25 2.25 0 0 1 2.25 2.25V18A2.25 2.25 0 0 1 18 20.25h-7.5A2.25 2.25 0 0 1 8.25 18v-1.5m8.25-8.25h-6a2.25 2.25 0 0 0-2.25 2.25v6"/></svg></button><button id="fullscreen" title="Enter fullscreen" aria-label="Enter fullscreen"><svg aria-hidden="true" class="enter-icon" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" data-slot="icon">  <path stroke-linecap="round" stroke-linejoin="round" d="M3.75 3.75v4.5m0-4.5h4.5m-4.5 0L9 9M3.75 20.25v-4.5m0 4.5h4.5m-4.5 0L9 15M20.25 3.75h-4.5m4.5 0v4.5m0-4.5L15 9m5.25 11.25h-4.5m4.5 0v-4.5m0 4.5L15 15"/></svg><svg aria-hidden="true" class="exit-icon" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" data-slot="icon">  <path stroke-linecap="round" stroke-linejoin="round" d="M9 9V4.5M9 9H4.5M9 9 3.75 3.75M9 15v4.5M9 15H4.5M9 15l-5.25 5.25M15 9h4.5M15 9V4.5M15 9l5.25-5.25M15 15h4.5M15 15v4.5m0-4.5 5.25 5.25"/></svg></button></div></header>
    <main><div id="stage"><div id="device" data-ready="false"><div id="shell" hidden aria-hidden="true"><i class="side-key action-key"></i><i class="side-key volume-up"></i><i class="side-key volume-down"></i><i class="side-key power-key"></i><i class="side-key camera-key"></i><i class="antenna a"></i><i class="antenna b"></i><i class="antenna c"></i><i class="antenna d"></i></div><div id="hardware" hidden aria-hidden="true"><i id="speaker"></i><i id="cutout" hidden></i></div><div id="gestures" aria-hidden="true"></div><img id="screen" alt="Live iPhone screen" draggable="false"><div id="placeholder"><svg aria-hidden="true" class="mark" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor" data-slot="icon">  <path stroke-linecap="round" stroke-linejoin="round" d="M10.5 1.5H8.25A2.25 2.25 0 0 0 6 3.75v16.5a2.25 2.25 0 0 0 2.25 2.25h7.5A2.25 2.25 0 0 0 18 20.25V3.75a2.25 2.25 0 0 0-2.25-2.25H13.5m-3 0V3h3V1.5m-3 0h3m-3 18.75h3"/></svg><span id="placeholder-label" class="sr-only">Waiting for iPhone screen</span></div><img id="bezel" hidden alt="" aria-hidden="true" draggable="false"></div></div>
    </main>
    </div><details id="diagnostics" hidden><summary id="diagnostics-label">Browser display metrics (last 1,800 frames)</summary><pre id="metrics"></pre></details>
    <script>

    let objectURL; const screen=document.getElementById('screen'), state=document.getElementById('state');
    const device=document.getElementById('device'), stage=document.getElementById('stage'), bezel=document.getElementById('bezel');
    const deviceName=document.getElementById('device-name'), shell=document.getElementById('shell'), hardware=document.getElementById('hardware');
    const cutout=document.getElementById('cutout'), speaker=document.getElementById('speaker');
    const connection=document.getElementById('connection'), fullscreen=document.getElementById('fullscreen');
    const appearanceToggle=document.getElementById('appearance-toggle'), toolbar=document.getElementById('toolbar');
    const appearanceComparisonEnabled=\(appearanceComparisonEnabled ? "true" : "false");
    const chrome=document.getElementById('chrome'), identity=document.getElementById('identity');
    // Use the primary browser language, not any secondary preference in its list.
    const language=navigator.languages?.[0]||navigator.language||'en';
    const chinese=/^zh(?:-|$)/i.test(language);
    const text=chinese?{
      controls:'预览控件',title:'iPhone-use · 实时预览',connecting:'正在连接…',drawn:'切换自绘外观',official:'切换官方外观',
      enterFullscreen:'进入全屏',exitFullscreen:'退出全屏',fullscreenDenied:'浏览器未允许全屏',
      screen:'iPhone 实时画面',placeholder:'等待手机画面',diagnostics:'浏览器显示统计（最近 1800 帧）',
      unavailable:'连接不可用',firstFrame:'等待首帧',waiting:'已连接 · 等待新画面',recovering:'正在恢复画面…',
      live:'实时画面',disconnected:'预览已停止或连接断开',
      metricsNote:'图片加载后的 rAF 绘制机会；页面可见性变化时重置；不代表物理屏幕呈现时间或端到端延迟'
    }:{
      controls:'Preview controls',title:'iPhone-use · Live preview',connecting:'Connecting…',drawn:'Use drawn frame',official:'Use official frame',
      enterFullscreen:'Enter fullscreen',exitFullscreen:'Exit fullscreen',fullscreenDenied:'Fullscreen unavailable in this browser',
      screen:'Live iPhone screen',placeholder:'Waiting for iPhone screen',diagnostics:'Browser display metrics (last 1,800 frames)',
      unavailable:'Connection unavailable',firstFrame:'Waiting for first frame',waiting:'Connected · Waiting for a new frame',recovering:'Recovering preview…',
      live:'Live preview',disconnected:'Preview stopped or disconnected',
      metricsNote:'Image load + rAF opportunity; resets on visibility change; not physical display or glass-to-glass latency'
    };
    toolbar.setAttribute('aria-label',text.controls);
    document.documentElement.lang=chinese?'zh-CN':'en';document.title=text.title;screen.alt=text.screen;
    document.getElementById('placeholder-label').textContent=text.placeholder;
    document.getElementById('diagnostics-label').textContent=text.diagnostics;
    function labelButton(button,label){button.title=label;button.setAttribute('aria-label',label);}
    labelButton(fullscreen,text.enterFullscreen);showState(text.connecting,'waiting');
    let forceDrawing=false;
    let artworkAvailable=true, rotation='rot0', layoutKey='', lastFrameAt=0;
    let connectedDevice={}, profile=null, identityKey='';
    // Exact Apple model identifiers and display dimensions, checked against Xcode device profiles.
    // Opening geometry is calibrated per model; see docs/preview-hardware-calibration.md.
    // Materials, lens highlights and side keys remain independently authored approximations.
    // name, display width/height, rim, screen radius, shape, hardware, finish, Camera Control.
    // Hardware uses a 400-unit screen width: cutout [x,y,w,h,radius,shoulder],
    // camera [centreX,centreY,diameter], speaker [x,y,w,h], all relative to screen top-left.
    const drawnModels={
      "iPhone12,5":["iPhone 11 Pro Max",1242,2688,25.79,37.07,"notch",{"cutout":[98.72,0.0,202.25,28.36,20.95,4.83],"camera":[241.58,9.35,10.99],"speaker":[176.95,5.48,45.77,8.06]},"polished",false],
      "iPhone12,3":["iPhone 11 Pro",1125,2436,28.85,40.96,"notch",{"cutout":[88.25,0.0,223.51,31.34,22.97,5.34],"camera":[246.3,9.62,12.15],"speaker":[174.89,5.34,50.58,8.9]},"polished",false],
      "iPhone12,1":["iPhone 11",828,1792,34.87,39.71,"notch",{"cutout":[88.18,0.0,223.64,31.48,25.42,4.6],"camera":[244.31,6.3,12.01],"speaker":[176.76,3.39,45.52,6.3]},"satin",false],
      "iPhone13,4":["iPhone 12 Pro Max",1284,2778,20.28,48.99,"notch",{"cutout":[101.8,0.0,196.4,29.64,21.68,4.52],"camera":[240.25,10.61,12.09],"speaker":[177.54,7.8,44.93,7.8]},"polished",false],
      "iPhone13,3":["iPhone 12 Pro",1170,2532,21.54,49.57,"notch",{"cutout":[92.13,0.0,215.74,32.82,23.25,6.32],"camera":[244.62,12.31,12.72],"speaker":[175.73,8.21,45.81,7.86]},"polished",false],
      "iPhone13,1":["iPhone 12 mini",1080,2340,23.15,46.3,"notch",{"cutout":[78.87,0.0,242.25,36.33,26.36,6.23],"camera":[249.51,14.6,14.35],"speaker":[172.75,10.33,52.0,8.19]},"satin",false],
      "iPhone13,2":["iPhone 12",1170,2532,21.54,49.57,"notch",{"cutout":[92.17,0.0,215.67,32.82,23.08,6.32],"camera":[244.79,12.31,13.25],"speaker":[175.73,8.55,48.55,8.21]},"satin",false],
      "iPhone14,3":["iPhone 13 Pro Max",1284,2778,19.31,50.16,"notch",{"cutout":[124.52,0.0,150.96,31.46,21.81,5.3],"camera":[145.64,10.44,11.59],"speaker":[168.54,-11.84,62.93,4.67]},"polished",false],
      "iPhone14,2":["iPhone 13 Pro",1170,2532,21.54,48.89,"notch",{"cutout":[117.03,0.0,165.94,34.53,23.93,5.81],"camera":[140.17,11.11,13.25],"speaker":[165.47,-13.33,69.06,5.13]},"polished",false],
      "iPhone14,4":["iPhone 13 mini",1080,2340,22.59,47.78,"notch",{"cutout":[107.14,0.0,185.73,40.0,26.48,6.85],"camera":[132.96,13.7,14.35],"speaker":[161.48,-13.7,77.04,5.93]},"satin",false],
      "iPhone14,5":["iPhone 13",1170,2532,21.54,48.89,"notch",{"cutout":[117.03,0.0,165.94,34.53,23.93,5.81],"camera":[140.17,11.11,13.25],"speaker":[165.47,-13.33,69.06,5.47]},"satin",false],
      "iPhone14,8":["iPhone 14 Plus",1284,2778,19.31,49.53,"notch",{"cutout":[124.51,0.0,150.67,31.15,21.34,4.98],"camera":[145.79,9.97,14.97],"speaker":[168.85,-12.46,62.62,4.98]},"satin",false],
      "iPhone15,3":["iPhone 14 Pro Max",1290,2796,17.36,51.47,"island",{"cutout":[141.71,10.54,116.59,34.11,17.05,0.0],"camera":[240.93,27.44,15.38],"speaker":[158,-10,84,1.4]},"polished",false],
      "iPhone15,2":["iPhone 14 Pro",1179,2556,19.68,56.32,"island",{"cutout":[136.39,11.54,127.23,37.32,18.66,0.0],"camera":[244.95,30.03,16.83],"speaker":[158,-10,84,1.4]},"polished",false],
      "iPhone14,7":["iPhone 14",1170,2532,21.2,49.23,"notch",{"cutout":[117.13,0.0,165.73,34.53,23.59,6.5],"camera":[140.0,11.45,16.96],"speaker":[165.47,-13.33,69.06,5.47]},"satin",false],
      "iPhone15,5":["iPhone 15 Plus",1290,2796,18.29,51.47,"island",{"cutout":[141.71,10.54,116.59,34.11,17.05,0.0],"camera":[240.93,27.44,15.38],"speaker":[158,-10,84,1.4]},"satin",false],
      "iPhone16,2":["iPhone 15 Pro Max",1290,2796,15.19,51.47,"island",{"cutout":[141.71,10.54,116.59,34.11,17.05,0.0],"camera":[240.93,27.44,15.38],"speaker":[158,-7,84,1.4]},"satin",false],
      "iPhone16,1":["iPhone 15 Pro",1179,2556,17.3,56.32,"island",{"cutout":[136.39,11.54,127.23,37.32,18.66,0.0],"camera":[244.61,30.03,16.83],"speaker":[158,-7,84,1.4]},"satin",false],
      "iPhone15,4":["iPhone 15",1179,2556,20.02,56.32,"island",{"cutout":[136.39,11.54,127.23,37.32,18.66,0.0],"camera":[244.95,30.03,16.83],"speaker":[158,-10,84,1.4]},"satin",false],
      "iPhone17,4":["iPhone 16 Plus",1290,2796,18.29,51.47,"island",{"cutout":[141.71,10.54,116.59,34.11,17.05,0.0],"camera":[240.93,27.6,14.9],"speaker":[158,-7,84,1.4]},"satin",true],
      "iPhone17,2":["iPhone 16 Pro Max",1320,2868,13.33,57.27,"island",{"cutout":[143.33,13.03,113.33,32.73,16.36,0.0],"camera":[240.45,29.24,15.03],"speaker":[158,-7,84,1.4]},"satin",true],
      "iPhone17,1":["iPhone 16 Pro",1206,2622,14.26,62.69,"island",{"cutout":[137.98,14.26,124.05,35.49,17.74,0.0],"camera":[244.11,32.01,16.45],"speaker":[158,-7,84,1.4]},"satin",true],
      "iPhone17,3":["iPhone 16",1179,2556,20.02,56.32,"island",{"cutout":[136.39,11.54,127.23,37.32,18.66,0.0],"camera":[244.95,30.03,16.83],"speaker":[158,-7,84,1.4]},"satin",true],
      "iPhone17,5":["iPhone 16e",1170,2532,21.49,48.55,"notch",{"cutout":[117.03,0,165.93,34.56,23.04,5.08],"camera":[140.57,11.75,14.87],"speaker":[162.99,-12.95,74.02,3.72]},"satin",false],
      "iPhone18,5":["iPhone 17e",1170,2532,21.49,48.55,"notch",{"cutout":[117.03,0,165.93,34.56,23.04,5.08],"camera":[140.57,11.75,14.87],"speaker":[162.99,-12.95,74.02,3.72]},"satin",false],
      "iPhone18,1":["iPhone 17 Pro",1206,2622,15.86,61.69,"island",{"cutout":[137.63,13.91,124.74,36.47,18.24,0],"camera":[244.13,32.15,16.82],"speaker":[156.56,-13.16,86.89,1.8]},"satin",true],
      "iPhone18,2":["iPhone 17 Pro Max",1320,2868,14.05,56.36,"island",{"cutout":[143.01,12.71,113.97,33.32,16.66,0],"camera":[240.32,29.37,15.37],"speaker":[160.31,-11.58,79.39,1.65]},"satin",true],
      "iPhone18,3":["iPhone 17",1206,2622,14.66,61.69,"island",{"cutout":[137.69,13.91,124.62,36.47,18.24,0],"camera":[244.07,32.15,16.82],"speaker":[156.56,-11.96,86.89,1.8]},"satin",true],
      "iPhone18,4":["iPhone Air",1260,2736,14.84,59.05,"island",{"cutout":[140.3,19.01,119.4,34.91,17.46,0],"camera":[242.24,36.46,16.1],"speaker":[158.42,-12.25,83.16,1.73]},"polished",false],
      "iPhone19,2":["iPhone 18 Pro",1206,2622,15.86,61.69,"island",{"cutout":[152.95,13.91,94.1,36.47,18.24,0],"camera":[228.81,32.15,16.82],"speaker":[156.56,-13.16,86.89,1.8]},"satin",true],
      "iPhone19,3":["iPhone 18 Pro Max",1320,2868,14.05,56.36,"island",{"cutout":[156.96,12.71,86.08,33.32,16.66,0],"camera":[226.38,29.37,15.37],"speaker":[160.31,-11.58,79.39,1.65]},"satin",true],
      "iPhone19,7":["iPhone 18 Pro Max",1320,2868,14.05,56.36,"island",{"cutout":[156.96,12.71,86.08,33.32,16.66,0],"camera":[226.38,29.37,15.37],"speaker":[160.31,-11.58,79.39,1.65]},"satin",true]
    };
    function setDevice(s){
      connectedDevice=s.device||{};profile=s.bezel||null;
      identityKey=JSON.stringify([connectedDevice,profile]);layout();
    }
    function fitPreview(width,height,ratioWidth,ratioHeight,controls){
      const fit=top=>Math.max(0,Math.min((width-40)/ratioWidth,(height-top-40)/ratioHeight));
      let scale=fit(0),topInset=0;
      const left=(width-ratioWidth*scale)/2,right=width-left,top=(height-ratioHeight*scale)/2;
      if(controls.some(r=>left<r.right+12&&right>r.left-12&&top<r.bottom+12)){
        topInset=Math.max(0,...controls.map(r=>r.bottom))+12;scale=fit(topInset);
      }
      return {scale,topInset};
    }
    function layout(){
      const model=Object.hasOwn(drawnModels,connectedDevice.productType)?drawnModels[connectedDevice.productType]:null;
      const w=screen.naturalWidth||profile?.screenWidth||model?.[1]||390, h=screen.naturalHeight||profile?.screenHeight||model?.[2]||844, landscape=w>h;
      const ratio=Math.min(w,h)/Math.max(w,h);
      const canShowOfficial=Boolean(artworkAvailable&&profile&&Math.abs(ratio-profile.screenWidth/profile.screenHeight)<.002&&rotation!=='rot180');
      const official=canShowOfficial&&!forceDrawing;
      const exact=model&&Math.abs(ratio-model[1]/model[2])<.002;
      const name=profile?.name||model?.[0]||connectedDevice.name||connectedDevice.productType||'iPhone';
      if(deviceName.textContent!==name){deviceName.textContent=name;deviceName.title=name;}
      const key=[w,h,rotation,artworkAvailable,forceDrawing,identityKey,stage.clientWidth,stage.clientHeight,identity.clientWidth,toolbar.clientWidth,chrome.clientHeight].join(':');
      if(key===layoutKey)return;layoutKey=key;
      appearanceToggle.hidden=!appearanceComparisonEnabled||!canShowOfficial;toolbar.hidden=appearanceToggle.hidden&&fullscreen.hidden;
      labelButton(appearanceToggle,forceDrawing?text.official:text.drawn);
      const angle=landscape?(rotation==='rot90'?90:-90):(rotation==='rot180'?180:0);
      const rim=exact?model[3]:12, radius=exact?model[4]:32;
      const screenRatio=canShowOfficial?profile.screenWidth/profile.screenHeight:ratio;
      const drawing={canvasWidth:400+rim*2,canvasHeight:400/screenRatio+rim*2,screenX:rim,screenY:rim,screenWidth:400,screenHeight:400/screenRatio,cornerRadius:radius};
      const p=official?profile:drawing;
      // Fit both appearances against the same screen-centred envelope. PNG
      // transparent margins and independently drawn rims must not zoom the video.
      const candidates=canShowOfficial?[profile,drawing]:[p];
      const fitWidth=Math.max(...candidates.map(p=>(p.screenWidth+2*Math.max(p.screenX,p.canvasWidth-p.screenX-p.screenWidth))/p.screenWidth));
      const fitHeight=Math.max(...candidates.map(p=>(p.screenHeight+2*Math.max(p.screenY,p.canvasHeight-p.screenY-p.screenHeight))/p.screenWidth));
      const width=landscape?p.canvasHeight:p.canvasWidth,height=landscape?p.canvasWidth:p.canvasHeight;
      const sw=landscape?p.screenHeight:p.screenWidth,sh=landscape?p.screenWidth:p.screenHeight;
      const x=landscape?(angle===90?p.canvasHeight-p.screenY-p.screenHeight:p.screenY):p.screenX;
      const y=landscape?(angle===90?p.screenX:p.canvasWidth-p.screenX-p.screenWidth):p.screenY;
      const stageRect=stage.getBoundingClientRect();
      const controls=[identity,toolbar].filter(el=>!el.hidden).map(el=>{const r=el.getBoundingClientRect();return {left:r.left-stageRect.left,right:r.right-stageRect.left,bottom:r.bottom-stageRect.top};});
      const placement=fitPreview(stage.clientWidth,stage.clientHeight,landscape?fitHeight:fitWidth,landscape?fitWidth:fitHeight,controls);
      const screenScale=placement.scale;
      const scale=screenScale/p.screenWidth;
      device.style.width=width*scale+'px';device.style.height=height*scale+'px';
      device.style.transform='translate('+((width-sw)/2-x)*scale+'px,'+(((height-sh)/2-y)*scale+placement.topInset/2)+'px)';
      device.dataset.appearance=official?'official':exact?'drawn':'generic';
      screen.style.left=x*scale+'px';screen.style.top=y*scale+'px';
      screen.style.width=sw*scale+'px';screen.style.height=sh*scale+'px';
      screen.style.borderRadius=p.cornerRadius*scale+'px';
      for(const property of ['left','top','width','height','borderRadius'])document.getElementById('gestures').style[property]=screen.style[property];
      document.getElementById('gestures').innerHTML='';
      bezel.hidden=!official;shell.hidden=official;hardware.hidden=official;
      const transform='translate(-50%,-50%) rotate('+angle+'deg)';
      if(official){
        if(!bezel.dataset.loaded){bezel.dataset.loaded='true';bezel.src='bezel';}
        bezel.style.width=p.canvasWidth*scale+'px';bezel.style.height=p.canvasHeight*scale+'px';bezel.style.transform=transform;
      }else{
        for(const layer of [shell,hardware]){
          layer.style.width=p.canvasWidth*scale+'px';layer.style.height=p.canvasHeight*scale+'px';
          layer.style.fontSize=scale+'px';layer.style.transform=transform;
        }
        shell.style.setProperty('--outer-radius',(radius+rim)+'em');
        shell.dataset.finish=exact?model[7]:'satin';shell.dataset.generic=String(!exact);shell.dataset.camera=String(Boolean(exact&&model[8]));
        cutout.hidden=!exact;speaker.hidden=!exact;
        if(exact){
          const sensor=model[6], [cx,cy,cw,ch,cr,shoulder]=sensor.cutout;
          cutout.dataset.shape=model[5];
          cutout.style.left=(rim+cx)+'em';cutout.style.top=(rim+cy)+'em';
          cutout.style.width=cw+'em';cutout.style.height=ch+'em';
          cutout.style.setProperty('--cutout-radius',cr+'em');cutout.style.setProperty('--shoulder',shoulder+'em');
          cutout.style.setProperty('--camera-x',(sensor.camera[0]-cx)+'em');
          cutout.style.setProperty('--camera-y',(sensor.camera[1]-cy)+'em');
          cutout.style.setProperty('--camera-size',sensor.camera[2]+'em');
          const [sx,sy,sw,sh]=sensor.speaker;
          speaker.style.left=(rim+sx)+'em';speaker.style.top=(rim+sy)+'em';
          speaker.style.width=sw+'em';speaker.style.height=sh+'em';
        }
      }
    }
    appearanceToggle.addEventListener('click',()=>{if(appearanceComparisonEnabled){forceDrawing=!forceDrawing;layout();}});
    bezel.addEventListener('error',()=>{artworkAvailable=false;layout();});
    fullscreen.hidden=!document.fullscreenEnabled;
    const layoutObserver=new ResizeObserver(layout);
    for(const el of [stage,identity,toolbar])layoutObserver.observe(el);layout();
    fullscreen.addEventListener('click',async()=>{try{if(document.fullscreenElement)await document.exitFullscreen();else await document.getElementById('viewer').requestFullscreen();}catch{labelButton(fullscreen,text.fullscreenDenied);}});
    document.addEventListener('fullscreenchange',()=>{fullscreen.dataset.active=String(Boolean(document.fullscreenElement));labelButton(fullscreen,document.fullscreenElement?text.exitFullscreen:text.enterFullscreen);});
    function showState(text,kind){state.textContent=text;connection.title=text;connection.dataset.kind=kind;}
    const diagnostic=new URLSearchParams(location.search).has('diagnostics'), samples=[]; let lastSequence=null, failures=0, duplicates=0;
    document.getElementById('diagnostics').hidden=!diagnostic;
    let totals; function resetTotals(){totals={frames:0,first:null,last:null,maxGapMs:0,gapsOver100ms:0,gapsOver250ms:0,slowFrames:[]};} resetTotals();
    if(diagnostic)document.addEventListener('visibilitychange',()=>{samples.length=0;lastSequence=null;failures=0;duplicates=0;resetTotals();});
    function presented(sequence,age,started,timing={}){const loaded=performance.now();if(!diagnostic)return;requestAnimationFrame(()=>{if(document.visibilityState!=='visible')return;if(sequence===lastSequence){duplicates++;return;}lastSequence=sequence;const at=Date.now();if(totals.last!==null){const gap=at-totals.last;totals.maxGapMs=Math.max(totals.maxGapMs,gap);if(gap>100)totals.gapsOver100ms++;if(gap>250)totals.gapsOver250ms++;if(gap>100){totals.slowFrames.push({at,gapMs:gap,frameAgeAtResponseMs:age,...timing,rafWaitMs:performance.now()-loaded});if(totals.slowFrames.length>120)totals.slowFrames.shift();}}totals.frames++;if(totals.first===null)totals.first=at;totals.last=at;samples.push({at,sequence,frameAgeAtResponseMs:age,requestToRafMs:performance.now()-started,...timing,rafWaitMs:performance.now()-loaded});if(samples.length>1800)samples.shift();});}
    // Bounded visual dispatch receipts; these are not raw device touch samples.
    const gestureLayer=document.getElementById('gestures');
    let gestureCursor=null,gestureTimer,gestureGeneration=0;
    function clearGestures(){gestureLayer.innerHTML='';}
    function gestureFits(e){return ['tap','double-tap','long-press','swipe','drag','pinch'].includes(e.kind)&&e.rotation===rotation&&Number.isFinite(e.aspect)&&Math.abs(e.aspect-screen.naturalWidth/screen.naturalHeight)<.005&&Array.isArray(e.paths)&&e.paths.length>0&&e.paths.length<=2&&e.paths.every(p=>Array.isArray(p)&&p.length===2&&p.every(v=>Array.isArray(v)&&v.length===2&&v.every(n=>Number.isFinite(n)&&n>=0&&n<=1)));}
    function showGestures(events){
      if(document.visibilityState!=='visible'||device.dataset.ready!=='true')return;
      const e=events.filter(gestureFits).at(-1);if(!e)return;
      const w=parseFloat(screen.style.width),h=parseFloat(screen.style.height);if(!(w>0&&h>0))return;
      // Compact visual receipts, not a replay of device timing. Move the same
      // neutral contact point; no arrows, trails or additional rendering surfaces.
      const duration={'tap':600,'double-tap':850,'long-press':1200,'swipe':900,'drag':1400,'pinch':1000}[e.kind];
      let content='';
      for(const [from,to] of e.paths){
        const x=from[0]*w,y=from[1]*h,dx=(to[0]-from[0])*w,dy=(to[1]-from[1])*h;
        content+='<g transform="translate('+x+' '+y+')"><g class="gesture-motion" style="--dx:'+dx+'px;--dy:'+dy+'px"><circle class="gesture-touch" cx="0" cy="0" r="14"/></g></g>';
      }
      gestureLayer.innerHTML='<svg xmlns="http://www.w3.org/2000/svg" class="gesture-'+e.kind+'" style="--gesture-duration:'+duration+'ms" viewBox="0 0 '+w+' '+h+'">'+content+'</svg>';
      clearTimeout(gestureTimer);gestureTimer=setTimeout(clearGestures,duration);
    }
    async function gestures(){
      const generation=gestureGeneration;
      if(document.visibilityState==='visible')try{
        const r=await fetch('gestures'+(gestureCursor===null?'':'?after='+gestureCursor),{cache:'no-store',signal:AbortSignal.timeout(1500)});if(!r.ok)throw Error();
        const data=await r.json();if(!Number.isSafeInteger(data.sequence)||!Array.isArray(data.events))throw Error();
        if(generation===gestureGeneration&&document.visibilityState==='visible'){
          if(gestureCursor!==null)showGestures(data.events);gestureCursor=data.sequence;
        }
      }catch{if(generation===gestureGeneration){gestureCursor=null;clearGestures();}}
      setTimeout(gestures,document.visibilityState==='visible'?200:1000);
    }
    document.addEventListener('visibilitychange',()=>{gestureGeneration++;gestureCursor=null;clearGestures();});
    let sequence = -1;
    async function frames(){const started=performance.now();let retry=0;try{const r=await fetch('frame?after='+sequence,{cache:'no-store',signal:AbortSignal.timeout(3000)});if(!r.ok)throw Error();sequence=Number(r.headers.get('X-Preview-Sequence'));const frameRotation=r.headers.get('X-Preview-Rotation');const age=Number(r.headers.get('X-Preview-Frame-Age-Ms')),encodeMs=Number(r.headers.get('X-Preview-Encode-Ms')),next=URL.createObjectURL(await r.blob()),received=performance.now();const loaded=new Promise((resolve,reject)=>{screen.onload=resolve;screen.onerror=reject;});screen.src=next;try{await loaded;rotation=frameRotation||rotation;device.dataset.ready='true';lastFrameAt=Date.now();layout();presented(sequence,age,started,{requestMs:received-started,imageLoadMs:performance.now()-received,encodeMs});screen.style.opacity=1;}finally{if(objectURL)URL.revokeObjectURL(objectURL);objectURL=next;}}catch{failures++;screen.style.opacity=.25;retry=100;}setTimeout(frames,retry);}
    async function health(){try{const r=await fetch('state',{cache:'no-store',signal:AbortSignal.timeout(3000)});if(!r.ok)throw Error();const s=await r.json();setDevice(s);if(s.error||!s.mediaHealthy){showState(s.error?text.unavailable+': '+s.error:text.unavailable,'error');screen.style.opacity=.25;}else if(s.frameAgeSeconds==null){showState(text.firstFrame,'waiting');}else if(s.frameAgeSeconds>2){showState(text.waiting,'waiting');}else if(!lastFrameAt||Date.now()-lastFrameAt>4000){showState(text.recovering,'waiting');}else{showState(text.live,'live');}}catch{showState(text.disconnected,'error');screen.style.opacity=.25;}setTimeout(health,1000);}
    frames();health();gestures();
    if(diagnostic)setInterval(()=>{const gaps=samples.slice(1).map((s,i)=>s.at-samples[i].at).sort((a,b)=>a-b), span=samples.length>1?samples.at(-1).at-samples[0].at:0;const m=document.getElementById('metrics');m.textContent=JSON.stringify({total:{...totals,fps:totals.last>totals.first?(totals.frames-1)*1000/(totals.last-totals.first):0},visibleNewFrames:samples.length,fps:span?(samples.length-1)*1000/span:0,lastNewFrameAgeMs:samples.length?Date.now()-samples.at(-1).at:null,gapP95Ms:gaps[Math.floor(gaps.length*.95)]||0,maxGapMs:gaps.at(-1)||0,gapsOver250ms:gaps.filter(x=>x>250).length,failures,duplicates,note:text.metricsNote},null,2);m.dataset.samples=JSON.stringify(samples);},1000);
        </script></body></html>
    """
}
