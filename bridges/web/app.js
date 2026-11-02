"use strict";
const $ = id => document.getElementById(id);
let config, phase="idle", webgazerReady=false, inferenceTimer, flushTimer, sceneTimer;
let calibrated=false, calibrationSize=null, sampleBuffer=[], validation=[], pointIndex=0, repetitions=0;
let validationStart=0, validationSamples=[], inferenceBusy=false, lastCapture=0;
let lastCalibrationClick=0;
const calibrationPoints = [[.12,.12],[.5,.12],[.88,.12],[.12,.5],[.5,.5],[.88,.5],[.12,.88],[.5,.88],[.88,.88]];
const validationPoints = [[.5,.5],[.2,.2],[.8,.2],[.8,.8],[.2,.8]];
async function post(path,data){
  const response=await fetch(path,{method:"POST",headers:{"Content-Type":"application/json","X-OcuDrive-Token":config.token},body:JSON.stringify(data)});
  if(!response.ok) throw new Error(`本機橋接回應 ${response.status}`);
  return response.json();
}
function status(message){$("status").textContent=message;}
async function fail(error){
  calibrated=false; phase="idle";$("stage").hidden=true;
  status(String(error.message||error));
  if(config) try{await post("/api/status",{state:"error",message:String(error.message||error)});}catch(_){}
  $("start").disabled=false; $("reset").disabled=!webgazerReady;
}
function loadScript(url){return new Promise((resolve,reject)=>{const script=document.createElement("script");script.src=url;script.onload=resolve;script.onerror=()=>reject(new Error("離線 WebGazer 資源未載入，請重新建立完整套件。"));document.head.appendChild(script);});}
function placePoint(){
  const point=(phase==="calibration"?calibrationPoints:validationPoints)[pointIndex];
  $("target").style.left=`${point[0]*100}%`;$("target").style.top=`${point[1]*100}%`;
  $("target").classList.toggle("validation",phase==="validation");
  $("target").disabled=phase==="validation";
  $("instruction").textContent=phase==="calibration"?`校正 ${pointIndex+1}/9：看著目標，確認 ${repetitions+1}/5`:`驗證 ${pointIndex+1}/5：看著目標，保持頭部不動。`;
  if(phase==="calibration")$("target").focus();
  validationStart=performance.now();validationSamples=[];
}
async function calibrate(){
  try{
    calibrated=false;$("start").disabled=true;$("reset").disabled=true;
    await post("/api/reset",{});
    await document.documentElement.requestFullscreen();
    if(innerWidth<480||innerHeight<480)throw new Error("校正需要至少 480 × 480 的桌面畫面。請移到訓練螢幕。 ");
    calibrationSize={width:innerWidth,height:innerHeight,dpr:devicePixelRatio,screenX:screenX,screenY:screenY};
    status("正在載入本機模型並請求相機權限。首次啟動可能需要稍候。");
    if(!webgazerReady){
      window.saveDataAcrossSessions=false;
      await loadScript("/webgazer.js");
      webgazer.showPredictionPoints(false).showVideo(false).showFaceOverlay(false).showFaceFeedbackBox(false);
      await webgazer.begin();
      webgazer.removeMouseEventListeners();
      webgazer.pause();
      webgazerReady=true;
      inferenceTimer=setInterval(infer,50);
      flushTimer=setInterval(flush,100);
    }
    await webgazer.clearData();
    phase="calibration";pointIndex=0;repetitions=0;validation=[];
    $("stage").hidden=false;placePoint();
  }catch(error){await fail(error);}
}
$("target").addEventListener("click",()=>{
  if(phase!=="calibration")return;
  if(performance.now()-lastCapture>250){$("instruction").textContent="目前未偵測到臉部，請調整光線與頭部位置。";return;}
  if((repetitions===0&&performance.now()-validationStart<400)||performance.now()-lastCalibrationClick<150)return;
  lastCalibrationClick=performance.now();
  const p=calibrationPoints[pointIndex];
  webgazer.recordScreenPosition(p[0]*calibrationSize.width,p[1]*calibrationSize.height,"click");
  repetitions++;
  if(repetitions>=5){repetitions=0;pointIndex++;}
  if(pointIndex>=calibrationPoints.length){phase="validation";pointIndex=0;}
  placePoint();
});
async function infer(){
  if(inferenceBusy||!webgazerReady||phase==="idle"||phase==="stopped")return;
  inferenceBusy=true;
  try{
    const prediction=await webgazer.getCurrentPrediction();
    const now=performance.now();
    const finite=prediction&&Number.isFinite(prediction.x)&&Number.isFinite(prediction.y);
    const tracker=webgazer.getTracker();
    if(tracker.getPositions()&&Number.isFinite(tracker.positionsTimestamp)&&now-tracker.positionsTimestamp<250)lastCapture=now;
    if(phase==="validation"){
      if(finite&&now-validationStart>500){const p=validationPoints[pointIndex];validationSamples.push(Math.hypot(prediction.x-p[0]*calibrationSize.width,prediction.y-p[1]*calibrationSize.height));}
      if(now-validationStart>2500){
        if(validationSamples.length<10)throw new Error("驗證樣本不足。請確認相機、光線和臉部位置後重新校正。");
        validation.push({error:validationSamples.reduce((a,b)=>a+b,0)/validationSamples.length,count:validationSamples.length});
        pointIndex++;
        if(pointIndex>=5){
          phase="finishing";
          const result=await post("/api/calibration",{...calibrationSize,errors_px:validation.map(p=>p.error),validation_counts:validation.map(p=>p.count)});
          $("stage").hidden=true;$("reset").disabled=false;
          if(!result.ok)throw new Error(`驗證平均誤差 ${result.mean_error_px.toFixed(0)} 像素，請重做校正。`);
          calibrated=true;phase="tracking";
          status(`校正完成。五點平均誤差 ${result.mean_error_px.toFixed(0)} 像素。保持此視窗開啟，返回 OcuDrive 開始訓練。`);
          if(document.fullscreenElement)await document.exitFullscreen();
        }else placePoint();
      }
    }
    if(calibrationSize){
      sampleBuffer.push({x:finite?prediction.x/calibrationSize.width:null,y:finite?prediction.y/calibrationSize.height:null,
        valid:Boolean(finite&&calibrated),timestamp_us:Math.round((finite&&Number.isFinite(prediction.t)?prediction.t:now)*1000)});
      if(sampleBuffer.length>64)sampleBuffer.splice(0,sampleBuffer.length-64);
    }
  }catch(error){await fail(error);}finally{inferenceBusy=false;}
}
async function flush(){
  if(!sampleBuffer.length)return;
  const samples=sampleBuffer.splice(0,64);
  try{await post("/api/gaze",{samples,sent_timestamp_us:Math.round(performance.now()*1000)});}catch(error){await fail(error);}
}
async function stop(){
  clearInterval(inferenceTimer);clearInterval(flushTimer);clearInterval(sceneTimer);
  if(webgazerReady){webgazer.end();webgazerReady=false;}
  phase="stopped";calibrated=false;$("stage").hidden=true;
  status("追蹤已停止，相機已釋放。可以關閉此視窗。");
  try{await post("/api/stop",{});}catch(_){}
}
$("start").addEventListener("click",calibrate);$("reset").addEventListener("click",calibrate);$("stop").addEventListener("click",stop);
$("verify-mapping").addEventListener("click",async()=>{try{const result=await post("/api/mapping/verify",{});$("mapping-status").textContent=result.message;}catch(error){status(error.message);}});
$("save-mapping").addEventListener("click",async()=>{try{const result=await post("/api/mapping/export",{});const blob=new Blob([JSON.stringify(result.mapping,null,2)],{type:"application/json"});const a=document.createElement("a");a.href=URL.createObjectURL(blob);a.download="ocudrive-sol-markers.json";a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);}catch(error){status(error.message);}});
document.addEventListener("fullscreenchange",()=>{if(!document.fullscreenElement&&(phase==="calibration"||phase==="validation")){fail(new Error("校正中離開全螢幕，請重做校正。"));}});
window.addEventListener("resize",()=>{if(calibrated&&devicePixelRatio!==calibrationSize.dpr){fail(new Error("顯示縮放已改變，請重新校正。"));}});
window.addEventListener("beforeunload",()=>{if(webgazerReady)webgazer.end();});
(async()=>{try{
  const response=await fetch("/api/config");if(!response.ok)throw new Error("校正工作階段已失效，請在 OcuDrive 重新連線。");config=await response.json();
  if(config.mode==="webgazer"){$("webgazer-controls").hidden=false;$("title").textContent="WebGazer 螢幕校正";$("intro").textContent="模型與影像在本機處理。相機會在按下開始後啟動。";status("尚未校正，請先開啟相機。");}
  else{$("sol-controls").hidden=false;$("title").textContent="Sol Glasses 螢幕映射";$("intro").textContent="以四個螢幕角落標記，將場景相機視線轉換為訓練畫面的座標。";status("等待 Chronus 與四角標記。返回駕駛畫面後，橋接會自動更新映射。");sceneTimer=setInterval(async()=>{try{const r=await fetch("/api/scene.jpg");if(r.ok){const blob=await r.blob();const old=$("scene").src;$("scene").src=URL.createObjectURL(blob);if(old.startsWith("blob:"))URL.revokeObjectURL(old);}}catch(_){}},500);}
}catch(error){status(error.message);}})();
