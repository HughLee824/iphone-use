import Foundation

private final class NativePreviewAssetAnchor: NSObject {}

// Artwork is loaded once, outside the video encoder. No network fetch, source
// path embedded in the binary, or dependency on the caller's working directory.
enum NativePreviewPage {
    static func assetDirectory(executable: URL? = Bundle(for: NativePreviewAssetAnchor.self).executableURL) -> URL? {
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

    // Byte-for-byte copy of assets/brand/favicon-64.png, embedded for relocatable/offline previews.
    static let faviconPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAACXBIWXMAACxLAAAsSwGlPZapAAADBUlEQVRoge2aMU/qUBTH+Ral9A1icCCyaAuExMWJyRg/gYaErYsgkcUokjCU/RJGYTAhUpPOBJqYOOnAwNSFvZSWAIJK6EseyU3zfEItXMt99rdyzj/nV24bSI9LxxyXjjkuHXNc+k8WkGW5UqlwHHdtCY7jKpVKp9OxQUCW5UQi4fF4iKXxeDzJZNKyhhUBSZIYhiFWCsMwkiR9h4CmaaFQiEBAOBxWVRW5wMXFBYGMq6srtAIvLy8bGxsL5zg5OeF5XjDA8/zx8fHCRq/XOxqNEArU63UzF7LX633sVVXVTK8oiggFSqWSmSFKpdJkMjE2TiaTm5sbM73lchmhAACAQAwAwBH4HOcbWAxwjtA8nCO0GOAcoXk4R+h/OUK//oCrAMuy4/F4NBqxLIulAPz3KMsyfgKbm5swbTwe4ydA0zRM0zQNP4FoNArTJEnCTyAWi8E0URTxEygUCjCtWCziJ/D8/AzT8HuM+ny+9/d3mEbTNGYC5+fn8+9gYs0FWq0WjMrlcpgJHB4ewpy3t7dAIICTgNvtfnp6gjmCIHxWCdZT4PT01JhzcHCAk0AgEJBlGYbc39/PKQbrJkBR1OPjI0wYDoe7u7s4Cdze3hoTstns/HqwPgJut7tYLBrba7UaSZJ4CFAUVa1Wjb2SJG1tbS1sBOsgwDCM8dzrut7tdiORiJleYLtAMpns9/vGLk3TotGomekJGwVIkozH481m86+Wdru9t7dncnrCFgGSJFOpVLvd/ljfaDT8fr/56QlbBDiO+1g5GAysvc8E3y/w8PBgrJlOp4Ig7OzsWJiesEUgnU7PPn19feV5fn9/39rodt7ER0dHLMtub28TSwNsf4w6AsD+F93LUEb6otvkqsEyiEhXDUwue1jGi3rZQ9f1y8tLdAKZTOar83xZQFXVcDiMYvpIJPLPNZcVC8x+2QeDwdVOHwqFvmnlbIaiKGdnZytZ+qMoKpVKdbtdG9YuFUW5u7vL5/PW1i7z+Xy1WlUUZZkZfvbi6zrg0jHHZfcAy/Ib2Fmu6PHCFAAAAAAASUVORK5CYII=")!

    static let html = """
    <!doctype html>
    <html lang="zh-CN">
    <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <link rel="icon" type="image/png" sizes="64x64" href="favicon.png">
    <meta name="color-scheme" content="light dark"><title>iPhone-use · 实时预览</title>
    <style>
    *{box-sizing:border-box} [hidden]{display:none!important}
    :root{color-scheme:light dark;--bg:#e5e9ef;--stage-center:#f8f9fb;--stage-mid:#edf0f4;--text:#242933;--muted:#596373;--secondary:#465263;--line:#1d2c401c;--header:#f5f7fabd;--button:#ffffff8c;--hover:#ffffff;--button-line:#263a542e;--accent:#4c5893;--focus:#405dc0;--live:#287750;--waiting:#94601d;--error:#b63b35;--shadow:#1e304329;font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:var(--text);background:var(--bg)}
    @media(prefers-color-scheme:dark){:root{--bg:#111215;--stage-center:#25282e;--stage-mid:#17191e;--text:#eceef2;--muted:#9ba3b0;--secondary:#b6bdc8;--line:#ffffff0d;--header:#111215a6;--button:#ffffff05;--hover:#ffffff10;--button-line:#ffffff1a;--accent:#c4caff;--focus:#adbcff;--live:#86d1ac;--waiting:#d2a564;--error:#ef9a91;--shadow:#0005}}
    body{margin:0}button{font:inherit;color:inherit;cursor:pointer}button:focus-visible,summary:focus-visible{outline:2px solid var(--focus);outline-offset:4px}
    button:disabled{opacity:.4;cursor:default}
    .viewer{height:100dvh;min-height:440px;display:flex;flex-direction:column;background:radial-gradient(ellipse at 50% 45%,var(--stage-center) 0%,var(--stage-mid) 48%,var(--bg) 100%)}
    header{flex:none;min-height:76px;display:flex;align-items:center;justify-content:space-between;gap:20px;padding:18px 28px;border-bottom:1px solid var(--line);background:var(--header)}
    .brand{display:flex;align-items:center;gap:11px;min-width:0}.brand>div{min-width:0}.mark{width:28px;height:28px;color:var(--accent)}h1{margin:0;font-size:16px;font-weight:620;letter-spacing:-.4px}#device-name{margin-top:3px;font-size:12px;color:var(--secondary);max-width:240px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .toolbar{display:flex;align-items:center;gap:12px}
    #appearance-toggle{height:34px;padding:0 10px;border:1px solid var(--button-line);border-radius:8px;background:var(--button);font-size:12px;white-space:nowrap}#appearance-toggle:hover{background:var(--hover)}
    #fullscreen{width:34px;height:34px;display:grid;place-items:center;border:1px solid var(--button-line);border-radius:8px;background:var(--button)}#fullscreen:hover{background:var(--hover)}svg{display:block}
    .connection{display:flex;align-items:center;gap:8px;color:var(--secondary);font-size:12px;min-height:18px}.dot{width:6px;height:6px;border-radius:50%;background:var(--waiting);flex:none}
    .connection[data-kind="live"] .dot{background:var(--live)}.connection[data-kind="error"] .dot{background:var(--error)}
    #state{max-width:38vw;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    main{min-height:0;flex:1;display:flex;flex-direction:column;align-items:center}
    #stage{position:relative;width:100%;flex:1;min-height:0;display:grid;place-items:center;overflow:hidden}
    #device{position:relative;flex:none}#screen{position:absolute;z-index:1;display:block;object-fit:contain;background:#08090b;visibility:hidden}
    #device[data-ready="true"] #screen{visibility:visible}
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
    @media(max-width:700px){header{padding:14px 18px;gap:12px;flex-wrap:wrap}.brand{flex:1}.connection{order:3;width:100%}#state{max-width:90vw}.toolbar{gap:8px}}
    @media(max-height:550px) and (min-width:701px){header{min-height:54px;padding:10px 24px}}
    </style></head>
    <body><div class="viewer" id="viewer">
    <header><div class="brand"><svg class="mark" viewBox="0 0 28 28" fill="none" aria-hidden="true"><rect x="7" y="2" width="14" height="24" rx="4" stroke="currentColor" stroke-width="1.5"/><path d="M12 5h4M12 23h4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg><div><h1>iPhone-use</h1><div id="device-name">iPhone</div></div></div>
    <div class="connection" id="connection" data-kind="waiting" role="status"><span class="dot" aria-hidden="true"></span><span id="state">正在连接…</span></div>
    <div class="toolbar"><button id="appearance-toggle" hidden title="临时外观对比，仅影响本页显示">切换自绘外观</button><button id="fullscreen" title="进入全屏" aria-label="进入全屏"><svg width="16" height="16" viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M7 3H3v4m10-4h4v4M3 13v4h4m10-4v4h-4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg></button></div></header>
    <main><div id="stage"><div id="device" data-ready="false"><div id="shell" hidden aria-hidden="true"><i class="side-key action-key"></i><i class="side-key volume-up"></i><i class="side-key volume-down"></i><i class="side-key power-key"></i><i class="side-key camera-key"></i><i class="antenna a"></i><i class="antenna b"></i><i class="antenna c"></i><i class="antenna d"></i></div><div id="hardware" hidden aria-hidden="true"><i id="speaker"></i><i id="cutout" hidden></i></div><img id="screen" alt="iPhone 实时画面" draggable="false"><div id="placeholder"><svg width="32" height="44" viewBox="0 0 32 44" fill="none" aria-hidden="true"><rect x="4" y="2" width="24" height="40" rx="6" stroke="currentColor" stroke-width="1.5"/><path d="M13 6h6M13 38h6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg><span>等待手机画面</span></div><img id="bezel" hidden alt="" aria-hidden="true" draggable="false"></div></div>
    </main>
    </div><details id="diagnostics" hidden><summary>浏览器显示统计（最近 1800 帧）</summary><pre id="metrics"></pre></details>
    <script>

    let objectURL; const screen=document.getElementById('screen'), state=document.getElementById('state');
    const device=document.getElementById('device'), stage=document.getElementById('stage'), bezel=document.getElementById('bezel');
    const deviceName=document.getElementById('device-name'), shell=document.getElementById('shell'), hardware=document.getElementById('hardware');
    const cutout=document.getElementById('cutout'), speaker=document.getElementById('speaker');
    const connection=document.getElementById('connection'), fullscreen=document.getElementById('fullscreen');
    const appearanceToggle=document.getElementById('appearance-toggle');
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
    function layout(){
      const model=Object.hasOwn(drawnModels,connectedDevice.productType)?drawnModels[connectedDevice.productType]:null;
      const w=screen.naturalWidth||profile?.screenWidth||model?.[1]||390, h=screen.naturalHeight||profile?.screenHeight||model?.[2]||844, landscape=w>h;
      const ratio=Math.min(w,h)/Math.max(w,h);
      const canShowOfficial=Boolean(artworkAvailable&&profile&&Math.abs(ratio-profile.screenWidth/profile.screenHeight)<.002&&rotation!=='rot180');
      const official=canShowOfficial&&!forceDrawing;
      const exact=model&&Math.abs(ratio-model[1]/model[2])<.002;
      const name=profile?.name||model?.[0]||connectedDevice.name||connectedDevice.productType||'iPhone';
      const key=[w,h,rotation,artworkAvailable,forceDrawing,identityKey,stage.clientWidth,stage.clientHeight].join(':');
      if(key===layoutKey)return;layoutKey=key;
      appearanceToggle.hidden=!canShowOfficial;
      appearanceToggle.textContent=forceDrawing?'切换官方外观':'切换自绘外观';
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
      const screenScale=Math.max(0,Math.min((stage.clientWidth-40)/(landscape?fitHeight:fitWidth),(stage.clientHeight-32)/(landscape?fitWidth:fitHeight)));
      const scale=screenScale/p.screenWidth;
      device.style.width=width*scale+'px';device.style.height=height*scale+'px';
      device.style.transform='translate('+((width-sw)/2-x)*scale+'px,'+((height-sh)/2-y)*scale+'px)';
      device.dataset.appearance=official?'official':exact?'drawn':'generic';
      screen.style.left=x*scale+'px';screen.style.top=y*scale+'px';
      screen.style.width=sw*scale+'px';screen.style.height=sh*scale+'px';
      screen.style.borderRadius=p.cornerRadius*scale+'px';
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
      deviceName.textContent=name;
    }
    appearanceToggle.addEventListener('click',()=>{forceDrawing=!forceDrawing;layout();});
    bezel.addEventListener('error',()=>{artworkAvailable=false;layout();});
    new ResizeObserver(layout).observe(stage);layout();
    fullscreen.hidden=!document.fullscreenEnabled;
    fullscreen.addEventListener('click',async()=>{try{if(document.fullscreenElement)await document.exitFullscreen();else await document.getElementById('viewer').requestFullscreen();}catch{fullscreen.title='浏览器未允许全屏';}});
    document.addEventListener('fullscreenchange',()=>{const label=document.fullscreenElement?'退出全屏':'进入全屏';fullscreen.title=label;fullscreen.setAttribute('aria-label',label);});
    function showState(text,kind){state.textContent=text;state.title=text;connection.dataset.kind=kind;}
    const diagnostic=new URLSearchParams(location.search).has('diagnostics'), samples=[]; let lastSequence=null, failures=0, duplicates=0;
    document.getElementById('diagnostics').hidden=!diagnostic;
    let totals; function resetTotals(){totals={frames:0,first:null,last:null,maxGapMs:0,gapsOver100ms:0,gapsOver250ms:0,slowFrames:[]};} resetTotals();
    if(diagnostic)document.addEventListener('visibilitychange',()=>{samples.length=0;lastSequence=null;failures=0;duplicates=0;resetTotals();});
    function presented(sequence,age,started,timing={}){const loaded=performance.now();if(!diagnostic)return;requestAnimationFrame(()=>{if(document.visibilityState!=='visible')return;if(sequence===lastSequence){duplicates++;return;}lastSequence=sequence;const at=Date.now();if(totals.last!==null){const gap=at-totals.last;totals.maxGapMs=Math.max(totals.maxGapMs,gap);if(gap>100)totals.gapsOver100ms++;if(gap>250)totals.gapsOver250ms++;if(gap>100){totals.slowFrames.push({at,gapMs:gap,frameAgeAtResponseMs:age,...timing,rafWaitMs:performance.now()-loaded});if(totals.slowFrames.length>120)totals.slowFrames.shift();}}totals.frames++;if(totals.first===null)totals.first=at;totals.last=at;samples.push({at,sequence,frameAgeAtResponseMs:age,requestToRafMs:performance.now()-started,...timing,rafWaitMs:performance.now()-loaded});if(samples.length>1800)samples.shift();});}
    let sequence = -1;
    async function frames(){const started=performance.now();let retry=0;try{const r=await fetch('frame?after='+sequence,{cache:'no-store',signal:AbortSignal.timeout(3000)});if(!r.ok)throw Error();sequence=Number(r.headers.get('X-Preview-Sequence'));const frameRotation=r.headers.get('X-Preview-Rotation');const age=Number(r.headers.get('X-Preview-Frame-Age-Ms')),encodeMs=Number(r.headers.get('X-Preview-Encode-Ms')),next=URL.createObjectURL(await r.blob()),received=performance.now();const loaded=new Promise((resolve,reject)=>{screen.onload=resolve;screen.onerror=reject;});screen.src=next;try{await loaded;rotation=frameRotation||rotation;device.dataset.ready='true';lastFrameAt=Date.now();layout();presented(sequence,age,started,{requestMs:received-started,imageLoadMs:performance.now()-received,encodeMs});screen.style.opacity=1;}finally{if(objectURL)URL.revokeObjectURL(objectURL);objectURL=next;}}catch{failures++;screen.style.opacity=.25;retry=100;}setTimeout(frames,retry);}
    async function health(){try{const r=await fetch('state',{cache:'no-store',signal:AbortSignal.timeout(3000)});if(!r.ok)throw Error();const s=await r.json();setDevice(s);if(s.error||!s.mediaHealthy){showState(s.error||'连接不可用','error');screen.style.opacity=.25;}else if(s.frameAgeSeconds==null){showState('等待首帧','waiting');}else if(s.frameAgeSeconds>2){showState('已连接 · 等待新画面','waiting');}else if(!lastFrameAt||Date.now()-lastFrameAt>4000){showState('正在恢复画面…','waiting');}else{showState('实时画面','live');}}catch{showState('预览已停止或连接断开','error');screen.style.opacity=.25;}setTimeout(health,1000);}
    frames();health();
    if(diagnostic)setInterval(()=>{const gaps=samples.slice(1).map((s,i)=>s.at-samples[i].at).sort((a,b)=>a-b), span=samples.length>1?samples.at(-1).at-samples[0].at:0;const m=document.getElementById('metrics');m.textContent=JSON.stringify({total:{...totals,fps:totals.last>totals.first?(totals.frames-1)*1000/(totals.last-totals.first):0},visibleNewFrames:samples.length,fps:span?(samples.length-1)*1000/span:0,lastNewFrameAgeMs:samples.length?Date.now()-samples.at(-1).at:null,gapP95Ms:gaps[Math.floor(gaps.length*.95)]||0,maxGapMs:gaps.at(-1)||0,gapsOver250ms:gaps.filter(x=>x>250).length,failures,duplicates,note:'Image load + rAF opportunity; resets on visibility change; not physical display or glass-to-glass latency'},null,2);m.dataset.samples=JSON.stringify(samples);},1000);
        </script></body></html>
    """
}
