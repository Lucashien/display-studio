# Philips 498P9Z：逐輸入孔連線／訊號查詢可行性

查核日期：2026-10-24（Asia/Taipei）。本次未切換輸入、未安裝或執行原廠 SmartControl，也未聯絡第三方。

## 結論

**目前沒有確認到可用於 498P9Z、能從一台電腦查詢其他 HDMI 輸入是否接線或有訊號的公開／已驗證介面。因此，現階段無法把這項需求實作成可靠的自動偵測功能。**

這是目前介面可用性的工程判定，不是「已證明韌體不存在任何私有指令」。此型號回報了未公開語義的廠商代碼，不能只因公開文件沒有寫，就排除私有功能。

## 核對的證據與適用範圍

1. **原廠 498P9Z 規格／快速指南：**列出 HDMI 2.0 ×3、DisplayPort、DDC/CI、SmartControl、PBP 與輸入選擇，未提供逐輸入孔接線／訊號狀態 API 或命令表。規格未列出功能不是不存在功能的證明。
   - [原廠 498P9Z 規格](https://www.documents.philips.com/assets/20230607/d03c1d1ca12a474399abb01a00bebc6b.pdf)
   - [原廠 498P9Z 快速指南](https://www.documents.philips.com/assets/20230529/53d05698c26b49e1b6edb011011b18ac.pdf)
2. **實機 DDC/CI 能力字串：**型號 `498P9Z`、MCCS 2.2，輸入來源項為 `60(00 11 12 13 0F 10 21 22 2F 30 31)`。這是宣告的輸入選項，不是目前已插線的接孔清單。本次讀取 0x60 的低位元組為 0x0F；只能確認螢幕回報的選取來源。能力字串亦含廠商代碼，其完整定義未取得。
3. **從 SmartControl 7.0.0 分析而來的獨立控制實作：**核對其原始碼，提供主要／次要來源、MultiView、來源交換、輸入自動選擇開關與顯示資訊等；未見逐接孔線材或訊號存在狀態的查詢。作者只明示在 BDM4037U 測試過，因此不能拿此程式作為 498P9Z 沒有私有功能的證明。
   - [控制實作與相容性限制](https://github.com/n14395/philips-monitor-control)
   - [實際來源控制程式碼](https://github.com/n14395/philips-monitor-control/blob/master/Linux/multiview_ddc.py)
4. **其他 Philips 型號的 USB 廠商協定：**另核對 49M2C8900 的公開控制實作，亦未找到可直接套用到 498P9Z 的逐接孔狀態查詢。它是不同型號，不應假定其 USB 協定與 498P9Z 相容。
   - [49M2C8900 USB／DDC 協定實作文件](https://github.com/TimP4w/HaloDaemon-plugins/blob/main/philips_evnia/docs/ddc-ci.md)
5. **官方 SmartControl 安裝包未能取得：**原廠支援頁與 Microsoft WinGet 都指向同一 TPV 下載位址；本次數次存取回傳 502，另一次 Python 請求遇到憑證鏈驗證錯誤，沒有繞過驗證。因此沒有完成官方最新版二進位程式的直接檢查，不能宣稱已排除其所有功能。
   - [原廠提供 SmartControl 的支援頁](https://www.usa.philips.com/c-p/24M1N3200V_27/gaming-monitor-full-hd-gaming-monitor/support)
   - [WinGet SmartControl 7.2.0 安裝資訊](https://github.com/microsoft/winget-pkgs/blob/master/manifests/p/Philips/SmartControl/7.2.0/Philips.SmartControl.installer.yaml)

## 對 Prototype 的影響

- 保留目前來源讀取與切換來源控制。
- Windows 顯示路徑只能表示本機的連線可用性；另一台電腦接 HDMI 1，並不會出現在本機的路徑清單。
- HDMI 各編號應保持「本機無法判定／未知」，不能顯示成未接線。即使選取 HDMI 1，也不能只憑選取值就顯示有訊號。
- 不把「輪流切到每個來源再觀察」當成背景偵測；它會改變畫面，而且線材接著與設備輸出有效影像是不同條件。

## 要得到確定的硬體支援答案，仍缺少什麼

需要飛利浦／TPV 針對 **498P9Z（EDID PHL0978）**提供或確認：

> 是否能在保留 DP 為目前來源的情況下，經 DDC/CI 或 USB 查詢 HDMI 1／2／3 各自的線材／來源存在狀態，以及有效影像訊號狀態？若支援，請提供 VCP 或廠商命令、請求與回覆格式、必要的 USB 連線方式及韌體版本；若不支援，請明確確認此型號沒有對主機開放此查詢。

目前尚未取得這項原廠確認；未將「查無公開介面」寫成「硬體絕對做不到」。
