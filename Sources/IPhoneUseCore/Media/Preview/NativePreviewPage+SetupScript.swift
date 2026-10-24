extension NativePreviewPage {
    static let setupScript = """
        <script>

        let objectURL, screen=document.getElementById('screen'); const state=document.getElementById('state');
        const device=document.getElementById('device'), stage=document.getElementById('stage'),\
         bezel=document.getElementById('bezel');
        const deviceName=document.getElementById('device-name'), shell=document.getElementById('shell'),\
         hardware=document.getElementById('hardware');
        const cutout=document.getElementById('cutout'), speaker=document.getElementById('speaker');
        const connection=document.getElementById('connection');
        const appearanceToggle=document.getElementById('appearance-toggle');
        const appearanceComparisonEnabled=\(appearanceComparisonEnabled ? "true" : "false");
        const identity=document.getElementById('identity');
        // Use the primary browser language, not any secondary preference in its list.
        const language=navigator.languages?.[0]||navigator.language||'en';
        const chinese=/^zh(?:-|$)/i.test(language);
        const text=chinese?{
          title:'iPhone-use · 实时预览',connecting:'正在连接…',drawn:'切换自绘外观'\
        ,official:'切换官方外观',
          screen:'iPhone 实时画面',placeholder:'等待手机画面'\
        ,diagnostics:'浏览器显示统计（最近 1800 帧）',
          unavailable:'连接不可用',firstFrame:'等待首帧',waiting:'已连接 · 等待新画面'\
        ,recovering:'正在恢复画面…',
          live:'实时画面',disconnected:'预览已停止或连接断开',
          authorization:'在 iPhone 上授权',
          runnerStarting:'正在等待 iPhone 就绪',
          authorized:'授权已完成，正在连接',
          authorizationUnknown:'请检查 iPhone 上的认证状态',
          metricsNote:'图片解码完成后的 rAF\
         绘制机会；页面可见性变化时重置；不代表物理屏幕呈现时间或端到端延迟'
        }:{
          title:'iPhone-use · Live preview',connecting:'Connecting…',drawn:'Use drawn frame',official:'Use\
         official frame',
          screen:'Live iPhone screen',placeholder:'Waiting for iPhone screen',diagnostics:'Browser display\
         metrics (last 1,800 frames)',
          unavailable:'Connection unavailable',firstFrame:'Waiting for first frame',waiting:'Connected ·\
         Waiting for a new frame',recovering:'Recovering preview…',
          live:'Live preview',disconnected:'Preview stopped or disconnected',
          authorization:'Authorize on your iPhone',
          runnerStarting:'Waiting for your iPhone',
          authorized:'Authorized · Connecting',
          authorizationUnknown:'Check authentication on your iPhone',
          metricsNote:'Image decode + rAF opportunity; resets on visibility change; not physical display or\
         glass-to-glass latency'
        };
        document.documentElement.lang=chinese?'zh-CN':'en';document.title=text.title;screen.alt=text.screen;
        document.getElementById('placeholder-label').textContent=text.placeholder;
        document.getElementById('diagnostics-label').textContent=text.diagnostics;
        function labelButton(button,label){button.title=label;button.setAttribute('aria-label',label);}
        showState(text.connecting,'waiting');
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
          "iPhone12,5":["iPhone 11 Pro Max",1242,2688,25.79,37.07,"notch",{"cutout":[98.72,0.0,202.25,28.36\
        ,20.95,4.83],"camera":[241.58,9.35,10.99],"speaker":[176.95,5.48,45.77,8.06]},"polished",false],
          "iPhone12,3":["iPhone 11 Pro",1125,2436,28.85,40.96,"notch",{"cutout":[88.25,0.0,223.51,31.34,22.97\
        ,5.34],"camera":[246.3,9.62,12.15],"speaker":[174.89,5.34,50.58,8.9]},"polished",false],
          "iPhone12,1":["iPhone 11",828,1792,34.87,39.71,"notch",{"cutout":[88.18,0.0,223.64,31.48,25.42,4.6]\
        ,"camera":[244.31,6.3,12.01],"speaker":[176.76,3.39,45.52,6.3]},"satin",false],
          "iPhone13,4":["iPhone 12 Pro Max",1284,2778,20.28,48.99,"notch",{"cutout":[101.8,0.0,196.4,29.64\
        ,21.68,4.52],"camera":[240.25,10.61,12.09],"speaker":[177.54,7.8,44.93,7.8]},"polished",false],
          "iPhone13,3":["iPhone 12 Pro",1170,2532,21.54,49.57,"notch",{"cutout":[92.13,0.0,215.74,32.82,23.25\
        ,6.32],"camera":[244.62,12.31,12.72],"speaker":[175.73,8.21,45.81,7.86]},"polished",false],
          "iPhone13,1":["iPhone 12 mini",1080,2340,23.15,46.3,"notch",{"cutout":[78.87,0.0,242.25,36.33,26.36\
        ,6.23],"camera":[249.51,14.6,14.35],"speaker":[172.75,10.33,52.0,8.19]},"satin",false],
          "iPhone13,2":["iPhone 12",1170,2532,21.54,49.57,"notch",{"cutout":[92.17,0.0,215.67,32.82,23.08\
        ,6.32],"camera":[244.79,12.31,13.25],"speaker":[175.73,8.55,48.55,8.21]},"satin",false],
          "iPhone14,3":["iPhone 13 Pro Max",1284,2778,19.31,50.16,"notch",{"cutout":[124.52,0.0,150.96,31.46\
        ,21.81,5.3],"camera":[145.64,10.44,11.59],"speaker":[168.54,-11.84,62.93,4.67]},"polished",false],
          "iPhone14,2":["iPhone 13 Pro",1170,2532,21.54,48.89,"notch",{"cutout":[117.03,0.0,165.94,34.53,23.93\
        ,5.81],"camera":[140.17,11.11,13.25],"speaker":[165.47,-13.33,69.06,5.13]},"polished",false],
          "iPhone14,4":["iPhone 13 mini",1080,2340,22.59,47.78,"notch",{"cutout":[107.14,0.0,185.73,40.0,26.48\
        ,6.85],"camera":[132.96,13.7,14.35],"speaker":[161.48,-13.7,77.04,5.93]},"satin",false],
          "iPhone14,5":["iPhone 13",1170,2532,21.54,48.89,"notch",{"cutout":[117.03,0.0,165.94,34.53,23.93\
        ,5.81],"camera":[140.17,11.11,13.25],"speaker":[165.47,-13.33,69.06,5.47]},"satin",false],
          "iPhone14,8":["iPhone 14 Plus",1284,2778,19.31,49.53,"notch",{"cutout":[124.51,0.0,150.67,31.15\
        ,21.34,4.98],"camera":[145.79,9.97,14.97],"speaker":[168.85,-12.46,62.62,4.98]},"satin",false],
          "iPhone15,3":["iPhone 14 Pro Max",1290,2796,17.36,51.47,"island",{"cutout":[141.71,10.54,116.59\
        ,34.11,17.05,0.0],"camera":[240.93,27.44,15.38],"speaker":[158,-10,84,1.4]},"polished",false],
          "iPhone15,2":["iPhone 14 Pro",1179,2556,19.68,56.32,"island",{"cutout":[136.39,11.54,127.23,37.32\
        ,18.66,0.0],"camera":[244.95,30.03,16.83],"speaker":[158,-10,84,1.4]},"polished",false],
          "iPhone14,7":["iPhone 14",1170,2532,21.2,49.23,"notch",{"cutout":[117.13,0.0,165.73,34.53,23.59,6.5]\
        ,"camera":[140.0,11.45,16.96],"speaker":[165.47,-13.33,69.06,5.47]},"satin",false],
          "iPhone15,5":["iPhone 15 Plus",1290,2796,18.29,51.47,"island",{"cutout":[141.71,10.54,116.59,34.11\
        ,17.05,0.0],"camera":[240.93,27.44,15.38],"speaker":[158,-10,84,1.4]},"satin",false],
          "iPhone16,2":["iPhone 15 Pro Max",1290,2796,15.19,51.47,"island",{"cutout":[141.71,10.54,116.59\
        ,34.11,17.05,0.0],"camera":[240.93,27.44,15.38],"speaker":[158,-7,84,1.4]},"satin",false],
          "iPhone16,1":["iPhone 15 Pro",1179,2556,17.3,56.32,"island",{"cutout":[136.39,11.54,127.23,37.32\
        ,18.66,0.0],"camera":[244.61,30.03,16.83],"speaker":[158,-7,84,1.4]},"satin",false],
          "iPhone15,4":["iPhone 15",1179,2556,20.02,56.32,"island",{"cutout":[136.39,11.54,127.23,37.32,18.66\
        ,0.0],"camera":[244.95,30.03,16.83],"speaker":[158,-10,84,1.4]},"satin",false],
          "iPhone17,4":["iPhone 16 Plus",1290,2796,18.29,51.47,"island",{"cutout":[141.71,10.54,116.59,34.11\
        ,17.05,0.0],"camera":[240.93,27.6,14.9],"speaker":[158,-7,84,1.4]},"satin",true],
          "iPhone17,2":["iPhone 16 Pro Max",1320,2868,13.33,57.27,"island",{"cutout":[143.33,13.03,113.33\
        ,32.73,16.36,0.0],"camera":[240.45,29.24,15.03],"speaker":[158,-7,84,1.4]},"satin",true],
          "iPhone17,1":["iPhone 16 Pro",1206,2622,14.26,62.69,"island",{"cutout":[137.98,14.26,124.05,35.49\
        ,17.74,0.0],"camera":[244.11,32.01,16.45],"speaker":[158,-7,84,1.4]},"satin",true],
          "iPhone17,3":["iPhone 16",1179,2556,20.02,56.32,"island",{"cutout":[136.39,11.54,127.23,37.32,18.66\
        ,0.0],"camera":[244.95,30.03,16.83],"speaker":[158,-7,84,1.4]},"satin",true],
          "iPhone17,5":["iPhone 16e",1170,2532,21.49,48.55,"notch",{"cutout":[117.03,0,165.93,34.56,23.04\
        ,5.08],"camera":[140.57,11.75,14.87],"speaker":[162.99,-12.95,74.02,3.72]},"satin",false],
          "iPhone18,5":["iPhone 17e",1170,2532,21.49,48.55,"notch",{"cutout":[117.03,0,165.93,34.56,23.04\
        ,5.08],"camera":[140.57,11.75,14.87],"speaker":[162.99,-12.95,74.02,3.72]},"satin",false],
          "iPhone18,1":["iPhone 17 Pro",1206,2622,15.86,61.69,"island",{"cutout":[137.63,13.91,124.74,36.47\
        ,18.24,0],"camera":[244.13,32.15,16.82],"speaker":[156.56,-13.16,86.89,1.8]},"satin",true],
          "iPhone18,2":["iPhone 17 Pro Max",1320,2868,14.05,56.36,"island",{"cutout":[143.01,12.71,113.97\
        ,33.32,16.66,0],"camera":[240.32,29.37,15.37],"speaker":[160.31,-11.58,79.39,1.65]},"satin",true],
          "iPhone18,3":["iPhone 17",1206,2622,14.66,61.69,"island",{"cutout":[137.69,13.91,124.62,36.47,18.24\
        ,0],"camera":[244.07,32.15,16.82],"speaker":[156.56,-11.96,86.89,1.8]},"satin",true],
          "iPhone18,4":["iPhone Air",1260,2736,14.84,59.05,"island",{"cutout":[140.3,19.01,119.4,34.91,17.46\
        ,0],"camera":[242.24,36.46,16.1],"speaker":[158.42,-12.25,83.16,1.73]},"polished",false],
          "iPhone19,2":["iPhone 18 Pro",1206,2622,15.86,61.69,"island",{"cutout":[152.95,13.91,94.1,36.47\
        ,18.24,0],"camera":[228.81,32.15,16.82],"speaker":[156.56,-13.16,86.89,1.8]},"satin",true],
          "iPhone19,3":["iPhone 18 Pro Max",1320,2868,14.05,56.36,"island",{"cutout":[156.96,12.71,86.08,33.32\
        ,16.66,0],"camera":[226.38,29.37,15.37],"speaker":[160.31,-11.58,79.39,1.65]},"satin",true],
          "iPhone19,7":["iPhone 18 Pro Max",1320,2868,14.05,56.36,"island",{"cutout":[156.96,12.71,86.08,33.32\
        ,16.66,0],"camera":[226.38,29.37,15.37],"speaker":[160.31,-11.58,79.39,1.65]},"satin",true]
        };
        """
}
