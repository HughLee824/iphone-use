extension NativePreviewPage {
    static let streamScript = """
        let sequence = -1;
        // Decode off-DOM before replacing the visible image. Keep one displayed
        // frame and one candidate; a failed decode must retain the last good frame.
        async function displayFrame(blob,frameRotation){
          const nextURL=URL.createObjectURL(blob), next=screen.cloneNode(false);
          next.decoding='async';
          const decodeStarted=performance.now();
          try{
            next.src=nextURL;
            await next.decode();
            const decodeWaitMs=performance.now()-decodeStarted,layoutStarted=performance.now();
            const nextRotation=frameRotation||rotation;
            const geometryChanged=next.naturalWidth!==screen.naturalWidth||next.naturalHeight!==screen.natura\
        lHeight||nextRotation!==rotation;
            // Copy the current style after await: resize/health can change it while
            // decoding. Do not carry handlers or replace the gesture overlay.
            next.style.cssText=screen.style.cssText;next.style.opacity=1;
            screen.replaceWith(next);screen=next;rotation=nextRotation;
            if(device.dataset.ready!=='true')device.dataset.ready='true';
            lastFrameAt=Date.now();
            setScreenCovered(false);
            if(geometryChanged)layout();
            if(objectURL)URL.revokeObjectURL(objectURL);objectURL=nextURL;
            return {decodeWaitMs,layoutMs:performance.now()-layoutStarted};
          }catch(error){URL.revokeObjectURL(nextURL);throw error;}
        }
        async function frames(){
          const started=performance.now();let retry=0;
          try{
            const r=await fetch('frame?after='+sequence,{cache:'no-store',signal:AbortSignal.timeout(3000)});
            if(!r.ok)throw Error();
            sequence=Number(r.headers.get('X-Preview-Sequence'));
            const frameRotation=r.headers.get('X-Preview-Rotation');
            const age=Number(r.headers.get('X-Preview-Frame-Age-Ms'))\
        ,encodeMs=Number(r.headers.get('X-Preview-Encode-Ms'));
            const headersAt=performance.now(),blob=await r.blob(),received=performance.now();
            const timing=await displayFrame(blob,frameRotation);
            presented(sequence,age,started,{requestMs:received-started,bodyMs:received-headersAt,...timing\
        ,encodeMs});
          }catch{failures++;screen.style.opacity=.25;retry=100;}
          setTimeout(frames,retry);
        }
        function setScreenCovered(covered){
          document.getElementById('notice').hidden=!covered;
          device.dataset.notice=String(covered);
        }
        function renderHealth(s,newerFrame=false){
          setDevice(s);const c=s.connection;
          // Missing video never proves an authorization request. All unavailable
          // frames use the same blank cover; control guidance stays in the footer.
          const recentFrame=lastFrameAt&&Date.now()-lastFrameAt<=4000;
          const displayedFrame=lastFrameAt&&(recentFrame||s.frameAgeSeconds>2);
          const visibleMedia=(newerFrame&&recentFrame)||(!s.error&&s.mediaHealthy===true&&s.frameAgeSecond\
        s!=null&&displayedFrame);
          setScreenCovered(!visibleMedia);
          if(c?.reason==='ui_automation_authorization_required'&&c.requiresUserAction===true&&c.authorizatio\
        n==='required'&&c.monitorAvailable===true&&c.evidence==='device_log_exact_runner_pid'&&c.phase!=='failed'){
            showState(text.authorization,'waiting');return;
          }
          if(c?.authorization==='unverified'&&c.phase!=='failed'){
            showState(text.authorizationUnknown,'waiting');return;
          }
          if(c?.phase==='starting'){
            const authorized=c.authorization==='authenticated'||c.authorization==='enabled';
            showState(authorized?text.authorized:text.runnerStarting,'waiting');return;
          }
          if(c?.phase==='failed'||s.error||!s.mediaHealthy){
            showState(s.error?text.unavailable+': '+s.error:text.unavailable,'error');
          }else if(s.frameAgeSeconds==null){showState(text.firstFrame,'waiting');}
          else if(s.frameAgeSeconds>2){showState(text.waiting,'waiting');}
          else if(!recentFrame){showState(text.recovering,'waiting');}
          else{showState(text.live,'live');}
        }
        async function health(){
          const frameBeforeRequest=lastFrameAt;
          try{
            const r=await fetch('state',{cache:'no-store',signal:AbortSignal.timeout(3000)});if(!r.ok)throw\
         Error();
            const s=await r.json();
            // A slow status response must not cover a frame decoded since this request began.
            renderHealth(s,lastFrameAt!==frameBeforeRequest);
          }catch{
            showState(text.disconnected,'error');
            if(lastFrameAt===frameBeforeRequest)setScreenCovered(true);
          }
          setTimeout(health,1000);
        }
        frames();health();gestures();
        if(diagnostic)setInterval(()=>{const gaps=samples.slice(1).map((s,i)=>s.at-samples[i].at).sort((a\
        ,b)=>a-b), span=samples.length>1?samples.at(-1).at-samples[0].at:0;const\
         m=document.getElementById('metrics');m.textContent=JSON.stringify({longTasks,total:{...totals\
        ,fps:totals.last>totals.first?(totals.frames-1)*1000/(totals.last-totals.first):0}\
        ,visibleNewFrames:samples.length,fps:span?(samples.length-1)*1000/span:0\
        ,lastNewFrameAgeMs:samples.length?Date.now()-samples.at(-1).at:null\
        ,gapP95Ms:gaps[Math.floor(gaps.length*.95)]||0,maxGapMs:gaps.at(-1)||0\
        ,gapsOver250ms:gaps.filter(x=>x>250).length,failures,duplicates,note:text.metricsNote},null,2)\
        ;m.dataset.samples=JSON.stringify(samples);},1000);
            </script></body></html>
        """
}
