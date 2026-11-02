# OcuDrive 0.1.0 開發預覽交付

產物：`dist/OcuDrive.exe`，193,192,904 bytes（約 193 MB）。單一 EXE 已內嵌 Godot 專案、眼動 helper、WebGazer／模型、Tobii DLL 與授權說明，不需要旁放 PCK 或安裝 Python。原廠驅動、外部校正應用與相機所用瀏覽器仍為系統需求。

SHA-256：`0b3e6e08597752c87b0e2a471f4981f7917f1534e0d87569bff58eba2c96fb6f`。

已核對 `dist/build-manifest.json`、`OcuDrive.exe.sha256`、完整測試與 Defender 報告均對應這個同一產物；最後掃描後沒有再改動 EXE。

## 已完成

- Godot Compatibility 3D 駕駛、五類道路事件、距離 trigger、反應時間與 20 Hz 車況紀錄。
- 完整設定、訓練、暫停、提前結束、結果與本機 CSV／JSON 匯出。
- 按需橋接與 SDK 載入、WebGazer 九點／五點流程、Tobii Experience 校正確認，以及 Sol 真實 API 呼叫與四角動態映射邏輯。
- 首次 AOI 進入及持續 AOI 停留 TFF 代理值分開輸出；來源／主機／Godot 時鐘估計、歷史 AOI、晚到樣本與暫停邊界已有測試。
- 設計、開發、產品、維護、量測、聲音與資安分工／交叉審查記於 [協作紀錄](departments.md)。

## 最後驗證

| 項目 | 證據 |
| --- | --- |
| TFF | 73 assertions PASS |
| 紀錄器 | 59 assertions PASS，包含 CSV、路徑與最後寫入失敗 |
| Godot 橋接 | 30 assertions PASS，真實 loopback 時鐘握手與認證 |
| frame alignment | 9 assertions PASS，歷史 AOI、暫停、過期與停止後樣本 |
| 駕駛 | 五種事件、重播、車況、煞車反應、碰撞、闖紅燈與音訊生命週期 PASS |
| Python 橋接 | 14 tests PASS，包含真實瀏覽器校正頁的推論 fixture；另有 1 項 Windows Brave 探索測試 PASS |
| GUI | 80 checks PASS，960×640 與 1280×720 真實截圖、鍵盤與焦點狀態 |
| 單檔 | 獨立目錄啟動完成 5 事件、1,201 筆車況、0 筆虛構眼動，儲存成功 |
| 封裝橋接 | 三個 frozen provider 啟動／停止 PASS；WebGazer 未載入其他 SDK 原生模組；內嵌 helper 抽取與雜湊、時鐘與停止 PASS |
| 弱掃 | 24 項離線來源／HTTP／封裝檢查 PASS，Defender 對實際兩個 EXE 均回報未發現威脅 |
| antislop during | [逐項 Delivery Gate](antislop-delivery.md) PASS |

可重跑命令見 [BUILD.md](../BUILD.md)。原始執行證據在 `.tmp/verification.json`、`.tmp/packaged-check.json`、`.tmp/security-scan.json`；可閱讀的報告見 [介面](ui-verification.md)、[量測](measurement.md)、[資安](security-review.md)。

## 尚未完成

1. **Sol 原廠 SDK 缺件。** 這個 EXE 有 Sol 橋接與映射邏輯，但不能連線 Sol 實機。UI 與 build manifest 已明確標示；取得 Chronus 提供的 Python 3.12 SDK wheel 後須重新建立完整版本，不能只把 wheel 放到 EXE 旁。
2. **Claude Code 沒有完成對抗審查。** 已實際正式呼叫，60 秒逾時沒有結果；先前最小探測回報 ECONNREFUSED。見 [執行紀錄](claude-review.md)。本地弱掃不取代該審查。
3. 實體 WebGazer／Tobii／Sol 的精度、DPI／多螢幕、手把、實際顯示延遲與臨床效度尚未驗收。TFF 欄位是清楚標示的 AOI 停留代理值。
4. 本機缺官方 runtime export template，因此沿用較大的離線 Godot 宿主複本；已驗證執行遊戲而非開啟編輯器。正式較小版本可依 BUILD.md 改用官方 template 重建。此 EXE 未簽章。

這是可操作與可檢查的開發預覽，不能稱為已完成三種眼動儀實機驗收的正式版。
