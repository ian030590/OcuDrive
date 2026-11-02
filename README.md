# OcuDrive 0.1.0

以 Godot 4.7.1 製作的 Windows 復健情境駕駛練習專案。提供簡化 3D 道路、行人穿越、前車煞車、路口號誌、車道障礙與後方交通，記錄車況、事件反應與眼動資料。這是可執行的開發預覽版，尚未完成實體眼動儀及臨床效度驗收。

執行檔：[dist/OcuDrive.exe](dist/OcuDrive.exe)。來源專案：[godot/project.godot](godot/project.godot)。不需要另外安裝 Godot 或 Python。

**目前缺完整 Ganzin Sol SDK。** 三種橋接程式均已包含，但這個建置的 Sol 選項不能連接實機；程式會顯示缺件原因。原廠 SDK 由 Chronus Remote Browser 提供，取得符合版本的 wheel 後，可依 [BUILD.md](BUILD.md) 重建。WebGazer 資產與 Tobii Stream Engine DLL 已包含。

## 使用

1. 執行 `OcuDrive.exe`，輸入受試者代碼（英數字、底線、連字號，請勿使用姓名）。選擇時間、難度、情境種子及訓練螢幕。
2. 可選「無眼動」直接練習。其他來源須先按「連接與校正」，完成校正並等候就緒。
3. WebGazer 會開啟獨立的本機瀏覽器校正頁，按鈕啟用攝影機，完成九點、每點五次確認及五點驗證後返回程式。請在同一螢幕全螢幕校正。需要電腦已有 Edge、Chrome 或 Brave，沒有內嵌整套 Chromium。
4. Tobii Eye Tracker 5 先在 Windows 的 Tobii Experience 校正同一訓練螢幕，勾選已校正，再連接。仍需要原廠驅動與 Tobii Experience。
5. 完整 Sol 建置需先在 Chronus 校正眼鏡，輸入手機私人 IPv4 位址與連線埠。四角標記必須同時可見；它們把場景相機的視線轉成螢幕座標，轉頭後重新映射，不能用場景像素直接當螢幕像素。
6. 按「開始駕駛練習」。方向鍵或 WASD 控制，空白鍵煞車；支援一般遊戲手把。自動車速可減少操作負擔，轉向與煞車仍由參與者執行。
7. Esc 暫停。結束時儲存完整或提前結束的紀錄；失去焦點、追蹤斷線及視窗尺寸改變會暫停。若眼動幾何改變，須儲存後重新校正。

無眼動模式不啟動橋接、SDK 或相機，不會把滑鼠位置當眼動。選擇裝置之後仍須按連接才啟動橋接；只初始化選定的 SDK。切換、結束或主程式離開會停止橋接並回收其獨立瀏覽器。選定裝置時，內嵌 helper 與原生檔案會解到使用者的快取磁碟，未選 SDK 不會初始化。

## 紀錄

按結果頁的資料夾按鈕即可開啟紀錄。預設位置是 `%APPDATA%/Godot/app_userdata/OcuDrive/sessions/`，每次建立獨立的「代碼、時間、隨機後綴」目錄。`OCUDRIVE_DATA_DIR` 環境變數可指定另一個本機根目錄。

| 檔案 | 內容 |
| --- | --- |
| `metadata.json` | 設定、軟體版本、校正資訊、是否正常結束及儲存完整性 |
| `vehicle.csv` | 20 Hz 車速、距離、車道位置、方向、油門、煞車與碰撞 |
| `gaze.csv` | 原生眼動樣本、來源與主機時間戳、同步估計、有效性及原因 |
| `timeline.jsonl` | 事件、暫停、裝置狀態、逐筆歷史 AOI 與樣本分析狀態 |
| `events.csv` | 各事件首次進入目標與 TFF 代理值 |
| `summary.json` | 全部事件、駕駛反應與彙整結果 |

資料保存在本機，未實作加密或雲端同步。不錄製攝影機或 Sol 影片。失效追蹤不會被命名為眨眼。來源封包的認證 token 不存入量測紀錄。

`time_to_first_entry_ms` 對應參考影片專案的首次進入 AOI 原則；`time_to_first_fixation_ms` 是本專案另加的持續停留代理值：至少 120 ms、至少三筆連續樣本。無效、離開目標、漏樣本或間隔超過 100 ms 會中斷。未看到與未成立均為 null，不能解讀為 0 ms。這不是 I-VT 注視分類。詳見 [量測定義](docs/measurement.md)。

## 效能與驗證範圍

使用 OpenGL Compatibility、30 FPS 上限、固定視角、程序幾何、無陰影及無後處理；後視鏡是清楚標示的 2D 後方交通示意。沒有完整城市、OSM、額外鏡面相機或高精細車輛物理。尚未在低階電腦與 RehabTrainerHub 做同條件效能對照，不能把設計取捨當成比較結果。

本機以 Ryzen/AMD 780M 的 1280×720 正常 GUI 跑 15.54 秒量得 441 畫面、約 28.37 FPS；RSS 結束約 249 MiB、峰值約 312 MiB，未啟用橋接。這不是最低硬體保證。詳見 [介面與效能驗證](docs/ui-verification.md)。

目前的離線建置沿用本機 Godot 編輯器二進位作為較大的執行宿主，並加入標準 PCK 容器區段。它啟動時執行遊戲，不開編輯器；獨立目錄啟動已驗證。取得官方 Windows release export template 後可重建較小版本。執行檔未簽章。

## 開發與審查

- [建置與測試](BUILD.md)
- [眼動橋接與 SDK 缺件](docs/bridge-notes.md)
- [OpenDS 與 Hub 取用範圍](docs/driving-reference.md)
- [產品與資安驗收](docs/review-plan.md)
- [各部門審查紀錄](docs/departments.md)
- [第三方元件](bridges/THIRD_PARTY.md)

專案原始碼採 AGPL-3.0，見 [LICENSE](LICENSE)。WebGazer、Godot、Python、模型與廠商 SDK 保留各自條款；本專案不授予額外廠商授權。
