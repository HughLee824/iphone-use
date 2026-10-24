extension NativePreviewPage {
    static let layoutScript = """
        function setDevice(s){
          connectedDevice=s.device||{};profile=s.bezel||null;
          identityKey=JSON.stringify([connectedDevice,profile]);layout();
        }
        function fitPreview(width,height,ratioWidth,ratioHeight,captionHeight){
          const bottomInset=captionHeight+16;
          const scale=Math.max(0,Math.min((width-40)/ratioWidth,(height-40-bottomInset)/ratioHeight));
          return {scale,offsetY:-bottomInset/2,captionTop:(height-bottomInset+ratioHeight*scale)/2+16};
        }
        function layout(){
          const model=Object.hasOwn(drawnModels\
        ,connectedDevice.productType)?drawnModels[connectedDevice.productType]:null;
          const w=screen.naturalWidth||profile?.screenWidth||model?.[1]||390,\
         h=screen.naturalHeight||profile?.screenHeight||model?.[2]||844, landscape=w>h;
          const ratio=Math.min(w,h)/Math.max(w,h);
          const canShowOfficial=Boolean(artworkAvailable&&profile&&Math.abs(ratio-profile.screenWidth/profil\
        e.screenHeight)<.002&&rotation!=='rot180');
          const official=canShowOfficial&&!forceDrawing;
          const exact=model&&Math.abs(ratio-model[1]/model[2])<.002;
          const name=profile?.name||model?.[0]||connectedDevice.name||connectedDevice.productType||'iPhone';
          if(deviceName.textContent!==name){deviceName.textContent=name;deviceName.title=name;}
          const key=[w,h,rotation,artworkAvailable,forceDrawing,identityKey,stage.clientWidth\
        ,stage.clientHeight,identity.clientHeight].join(':');
          if(key===layoutKey)return;layoutKey=key;
          appearanceToggle.hidden=!appearanceComparisonEnabled||!canShowOfficial;
          labelButton(appearanceToggle,forceDrawing?text.official:text.drawn);
          const angle=landscape?(rotation==='rot90'?90:-90):(rotation==='rot180'?180:0);
          const rim=exact?model[3]:12, radius=exact?model[4]:32;
          const screenRatio=canShowOfficial?profile.screenWidth/profile.screenHeight:ratio;
          const drawing={canvasWidth:400+rim*2,canvasHeight:400/screenRatio+rim*2,screenX:rim,screenY:rim\
        ,screenWidth:400,screenHeight:400/screenRatio,cornerRadius:radius};
          const p=official?profile:drawing;
          // Fit both appearances against the same screen-centred envelope. PNG
          // transparent margins and independently drawn rims must not zoom the video.
          const candidates=canShowOfficial?[profile,drawing]:[p];
          const fitWidth=Math.max(...candidates.map(p=>(p.screenWidth+2*Math.max(p.screenX\
        ,p.canvasWidth-p.screenX-p.screenWidth))/p.screenWidth));
          const fitHeight=Math.max(...candidates.map(p=>(p.screenHeight+2*Math.max(p.screenY\
        ,p.canvasHeight-p.screenY-p.screenHeight))/p.screenWidth));
          const width=landscape?p.canvasHeight:p.canvasWidth,height=landscape?p.canvasWidth:p.canvasHeight;
          const sw=landscape?p.screenHeight:p.screenWidth,sh=landscape?p.screenWidth:p.screenHeight;
          const x=landscape?(angle===90?p.canvasHeight-p.screenY-p.screenHeight:p.screenY):p.screenX;
          const y=landscape?(angle===90?p.screenX:p.canvasWidth-p.screenX-p.screenWidth):p.screenY;
          const placement=fitPreview(stage.clientWidth,stage.clientHeight,landscape?fitHeight:fitWidth\
        ,landscape?fitWidth:fitHeight,identity.clientHeight);
          identity.style.top=placement.captionTop+'px';
          const screenScale=placement.scale;
          const scale=screenScale/p.screenWidth;
          device.style.width=width*scale+'px';device.style.height=height*scale+'px';
          device.style.transform='translate('+((width-sw)/2-x)*scale+'px\
        ,'+(((height-sh)/2-y)*scale+placement.offsetY)+'px)';
          device.dataset.appearance=official?'official':exact?'drawn':'generic';
          screen.style.left=x*scale+'px';screen.style.top=y*scale+'px';
          screen.style.width=sw*scale+'px';screen.style.height=sh*scale+'px';
          screen.style.borderRadius=p.cornerRadius*scale+'px';
          for(const id of ['gestures','notice','placeholder'])for(const property of ['left','top','width'\
        ,'height','borderRadius'])document.getElementById(id).style[property]=screen.style[property];
          document.getElementById('gestures').innerHTML='';
          bezel.hidden=!official;shell.hidden=official;hardware.hidden=official;
          const transform='translate(-50%,-50%) rotate('+angle+'deg)';
          if(official){
            if(!bezel.dataset.loaded){bezel.dataset.loaded='true';bezel.src='bezel';}
            bezel.style.width=p.canvasWidth*scale+'px';bezel.style.height=p.canvasHeight*scale+'px'\
        ;bezel.style.transform=transform;
          }else{
            for(const layer of [shell,hardware]){
              layer.style.width=p.canvasWidth*scale+'px';layer.style.height=p.canvasHeight*scale+'px';
              layer.style.fontSize=scale+'px';layer.style.transform=transform;
            }
            shell.style.setProperty('--outer-radius',(radius+rim)+'em');
            shell.dataset.finish=exact?model[7]:'satin';shell.dataset.generic=String(!exact)\
        ;shell.dataset.camera=String(Boolean(exact&&model[8]));
            cutout.hidden=!exact;speaker.hidden=!exact;
            if(exact){
              const sensor=model[6], [cx,cy,cw,ch,cr,shoulder]=sensor.cutout;
              cutout.dataset.shape=model[5];
              cutout.style.left=(rim+cx)+'em';cutout.style.top=(rim+cy)+'em';
              cutout.style.width=cw+'em';cutout.style.height=ch+'em';
              cutout.style.setProperty('--cutout-radius',cr+'em');cutout.style.setProperty('--shoulder'\
        ,shoulder+'em');
              cutout.style.setProperty('--camera-x',(sensor.camera[0]-cx)+'em');
              cutout.style.setProperty('--camera-y',(sensor.camera[1]-cy)+'em');
              cutout.style.setProperty('--camera-size',sensor.camera[2]+'em');
              const [sx,sy,sw,sh]=sensor.speaker;
              speaker.style.left=(rim+sx)+'em';speaker.style.top=(rim+sy)+'em';
              speaker.style.width=sw+'em';speaker.style.height=sh+'em';
            }
          }
        }
        appearanceToggle.addEventListener('click'\
        ,()=>{if(appearanceComparisonEnabled){forceDrawing=!forceDrawing;layout();}});
        bezel.addEventListener('error',()=>{artworkAvailable=false;layout();});
        const layoutObserver=new ResizeObserver(layout);
        for(const el of [stage,identity])layoutObserver.observe(el);layout();
        """
}
