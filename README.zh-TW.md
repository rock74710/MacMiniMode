<p align="center">
  <img src="docs/icon.png" width="128" alt="Mac mini 模式圖示">
</p>

<h1 align="center">Mac mini 模式</h1>

<p align="center">讓插著電的 MacBook 合上蓋子也能一直執行；拔掉電源，它又是一台正常睡眠的筆電。</p>

<p align="center">
  <a href="https://github.com/Pama-Lee/MacMiniMode/releases/latest/download/MacMiniMode.pkg"><img src="docs/download-zh.svg" height="48" alt="下載安裝包"></a>
</p>

<p align="center"><a href="README.md">English</a> · <b>繁體中文</b></p>

## 安裝

1. 點上面的「下載安裝包」，會得到一個 `MacMiniMode.pkg`。
2. 雙擊開啟，一路點「繼續」，中途輸入一次開機密碼。
3. 裝完選單列會多出一個圖示，這時已經在工作了，不用重啟。

安裝包已簽名並通過 Apple 公證，開啟時不會提示「無法驗證開發者」。支援 macOS 12 及以上，Apple 晶片和 Intel 均可。

<p align="center">
  <img src="docs/installer-zh.png" width="620" alt="Mac mini 模式安裝器">
</p>

## 它做什麼

把 MacBook 放在家裡當 Mac mini、家用伺服器或無頭主機用：合蓋不休眠，不需要外接顯示器或 HDMI 假負載，也不用記著敲 `caffeinate` 或 `sudo pmset disablesleep`。它跟隨電源介面卡自動開關，所以 MacBook 不會在包裡一直醒著。

- **插電自動開啟**：接入電源後不再睡眠，合蓋、不接顯示器也照常執行。
- **拔電自動關閉**：切到電池立即恢復正常睡眠；已合蓋則直接入睡。
- **選單列切換**：「插電時不睡眠」「插電或用電池都不睡眠」「照系統設定睡眠」三種模式，當前狀態一眼可見。
- **退出並恢復睡眠**：主動退出時切換到「照系統設定睡眠」，確認已允許睡眠後再退出。再次插電或重啟也不會自動開啟，需重新選擇「插電時不睡眠」或「插電或用電池都不睡眠」。系統登出、重啟或關機保留所選模式。其他電源設定不變。
- **合蓋熄屏**：合上蓋子後自動關掉螢幕背光，開蓋恢復原來的亮度。只關背光，不會鎖屏，也不會打斷遠端桌面或正在執行的應用。接著外接顯示器時不會動它。可在選單裡關閉。
- **診斷**：一鍵檢查遠端登入、螢幕共享、電池和電源設定是否就緒，並可複製診斷資訊用於回報。
- **低電量保護**：「插電或用電池都不睡眠」時用電池，電量降到 10% 會自動放行睡眠，不會硬撐到斷電。
- **命令列**：`macminimode status`、`macminimode on|off|auto`，也可以在快捷指令裡用「執行 Shell 指令碼」呼叫。

## 更新

應用每天會向 GitHub 查一次有沒有新版本。有的話會自動下載、校驗簽名，然後彈窗問你要不要安裝；點「安裝」會開啟系統安裝器。不想自動檢查，可以在選單裡取消勾選「自動檢查更新」，需要時再點「檢查更新…」。

## 遇到問題

先升級到最新版。如果合蓋後還是會睡，點選單列圖示裡的「診斷…」，再點「複製診斷資訊」，把內容貼到 [Issues](../../issues)。常見原因是遠端桌面或清理類軟體會定時改電源設定，新版會自動改回去，並在日誌裡記一筆。

開蓋後螢幕如果還是黑的（極少見，比如合蓋期間應用被強制結束），按鍵盤上的亮度增加鍵（F2）就能恢復；遠端連著的話也可以執行 `macminimode screen-on`。

## 解除安裝

```bash
sudo /Applications/MacMiniMode.app/Contents/Resources/uninstall.sh
```

## 許可

[MIT](LICENSE)
