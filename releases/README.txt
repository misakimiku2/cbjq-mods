　　尘白禁区 · 滚轮镜头缩放 Mod　v87
　　=====================================

　功能
　　· 滚轮向前 = 镜头拉近，向后 = 拉远（基准约 3.2m，可拉到约 0.95m、拉远到约 5.8m）
　　· 拉近到人物居中时，界面会自动淡出（只剩画面和角色），开镜时自动恢复
　　· 开镜、切人、起跑演出时模组会自动让位，不与游戏自带的镜头动作打架

　安装（两步）
　　1) 把 Patch_CamZoomMod-Windows_100_P.pak 复制到游戏的 Paks 目录：
　　　　 <游戏安装目录>\Game\cbjq\game\Game\Content\Paks\
　　　　 例如 E://SeasunCBJQos//Game//cbjq//game//Game//Content//Paks//
　　2) 双击 CamZoomSniffer.exe，弹 UAC 时点"是"

　为什么需要那个 exe
　　游戏本身没有滚轮轴映射（Input.ini 里 0 条 AxisMapping），Lua 侧读不到滚轮，
　　所以必须有一个外部程序把滚轮事件写出来给模组读。它同时要管理员权限
　　（游戏是管理员进程，Windows 的 UIPI 会让低权限钩子收不到游戏的输入）。

　它安全吗
　　· 只在后台监听滚轮方向，不联网、不读写游戏内存、不改任何系统设置
　　· 只在 Game.exe 运行时才挂键盘/鼠标钩子，游戏退出立即卸载
　　· 不玩游戏时可以随时在任务管理器结束 pythonw.exe / CamZoomSniffer.exe

　使用
　　1. 先启动 CamZoomSniffer.exe（一次即可，之后它一直挂在后台）
　　2. 启动游戏
　　3. 进到可以自由走动的场景后，滚一下滚轮 —— 模组会自动完成标定
　　4. 之后滚轮就能推拉镜头了

　没有反应时
　　打开 C://ProgramData//CamZoomMod// 看这几个文件：
　　· sniffer_state.txt  hooks=on 表示钩子已挂上；elevated=1 表示管理员权限正常
　　· wheel.txt          滚轮时里面的序号会增长，说明事件已被捕获
　　· sniffer_beat.txt   每 2 秒递增，停住不动说明 exe 已经退出了
　　如果 elevated=0，说明没用管理员权限运行，右键"以管理员身份运行"。

　卸载
　　1. 删掉 Paks 目录里的 Patch_CamZoomMod-Windows_100_P.pak
　　2. 在任务管理器结束 CamZoomSniffer.exe
　　3. （可选）删掉 C://ProgramData//CamZoomMod 文件夹

　　本模组只改镜头位置，不修改任何游戏数据。
