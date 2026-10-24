extension NativePreviewPage {
    static let interactionScript = """
        function showState(text,kind){state.textContent=text;connection.title=text;connection.dataset.kind=kind;}
        const diagnostic=new URLSearchParams(location.search).has('diagnostics'), samples=[]; let\
         lastSequence=null, failures=0, duplicates=0;
        document.getElementById('diagnostics').hidden=!diagnostic;
        // Diagnostic-only, bounded main-thread evidence. Durations include
        // scheduling delays; neither decodeWaitMs nor rAF proves physical display.
        const longTasks=[];
        if(diagnostic&&typeof\
         PerformanceObserver!=='undefined'&&PerformanceObserver.supportedEntryTypes?.includes('longtask')){
          new PerformanceObserver(list=>{
            for(const entry of list.getEntries())longTasks.push({at:performance.timeOrigin+entry.startTime\
        ,durationMs:entry.duration});
            if(longTasks.length>120)longTasks.splice(0,longTasks.length-120);
          }).observe({type:'longtask'});
        }
        let totals; function resetTotals(){totals={frames:0,first:null,last:null,maxGapMs:0,gapsOver100ms:0\
        ,gapsOver250ms:0,slowFrames:[]};} resetTotals();
        if(diagnostic)document.addEventListener('visibilitychange',()=>{samples.length=0;longTasks.length=0\
        ;lastSequence=null;failures=0;duplicates=0;resetTotals();});
        function presented(sequence,age,started,timing={}){const loaded=performance.now()\
        ;if(!diagnostic)return;requestAnimationFrame(()=>{if(document.visibilityState!=='visible')return\
        ;if(sequence===lastSequence){duplicates++;return;}lastSequence=sequence;const at=Date.now()\
        ;if(totals.last!==null){const gap=at-totals.last;totals.maxGapMs=Math.max(totals.maxGapMs,gap)\
        ;if(gap>100)totals.gapsOver100ms++;if(gap>250)totals.gapsOver250ms++\
        ;if(gap>100){totals.slowFrames.push({at,gapMs:gap,frameAgeAtResponseMs:age,...timing\
        ,rafWaitMs:performance.now()-loaded});if(totals.slowFrames.length>120)totals.slowFrames.shift()\
        ;}}totals.frames++;if(totals.first===null)totals.first=at;totals.last=at;samples.push({at,sequence\
        ,frameAgeAtResponseMs:age,requestToRafMs:performance.now()-started,...timing\
        ,rafWaitMs:performance.now()-loaded});if(samples.length>1800)samples.shift();});}
        // Bounded visual dispatch receipts; these are not raw device touch samples.
        const gestureLayer=document.getElementById('gestures');
        let gestureCursor=null,gestureTimer,gestureGeneration=0;
        function clearGestures(){gestureLayer.innerHTML='';}
        function gestureFits(e){return ['tap','double-tap','long-press','swipe','drag'\
        ,'pinch'].includes(e.kind)&&e.rotation===rotation&&Number.isFinite(e.aspect)&&Math.abs(e.aspect-scree\
        n.naturalWidth/screen.naturalHeight)<.005&&Array.isArray(e.paths)&&e.paths.length>0&&e.paths.lengt\
        h<=2&&e.paths.every(p=>Array.isArray(p)&&p.length===2&&p.every(v=>Array.isArray(v)&&v.length===2&&v.e\
        very(n=>Number.isFinite(n)&&n>=0&&n<=1)));}
        function showGestures(events){
          if(document.visibilityState!=='visible'||device.dataset.ready!=='true')return;
          const e=events.filter(gestureFits).at(-1);if(!e)return;
          const w=parseFloat(screen.style.width),h=parseFloat(screen.style.height);if(!(w>0&&h>0))return;
          // Compact visual receipts, not a replay of device timing. Move the same
          // neutral contact point; no arrows, trails or additional rendering surfaces.
          const duration={'tap':600,'double-tap':850,'long-press':1200,'swipe':900,'drag':1400\
        ,'pinch':1000}[e.kind];
          let content='';
          for(const [from,to] of e.paths){
            const x=from[0]*w,y=from[1]*h,dx=(to[0]-from[0])*w,dy=(to[1]-from[1])*h;
            content+='<g transform="translate('+x+' '+y+')"><g class="gesture-motion" style="--dx:'+dx+'px\
        ;--dy:'+dy+'px"><circle class="gesture-touch" cx="0" cy="0" r="14"/></g></g>';
          }
          gestureLayer.innerHTML='<svg xmlns="http://www.w3.org/2000/svg" class="gesture-'+e.kind+'"\
         style="--gesture-duration:'+duration+'ms" viewBox="0 0 '+w+' '+h+'">'+content+'</svg>';
          clearTimeout(gestureTimer);gestureTimer=setTimeout(clearGestures,duration);
        }
        async function gestures(){
          const generation=gestureGeneration;let retry=0;
          if(document.visibilityState==='visible')try{
            const r=await fetch('gestures'+(gestureCursor===null?'':'?after='+gestureCursor),{cache:'no-store'\
        ,signal:AbortSignal.timeout(1500)});if(!r.ok)throw Error();
            const data=await r.json()\
        ;if(!Number.isSafeInteger(data.sequence)||!Array.isArray(data.events))throw Error();
            if(generation===gestureGeneration&&document.visibilityState==='visible'){
              if(gestureCursor!==null)showGestures(data.events);gestureCursor=data.sequence;
            }
          }catch{retry=200;if(generation===gestureGeneration){gestureCursor=null;clearGestures();}}
          // The server waits for dispatch; immediately renew the bounded long poll.
          setTimeout(gestures,document.visibilityState==='visible'?retry:1000);
        }
        document.addEventListener('visibilitychange',()=>{gestureGeneration++;gestureCursor=null\
        ;clearGestures();});
        """
}
