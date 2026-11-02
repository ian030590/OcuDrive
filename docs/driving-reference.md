# 駕駛模擬與聲音設計

本模組為 Godot 4 Compatibility renderer 的原生場景，並未在背景啟動 Java、OpenDS 或瀏覽器繪製道路。

## 參考與轉譯

參考版本：OpenDS `327c53a57f2dcddfbcb3e54c88937d8743e7097a`、Carlito `3aa07d63e1ee146a2a59b356a699c12e14b35f01`；影片 TTF 專案版本另見量測文件。參考工作目錄部分缺檔，已透過各庫的 `git show HEAD:path` 讀取原始內容，沒有覆寫其工作目錄。

- `references/carlito/README.md` 與 `src/input/vehicle_input.gd`：核對同版本 Godot、輕量原生車輛模擬與每 tick 正規化 throttle／brake／steer 的分離方式。本專案採簡化的同類輸入欄位與程序道路，不帶入其 CAN／多車種系統或整套素材。
- `references/openDS-oss/src/eu/opends/trigger/TriggerCenter.java`、`TriggerAction.java`：以路程條件觸發事件，事件產生可見物件及開始反應計時。
- `references/openDS-oss/assets/DrivingTasks/Projects/ReactionTest/interaction.xml`：參考 `manipulateObject`、`setupBrakeReactionTimer`、`setupLaneChangeReactionTimer`、錄製開始／結束等分離責任。Godot 實作在 `driving_world.gd`，並非載入或執行 OpenDS XML。
- `references/openDS-oss/src/eu/opends/analyzer/DataWriter.java` 與 `reactionCenter`：參考 50ms 車況取樣及速度、轉向、油門、煞車欄位，並用本專案同一次模擬時間記錄路程與個別事件反應，輸出由主程式資料記錄器負責。
- `C:/Users/ian/Projects/RehabTrainerHub/apps/rehabtrainerhub/games/driving-rehab/rendering/driving-rendering.ts`：採用 low profile 的方向，限制視距、不載入 OSM 城市及高模車輛、不採超取樣或陰影。
- 同資料夾 `hazards/driving-hazards.ts`：參考較寬鬆事件預告距離及難度差異。此專案新製作行人、前車煞車、路口號誌、車道障礙及後視鏡來車五類事件。

沒有移植 OpenDS 的 Bullet 車輛物理、完整車流路網、地圖、Drive Analyzer 二進位檔、反射鏡多相機渲染、力回饋方向盤或完整 XML action 語言。此版本的車輛是可煞停與橫向操控的簡化運動學模型，適合低硬體需求的注意與反應練習。一般手把的左搖桿、右扳機及左扳機可控制轉向、油門與煞車；未宣稱支援未校正的方向盤踏板。

## 使用與介面

`driving_world.gd` 延伸 `Node3D`，提供 `configure(settings)`、`start_session()`、`set_paused(value)`、`stop_session()`、`get_state()` 與 `get_event_aois()`；透過 `hazard_started`、`hazard_ended`、`telemetry`、`session_finished` signal 交給主程式。`step_simulation(delta, controls)` 讓測試可直接以明確輸入推進，不會產生虛構眼動。

設定包含 `duration_s`（60 至 600 秒）、`difficulty`（`gentle` 或 `standard`）、`seed`、`auto_speed` 與 `audio_enabled`。同一種子決定同一事件順序；路程觸發仍取決於實際駕駛。輕緩模式自動巡航目標 30 km/h，標準模式 45 km/h；關閉自動巡航後需按油門起步。按左右鍵／A、D 轉向，上鍵／W 油門，下鍵／S／Space 煞車。按住煞車不會在事件出現時被誤記為新的煞車反應。

所有事件及車況使用累積的模擬有效時間（毫秒），暫停期間不推進。Onset 為首次投影出有效 AOI 的模擬更新，對應下一個呈現畫格，並非光電感測器量得的實體螢幕發光時間。3D 物件 AOI 以物件邊界八角投影，加每邊 4 邏輯像素的容差；每次查詢都依目前攝影機與目標位置更新，裁切到實際 viewport。號誌 AOI 僅包含號誌頭部，不包含整條停止線。

後視鏡採用標示「後方示意」的 2D 視窗，省去第二次 3D 渲染；來車事件 AOI 僅對應示意中實際顯示的車。鏡面預設位於畫面的 x=40% 至 60%、y=14% 至 27%，主程式應避免以其他控制項遮住。後方示意並非完整光學後視鏡或真實後車物理模型。

聲音預設關閉。開啟後才建立低音量引擎及短碰撞提示的音訊資源；事件出現不發聲，避免聲音提前透露待注視的目標。暫停、停止及關閉聲音均停止播放。沒有外部錄音或網路音訊。

## 檢查範圍

同目錄測試 `godot/tests/test_driving_world.gd` 驗證可重播順序、暫停不計時、煞車反應、樣本時間遞增、五類事件與完整結束。需使用 Godot 4 執行：`godot --headless --path godot --script res://tests/test_driving_world.gd`。靜態語法檢查或程式碼閱讀不等同於引擎執行、畫面檢查或實體手把驗證。

本次已以本機 Godot 4.7.1 完成 headless 邏輯測試及 OpenGL Compatibility 顯示模式測試，並檢視 `.tmp/driving-world.png` 的實際渲染。音效建立與關閉生命週期在兩種模式皆檢查；真正啟動／停止播放的 assert 在顯示模式執行，避免 headless Dummy audio driver 關機時留下播放資源的引擎警告。未以實體手把或方向盤驗證。
