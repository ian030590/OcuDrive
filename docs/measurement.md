# 眼動與路上事件量測

此文件描述 `godot/scripts/tff_analyzer.gd` 的實際演算法。`tests/test_tff.gd` 是可由 Godot headless 執行的邊界測試；是否已執行及其結果，以專案驗證紀錄為準。這些指標用於回顧本次訓練，不提供駕駛適任或復健成效判定。

## 參考來源與差異

1. 本機 `references/Time-To-Fixate-Calculation-from-the-Eye-Tracker-Videos`，commit `7cc4796c3efa54c22aefa62a6d66e057b5330bb8`，`ttf.py`。來源用 YOLO 偵測影片中的行人框，在行人從公車前方出現後，尋找視線首次落入人物框的影格，計算 `(end_frame - start_frame) * 1000 / fps`。範例的影片為 50 fps，索引眼動資料時用 `2 * frame`；沒有最低停留時間、I-VT 速度分類或完整的無效樣本處理。來源以先前資料補部分 NaN，本專案不做該填補。
2. [Miljković 與 Sodnik 的原始研究](https://link.springer.com/article/10.3758/s13428-023-02177-3) 以危險出現到首次看向目標的時間研究 TTF。此研究的條件、裝置、受試者與本專案不同，不能直接套用研究結果或推導臨床分界。
3. 本機 `references/openDS-oss`，commit `327c53a57f2dcddfbcb3e54c88937d8743e7097a`。`DataUnit.java`、`DataWriter.java` 以行車時間、位置、速度、方向盤、油門及煞車欄位記錄行車；來源 writer 名義上每 50ms 收集一次，緩衝後寫入。`GetTimeUntilBrakeAction.java` 示範由 trigger 開始煞車反應計時。本專案參考事件觸發與分開記錄車輛、事件和眼動的設計，不把 Java 引擎或其 20Hz 節流套到眼動原始樣本。
4. `C:/Users/ian/Projects/OcuTrain/wwwroot/training.js` 的 `saccadeFixationSummary` 使用 I-VT 型速度條件、至少三筆樣本及來源時間戳。該任務不要求命中目標，與此處的路上事件 AOI 停留任務不同，兩者結果不可互換。

Godot 已知每個目標的畫面投影，因此直接使用每筆樣本對應的動態 AOI，省去影片、YOLO、OpenCV、Torch 和逐影格推論。這保留參考程式「事件出現到視線首次進入目標框」的計算原則；沒有宣稱逐位元重現其影片管線。

## 兩個分開的結果

| 匯出欄位 | 定義 | 未觀測到 |
| --- | --- | --- |
| `time_to_first_entry_ms` | 第一筆有效視線進入當下 AOI 的 active session 時間，減去事件 onset | `null` |
| `time_to_first_fixation_ms` | 第一段合格連續 AOI 停留的起點，減去事件 onset | `null` |
| `fixation_confirmed_ms` | 第一次滿足停留時間與樣本數的確認時刻 | `null` |

`time_to_first_entry_ms` 最接近來源 `ttf.py` 的 TTF。第二欄為本專案額外提供的 **連續 AOI 停留 proxy**：預設至少 120ms、至少三筆有效樣本，且任兩筆間隔不得超過 100ms。它不是 I-VT/I-DT 注視分類器，也不代表測得認知辨識。大 AOI 內來回掃視仍可能符合這個操作型條件，分析時須保留此限制。

例：事件 onset 為 1000ms；第一筆入框為 1050ms，之後 1110、1170ms 均有效且入框。首次進入為 50ms，停留 proxy 的起點也是 50ms，但直到 1170ms 才確認。若 1110ms 是無效資料，仍保留首次進入 50ms，該段不能產生已確認停留。

零是合法結果：若 onset 當下已注視 AOI，首次進入可為 0ms。沒有結果使用 `null`，CSV 可輸出空欄，不能用零代替。平均值只能使用有結果的事件，且同時呈現分子與全部事件數。

## 時鐘及樣本規則

- 呼叫者負責將 `t_ms` 對應到同一個 active session 單調時鐘，事件 onset/offset 使用相同座標。不能用系統日期、固定 Hz 或遊戲影格數代替。
- `source_timestamp_us` 保留原生裝置時間。分析器只在同來源檢查遞增及缺口，不將其絕對值減去 session onset。沒有完成時鐘同步的來源不能直接拿來源時間與 Godot 時間相減。
- 暫停前後呼叫 `break_continuity()`；暫停期間不送入量測。active time 排除暫停，且暫停前後的視線不合併成持續停留。斷線、校正、切換顯示器或改變視窗幾何也須打斷。
- onset 前樣本不計該事件的品質或命中。事件結束後不外推樣本狀態，也不以最後一點補足停留。
- 事件消失時可先呼叫 `mark_event_offset(id, offset_ms)`，保留事件等待在途樣本。只有樣本時間落在 onset 至該 offset 的資料仍可計算；offset 後樣本不進入該事件的品質統計。最終 `end_event` 使用原 offset，不能改成等待結束時刻。
- 無效視線、NaN/Infinity、螢幕範圍外座標、離開 AOI、當下缺 AOI/不可見 AOI，均打斷停留。無效或缺失資料不當作眨眼，也不前值填補。
- `t_ms`、來源時間戳、序號的重複或倒序會拒收該筆並打斷當時活躍的事件停留，不倒退已接受的時間高水位。序號跳號、session 或來源時間間隔大於 100ms 會打斷，之後有效樣本可作為新段起點。
- 切換來源時打斷停留並重設來源時間及序號的比較基準。呼叫者應在正式 session 中鎖定來源，校正或換來源應開始新 session。
- 使用每次 `add_sample` 傳入的 AOI；沒有新 AOI 就不命中，從不沿用上一個矩形。AOI 必須與該筆視線的畫面時間對應，過舊或延遲樣本不能配上最新畫面冒充同步。
- 與來源程式一致，AOI 邊界採嚴格內部條件：`x < gaze_x < x+w` 且 `y < gaze_y < y+h`。位於框線上的樣本不算進入。

`minimum_fixation_ms` 可設定，但不低於 100ms；預設 `maximum_gap_ms=100`。兩者、最少三筆及演算法版本都寫入每事件結果，分析者可追溯設定。

## 資料品質欄位

| 欄位 | 意義 |
| --- | --- |
| `valid_samples` | 事件內具有效且在螢幕內座標的樣本數，包含 AOI 外樣本 |
| `invalid_samples` | 事件內無效、非有限或螢幕外座標的樣本數 |
| `rejected_samples` | 時間、序號無效、重複或倒序的拒收筆數 |
| `missing_aoi_samples` | 視線有效，但當下缺可用 AOI 的樣本數 |
| `sample_gap_count` | 該事件期間偵測到 >100ms 或序號跳號的筆數 |
| `observed_ms` | 連續有效樣本對之間的時間總和；不跨無效樣本、暫停或長缺口 |
| `unobserved_ms` | 事件時長減去 `observed_ms`，包含首末邊界及無效/缺資料區段 |
| `aoi_dwell_ms` | 連續有效入框樣本對之間的總時間，不等同已確認 fixation 總時長 |

`observed_ms` 是保守的區間覆蓋量，並非量測精準度、相機在線時間或生理眨眼時間。AOI 不存在時仍可能有有效眼動，所以 `missing_aoi_samples` 不會自動轉為 `invalid_samples`。

## 呼叫介面與測試

```gdscript
var analyzer = preload("res://scripts/tff_analyzer.gd").new()
analyzer.begin_event({"id": "pedestrian_1", "onset_ms": 1000.0})
analyzer.add_sample({"t_ms": 1050.0, "x": 0.4, "y": 0.5,
    "valid": true, "source": "tobii", "source_timestamp_us": 123450000,
    "sequence": 1}, [{"id": "pedestrian_1", "x": 0.3, "y": 0.3,
    "w": 0.2, "h": 0.4}])
analyzer.break_continuity() # 暫停或斷線時使用。
var result = analyzer.end_event("pedestrian_1", 2000.0)
```

`begin_event` 對空 ID、重複 ID 或非法 onset 回傳 `false`。`mark_event_offset` 對未知事件、非有限 offset 或早於已接收樣本的 offset 回傳 `false`；同一個 marker 可重複設定，但不能移動已標記的 offset。`end_event` 遇到未知 ID、非有限 offset，offset 比已收到的該事件樣本還早，或與先前 marker 不同，回傳空 Dictionary 並保留活躍事件。`finish_all` 回傳本 session 全部已完成結果，已標記的事件保留原 offset；重複呼叫不新增結果。`reset` 清除結果與時鐘狀態，供下一個 session 使用。

測試執行方式（從儲存庫根目錄）：

```powershell
& <Godot-console.exe> --headless --path godot --script ../tests/test_tff.gd
```

測試涵蓋已知 entry/停留延遲、onset 前資料、首次進入但未停留、無資料、invalid/NaN/Infinity、出框、超時/序號缺口、100ms 邊界、重複/倒序時間及序號、來源時鐘偏移、動態 AOI、缺失矩形、暫停、重疊事件、重複 ID、重設及非法結束時間。

## 本次驗證紀錄

2026-11-01，使用本機 `C:/Program Files/Godot/Godot_v4.7.1-stable_win64.exe` 執行上述測試，另加 `--log-file C:/Users/ian/Projects/OcuDrive/.tmp/tff-godot.log` 將日誌導向可寫入的 workspace。結果為 **TFF PASS: 73 assertions**，包含八組測試均完整結束的檢查及事件消失後的延遲資料處理。

Godot 在這個受限環境額外輸出無法讀取 Windows root certificate store 的訊息；本測試沒有網路操作。測試腳本沒有 `SCRIPT ERROR`。此 Godot GUI 可執行檔的外層程序結束碼曾在內部 `quit(1)` 時仍回報零，因此自動驗證需同時讀取 PASS/FAIL 及 script error 日誌，不只檢查外層結束碼。未在此測試驗證實體眼動儀精度、畫面到光子延遲、時鐘同步或臨床效度。

同日亦執行下列整合邊界測試。橋接 fixture 為明示的合成測試資料，不載入眼動儀 SDK、不使用相機、不產生臨床或硬體精度證據。

| 測試 | 結果 | 證據範圍 |
| --- | --- | --- |
| `godot/tests/test_session_recorder.gd` | 59 assertions PASS | ID 路徑限制、唯一 session、CSV 公式/引號/CR/換行/null/空值/負數、JSON 最終 metadata、時鐘與 AOI 分析欄、不可寫目錄、事件摘要建立失敗的最終狀態 |
| `godot/tests/test_bridge_manager.gd` | 30 assertions PASS | 實際 Python/Godot loopback NTP ping/pong、四時間戳公式及最小 RTT、錯 token/錯 endpoint 拒收、malformed gaze 斷連續、gaze 獨立序號、停止 helper |
| `godot/tests/test_frame_alignment.gd` | 9 assertions PASS | 歷史動態 AOI、同 frame 多筆樣本時間內插、resume segment 前/過舊/未來/停止後資料拒收、缺 frame 不假造 AOI |

日誌位於 `.tmp/recorder-godot.log`、`.tmp/bridge-manager-godot.log`、`.tmp/frame-alignment-godot.log`。Recorder 測試會刻意將輸出根目錄指向一個檔案，Godot 會產生一條預期的無法建立資料夾錯誤；測試必須確認程式拒絕開始且提供訊息。測試啟動可加 `--quit-after 600`，避免腳本錯誤後程序無限等待；仍需檢查對應 PASS 行存在。
