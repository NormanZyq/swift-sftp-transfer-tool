# SSH 文件传输（原生 Swift 版）

从 Python/PySide6 版重写的**原生 macOS** SFTP 双窗格文件传输工具。基于
[Citadel](https://github.com/orlandos-nl/Citadel)（纯 Swift，async/await，构建于 Apple 的
swift-nio-ssh 之上）。

## 依赖

- macOS 14+
- Swift 6.x / Xcode（仅构建时需要）
- 运行时**无外部依赖**：Citadel/NIO 等全部静态链入二进制（不再依赖 miniconda/Python）

## 构建与运行

**打包成可双击的 app（推荐）**
```bash
./make-app.sh          # 生成「SSH 文件传输.app」
open "SSH 文件传输.app" # 或双击；可拖到 /Applications
```

**开发时直接跑**
```bash
swift run
```

**用 Xcode**
```bash
open Package.swift   # 按 Run
```

## 功能（v1）

- 启动从 `~/.ssh/config` 读取 host 列表，下拉选择后连接
- 左本地 / 右远程双窗格浏览；工具栏**导航簇**：◀ 后退 / ▶ 前进（浏览历史）/ ↑ 上级 / ⌂ 主目录 / ⟳ 刷新
- 本地面板 **📍「位置」菜单**：一键跳转 主目录 / iCloud 云盘 / 桌面 / 文档 / 下载，并列出**已挂载的外接磁盘**（当前位置带勾；未启用的位置如 iCloud 自动隐藏）
- **点击列头排序**（名称 / 大小 / 修改时间，可升降切换；目录恒排在前）
- 多选 + 按钮 / 右键菜单批量上传 / 下载，**目录递归传输**，底部进度条 + 队列进度 + 日志
- **底部「传输状态」栏可折叠**（点标题箭头收起 / 展开，状态记忆；**传输时自动展开、完成后自动收起**）
- 传输结束以**轻量提醒**（底部一角的半透明胶囊，自动淡出）显示成功 / 失败 / 取消结果
- **传输可随时取消**（在文件之间或大文件传输途中均能尽快停止）
- 两侧**新建文件夹 / 重命名 / 删除**（本地删除进废纸篓；远程递归删除，均有确认）
- 每个面板**搜索框**：默认过滤当前目录；点 🔍 切到**递归搜索**，回车在子目录中查找（最多 2000 条）
- 工具栏 **⋯ 菜单**收纳次要操作：新建文件夹、显示隐藏文件开关、（本地）在访达中打开当前目录
- 本地右键 **在访达中打开**（目录→打开，文件→在访达中选中）
- 拖拽：访达 / 本地行 → 「远程」面板（上传）；**远程行 → 「本地」面板（下载）**；本地行亦可拖到访达
- ed25519 / rsa 私钥登录；带口令的私钥弹窗输入（口令只在内存用于解密，不保存）

## 安全

- **主机指纹校验**：严格比对 `~/.ssh/known_hosts`（明文与哈希条目都支持）。未知主机弹窗显示
  SHA256 指纹、确认后才信任并写入 known_hosts；与记录不符则拒绝（疑似中间人）。
  —— 比 Python 版的 `AutoAddPolicy`（静默接受任何主机）更安全。
- 私钥只在本地读取，绝不外传；日志不记录任何密钥/口令。
- 仅使用现代算法（ed25519 / AES-GCM / x25519，源自 swift-nio-ssh）。

## 已知限制 / 下一步

- **ProxyJump（跳板机）**：Citadel 自带 `jump(to:)`，可逐跳保留 known_hosts 校验，技术上可行；
  因触及连接 / 认证路径、需真实双主机验证，暂按需再实现。
- **ssh-agent**：Citadel 无 agent 客户端，且底层 NIOSSH 的认证 offer 无「外部签名器」钩子，
  暂不易支持；当前密钥（含带口令）登录已覆盖常见需求。
- 拖拽多选：当前行拖拽为单条目（从名称单元格发起）；如需多选拖拽可后续加。

## 结构

```
Sources/SFTPTransfer/
  SFTPTransferApp.swift     @main 入口
  AppCommands.swift         菜单/快捷键
  Models/
    SSHConfig.swift         ~/.ssh/config 解析
    PrivateKeyLoader.swift  私钥加载 → 认证方式
    KnownHosts.swift        known_hosts 校验 + 校验器
    SFTPSession.swift        actor：封装 SSH/SFTP，串行化单通道
    FileItem.swift          统一文件条目模型
    LocalFileSystem.swift   本地文件操作
    TransferEngine.swift    传输队列 + 目录展开 + 进度
    AppModel.swift          顶层状态 + 连接流程
    PaneModel.swift         单面板状态与增删改
  Views/
    ContentView.swift       顶栏 + 双窗格 + 进度/日志 + 弹窗
    FilePaneView.swift      单个文件面板
```
