# Display Studio

在 Windows 上控制 Philips 498P9Z 的小工具，用來切換 DP／HDMI 輸入來源，以及調整亮度、螢幕音量和低藍光模式。

## 開始使用

下載專案並解壓縮，首次使用時在專案資料夾執行：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\BuildLauncher.ps1
```

之後雙擊 `MonitorInput.exe` 開啟面板：

- 點選 **DP／HDMI 1／2／3** 切換畫面。
- 拖動**亮度或音量**滑桿，再按「套用」。
- 選擇 **Off／LowBlue**，再按「套用」切換影像模式。
