# UI 與本機執行驗證

驗證日期：2026-11-01。本機使用 Godot 4.7.1、OpenGL Compatibility 與 AMD Radeon 780M，執行 `godot/tests/test_main_ui.gd`。最新實際顯示模式結果為 **80 checks，0 failures**；詳細記錄於 `.tmp/ui-data/ui-test-report.json`。

| 操作 | 實際觀察 |
| --- | --- |
| Tab | 焦點由受試者代碼前進至下一個設定控制項。 |
| 空代碼、含路徑字元的代碼 → 開始 | 不開始訓練，顯示可修正的錯誤。 |
| 選 WebGazer／Sol／Tobii | 不建立 helper process 或 UDP socket。 |
| 尚未連線的眼動來源 → 開始 | 阻擋訓練，要求連接／校正或選無眼動。 |
| Sol／Tobii 未確認校正 → 連接 | 阻擋啟動橋接；校正確認獲得焦點，文字仍可讀。 |
| 只勾選校正確認 → 開始 | 仍不能代替裝置連線。 |
| 無眼動 → 開始 | 進入駕駛畫面，helper PID 保持 -1，沒有 socket。 |
| 聲音按鈕 | 實際啟用／停用音效模組，介面設定同步更新。 |
| Esc → 暫停；繼續按鈕 | 暫停時路程與模擬時間停止；繼續後扣除暫停的牆鐘時間。 |
| 暫停 → 結束並儲存 | 顯示結果，產生六份紀錄檔；無眼動來源的眼動筆數為零。 |
| 返回訓練設定 | 恢復設定畫面，橋接保持卸載。 |

另檢查了世界隱藏時後視鏡同步隱藏、Sol 四角標記不與可見按鈕重疊、LineEdit 與 CheckBox 深色文字、焦點狀態文字，以及 960×640／1280×720 的實際 viewport 像素。

已檢視的實際畫面位於 `.tmp/ui-data/`：`setup-*`、`sol-*`、`driving-*`、`results-*`，各有 960×640 與 1280×720 版本，另有 `pause-1280x720.png`。以上畫面沒有用縮圖重建或人工製作。

## 15 秒正常 GUI 量測

`godot/tests/benchmark_driving.gd` 使用正常物理更新、正常紀錄寫入、無眼動來源與 30fps 上限。未使用加速 smoke stepping。量測報告位於 `.tmp/perf-data/engine-report.json` 與 `process-report.json`。

| 指標 | 本機觀察 |
| --- | --- |
| 畫面與渲染 | 1280×720，OpenGL Compatibility，AMD Radeon 780M |
| 呈現畫格 | 441 frames / 15.54 秒，平均 28.37fps |
| 平均 CPU | 單一邏輯核心容量的 18.51%；本機 16 邏輯核心總容量的 1.16% |
| 程序 working set | 最後 249.25MiB，取樣峰值 312.12MiB |
| 程序 private bytes | 最後 235.86MiB |
| 眼動橋接 | PID -1，未載入 |

這是本機 editor executable 執行專案的單次量測，沒有測 GPU 記憶體，不能作為其他硬體或單檔發布版本的效能保證。

## 驗證限制

未操作實體眼動儀、攝影機允許視窗、Tobii Experience、Sol Chronus、實體手把或方向盤；也未以自動測試開啟 Windows 檔案總管。測試實際操作了 Control signals 與 Tab／Esc 輸入，沒有假造眼動樣本。

沙箱內 Godot 啟動記錄含 Windows root certificate store 讀取及 shader disk cache 寫入的環境錯誤；引擎使用內建憑證後繼續執行，UI／駕駛測試沒有 GDScript 例外。上述環境訊息保留在 `.tmp/test-main-ui-gui.log`，沒有刪除或解釋為已完成實機驗證。
