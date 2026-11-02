# 眼動橋接與實機驗收

## 實作範圍

主程式啟動時不啟動眼動程序。選擇並連線某一來源後，才啟動 `OcuDriveBridge.exe --source ...`。該程序只匯入所選 provider；WebGazer 模型、Tobii DLL、Sol SDK / OpenCV / NumPy 彼此獨立。切換來源或關閉主程式時，以已認證 UDP stop、父程序存活檢查及主程式的程序回收停止橋接。相機來源使用獨立瀏覽器設定檔，不讀取使用者平常瀏覽器的資料。

橋接不提供模擬眼動。裝置、相機、SDK 或校正失敗時，回報具體錯誤，無效座標保持 `valid=false`。僅開啟未使用的裝置選項不會導致相應模型常駐。

## 介面

`python -m bridges.bridge_helper --source webgazer|tobii|sol --port GODOT_UDP_PORT --token RANDOM_TOKEN --parent-pid GODOT_PID`

Sol 另接受 `--sol-host`、`--sol-port`（預設8080，須與Chronus顯示一致）、`--sol-mapping`（可選標記配置JSON）。`--no-browser` 僅供自動化驗證。

Godot 綁定127.0.0.1。helper使用隨機來源埠向該埠傳送 JSON；第一個 loading status 提供 `control_port`。Godot控制封包必須由原本的接收socket送回該埠，並帶同一個token。

`gaze` 欄位：`token`、`type`、`source`、`process_id`、`sequence`、`transport_sequence`、`x`、`y`、`valid`、`source_timestamp_us`、`host_timestamp_us`、`bridge_timestamp_us`、`coordinate_space=screen_normalized`、`simulated=false`。`process_id`供封裝驗證識別真正SDK子程序，不寫入量測journal。`sequence`只對gaze連號，status及clock封包不消耗樣本序號；`transport_sequence`記錄所有封包。無效座標輸出安全的x/y=0並明確標記valid=false與invalid_reason，原始值保留在raw_x/raw_y，非有限原值為JSON null。螢幕外資料不充作有效。保留來源時間戳，未假定固定取樣率。

`status` 欄位：`state`、`message`，以及校正/映射與時鐘相關metadata。狀態使用loading、calibrating、ready、error、disconnected、stopped；error不會被finally的stopped覆蓋。`ready`表示來源的必要橋接條件成立；Tobii Experience與Chronus外部校正仍須使用者在主介面確認。calibrating的calibration_url內含短期認證token，主程式不得將該URL或token寫入量測journal、CSV或報告。

clock ping：Godot送 `{type:clock_ping,token,godot_ticks_us:t0}`，helper回 `{type:clock_sync,token,source,godot_ticks_us:t0,host_receive_us:t1,host_send_us:t2}`。主程式收到時記t3，以最小往返延遲估計host與Godot的monotonic clock offset。Tobii另外用SDK system clock取得device-to-host offset；WebGazer與Sol使用來源時間及最小到達offset估計。後兩者的來源到主機延遲並非經硬體同步量測，分析須保留此限制。

## WebGazer

離線JS與兩個臉部模型複用 `OcuTrain/wwwroot/webgazer*`，保留原始第三方授權聲明。校正頁有九點、每點五次確認及五點獨立驗證，每點至少十筆實測注視。驗證報告包含每點平均像素誤差、筆數、全螢幕CSS尺寸與devicePixelRatio。平均誤差不得超過較短邊15%，任一點不得超過25%；這是本軟體的開始門檻，並非臨床精度標準。

相機只在按下「開啟相機並開始九點校正」後啟動。使用與Godot相同的全螢幕顯示器校正，保存該時的完整CSS座標大小。返回遊戲後仍使用該校正座標空間，不依背景視窗大小重新縮放。更換顯示器、系統縮放或頭位需要重做校正。

該版WebGazer的 `getCurrentPrediction` 明確支援paused模式更新相機frame。橋接暫停內建rAF迴圈，以單一50ms timer逐次推論並每100ms批次傳送。瀏覽器以獨立app程序搭配關閉背景timer/renderer/遮擋節流選項啟動，避免全螢幕Godot蓋住後rAF停止。實際Hz仍受CPU、相機與瀏覽器影響，超過2秒未收資料會提示stale，主程式不得重用舊點計分。使用者須安裝Edge、Chrome或Brave；不內嵌完整Chromium。Windows僅從登錄的App Paths或標準安裝目錄尋找瀏覽器，不使用目前工作目錄／PATH猜測執行檔。

按停止會呼叫WebGazer.end，釋放所有camera tracks，再停止helper。主程式結束時也會回收獨立瀏覽器程序樹及其臨時設定檔。未錄製相機影像。

## Tobii Eye Tracker 5

沿用 `OcuTrain/src-tauri/src/tobii.rs` 的Stream Engine ABI。`NativeGaze`為24 bytes，時間戳offset0、validity8、x12、y16；訂閱兩眼合併視線，保持所有原生樣本，不臆造每眼注視點。DLL只在Tobii來源選取後由絕對路徑載入，離開時unsubscribe、destroy device及API。

使用者先在Tobii Experience校正實際訓練螢幕。SDK可連線不代表已校正，主介面必須要求外部校正確認。同一個校正顯示器上全螢幕運行；不提供自製硬體校正。

## Sol Glasses

以使用者提供的 `Sol_SDK_Tutorial.pdf` 第12至15頁為依據，使用 `ganzin.sol_sdk.synchronous.sync_client.SyncClient(address,port)`、`StreamingMode.GAZE_SCENE`、`create_streaming_thread`、`get_video_frames_from_streaming`、`get_gazes_from_streaming`、`frame.get_buffer()`、`frame.get_timestamp()`、`gaze.combined_gaze_2d.x/y`。新版SDK時間單位為微秒。PDF第17至21頁的async版本亦確認使用同一種場景像素座標，不能直接解釋為螢幕座標。SDK實際GazeData timestamp欄位必須在實機驗收確認，橋接接受 `get_timestamp()` 或 `timestamp` 且要求有效微秒值。

Chronus與PC須在私人區域網路，遠端監看保持預覽。先完成Chronus的眼鏡校正。只允許私人IPv4或.local主機；.local解析後再次檢查私人地址並固定該地址，避免任意網址與DNS轉向。

Godot在選擇Sol時於四角顯示 `DICT_4X4_50` IDs0、1、2、3，標記中心依序為 (.04,.04)、(.96,.04)、(.96,.96)、(.04,.96)。`godot/markers/marker_*.png` 每張168×168像素，中央120×120黑白標記加四側24px白色quiet margin；顯示時保持正方形。

每筆場景frame重新偵測全部四標記，以中心求camera-to-screen homography。只在四點凸四邊形、面積足夠且矩陣有限時接受。任一標記消失，當幀即刪除映射；映射到達超過250ms或視線與場景時間戳差超過100ms均判無效。轉頭後會依新frame重新映射，不沿用靜態homography。校正視窗可以查看本機場景快照、確認四角映射及匯出標記配置；匯出的JSON不包含可繞過live檢查的靜態homography。當校正視窗蓋住Godot標記時映射失效是預期行為，返回Godot後自動恢復。

實際現有檔案未包含完整Ganzin SDK：`build/sol-sdk-packages`只有`av/logging.pxd`，`.tmp/uv-cache`為零星不完整檔案；Downloads的同名Sol轉頭處理資料夾及ZIP均只有單一51738-byte HTML，沒有SDK wheel。PDF第6頁說明SDK由Chronus Remote Browser提供。本次不能從教學投影片重建廠商的RTSP/RTCP套件。橋接程式已實作真實API呼叫，但完整單檔套件仍須以原廠wheel重建，不能標示Sol實機已驗收或SDK已內含。

Sol有效性目前根據有限的場景座標與新鮮的四角映射；不把無效追蹤叫做眨眼。影像只保留記憶體快照供本機UI查看，未錄影、未外傳。

## 打包

從專案根目錄建置 `bridges/bridge_helper.py`。PyInstaller需要收集隱式匯入：`bridges.sources.webgazer`、`bridges.sources.tobii`、`bridges.sources.sol`，並將 `bridges/web` 加到helper的 `web`、`bridges/native` 加到 `native`。`resource_root()` 在原始碼模式指向bridges，在打包模式指向_MEIPASS。

Tobii DLL已從OcuTrain複製到 `bridges/native/tobii_stream_engine.dll`。WebGazer與模型約7MB，Tobii DLL及各SDK保留原廠條款；未變更廠商授權。未加入廠商SDK時，Sol選項會明確顯示缺套件錯誤。完整Sol建置需Python3.12、原廠Ganzin wheel及其宣告相依、OpenCV（含aruco）與NumPy，另以PyInstaller收集 `ganzin`、`cv2`、`numpy`、`av` 等實際wheel宣告套件與native binaries。禁止用不相關的同名PyPI套件替代。

主程式將helper檔案內嵌為資源，連線選定來源時才抽取並執行。SDK native檔案可能在helper啟動時解壓到暫存磁碟，但Python模組與DLL不會在未選取其來源時初始化到程序記憶體。

## 驗證

`python -m unittest discover -s tests -p test_bridges.py -v` 驗證SDK按需匯入、有限座標、token與來源socket、clock ping、Tobii ABI、HTTP cookie/Origin/Host/body/path保護及實際生成ArUco標記的homography/遮擋失效。

可選瀏覽器流程測試設定 `PLAYWRIGHT_MODULE` 指向本機Playwright套件、`PLAYWRIGHT_BROWSER`指向本機Chromium執行檔。測試以明確的推論fixture替代相機，但使用真實HTTP provider、九點45次確認、五點驗證與停止程序。此驗證不能取代真實攝影機、Tobii、Sol、DPI/多螢幕與網路延遲驗收。
