# 左右面板统一与通用传输设计备忘

本文记录一个未来可选的大改造方向：不再把左侧固定为本地、右侧固定为远程，而是让两侧面板都可以承载本地或远程 tab，并由传输层自动判断“本地 / 远程”的组合，执行对应的数据传输。

这不是当前已实现的行为，只是需求与技术路线记录，便于以后按需拆分任务。

## 目标行为

- 左右两侧都可以打开本地 tab 或远程服务器 tab。
- 两侧 tab 支持相互拖拽文件 / 文件夹。
- 传输时自动判断源端和目标端类型：
  - 本地 -> 本地：本机文件复制。
  - 本地 -> 远程：上传。
  - 远程 -> 本地：下载。
  - 远程 -> 远程：两台服务器互传，优先通过本机流式中转。
- 顶部或面板工具栏不再使用“上传 / 下载”这种方向固定的概念，而是更通用的“传输到另一侧”。
- 传输进度、取消、日志、失败提示仍然沿用当前体验。

## 现有架构约束

当前代码仍有明显的左右角色假设：

- `AppModel.localTabs` 固定是本地 `PaneModel`。
- `AppModel.remoteTabs` 固定是 `RemoteTab`。
- `ContentView` 左侧绑定 `activeLocalPane`，右侧绑定 `activeRemoteTab?.pane`。
- `FilePaneView` 的拖放逻辑按面板 `kind` 分支：
  - 本地 / Finder -> 远程 = 上传。
  - 远程 -> 本地 = 下载。
- `TransferEngine` 主要围绕“本地路径 + 一个远程 session”的上传 / 下载模型工作。
- `SFTPSession` 已经是 actor，适合作为远程端串行 I/O 边界，但目前没有暴露“从一个远程 session 分块读，再写入另一个远程 session”的高级传输接口。

因此，这个需求不适合只在现有 `uploadSelection()` / `downloadSelection()` 上继续加分支。更稳妥的方式是先抽象传输端点，再让 UI 使用统一端点模型。

## 建议核心抽象

引入统一的“面板端点”概念，而不是让左右侧本身代表本地或远程。

```swift
enum PaneEndpoint {
    case local
    case remote(RemoteTab)
}
```

每个 tab 可以进一步抽象为：

```swift
final class BrowserTab: Identifiable {
    enum Kind {
        case local(PaneModel)
        case remote(RemoteTab)
    }
}
```

左右两侧则变成两个 tab 容器：

```swift
final class PaneColumnModel {
    var tabs: [BrowserTab]
    var selectedIndex: Int
}
```

这样，“左 / 右”只表示视觉位置，不再表示传输语义。

## 传输端点模型

传输层建议从“上传 / 下载”改为“源端 -> 目标端”。

```swift
enum TransferEndpoint {
    case local
    case remote(session: SFTPSession)
}

struct TransferItem {
    var endpoint: TransferEndpoint
    var path: String
    var name: String
    var isDirectory: Bool
}

struct TransferRequest {
    var source: TransferItem
    var destinationDirectory: TransferEndpointDirectory
}
```

实际实现可以更贴合现有代码，但方向应是：`TransferEngine` 不关心左右侧，只关心源端类型、目标端类型和路径。

## 四种传输路径

### 本地 -> 本地

使用 `FileManager` 递归复制。

需要处理：

- 目标路径已存在。
- 目录递归。
- 权限错误。
- 是否覆盖、跳过或自动重命名。

### 本地 -> 远程

可以复用现有上传逻辑：

- 本地目录展开仍用 `FileManager.enumerator`。
- 远程父目录仍用 `makeDirectoryRecursive`。
- 文件写入仍走 `SFTPSession.upload`。

### 远程 -> 本地

可以复用现有下载逻辑：

- 远程目录展开仍用 `session.walkFiles`。
- 本地父目录用 `FileManager.createDirectory`。
- 文件读取仍走 `SFTPSession.download`。

### 远程 -> 远程

推荐通过本机流式中转，而不是先完整下载到临时文件再上传。

推荐流程：

1. 源服务器 `walkFiles` 展开文件列表。
2. 目标服务器按需创建目录。
3. 对每个文件：
   - 从源 `SFTPSession` 打开远程文件读取。
   - 从目标 `SFTPSession` 打开远程文件写入。
   - 按固定 chunk 大小读写，例如 256 KB。
   - 每个 chunk 更新进度并检查取消。
4. 文件结束后关闭两端句柄，进入下一个文件。

这种方式仍然“通过本机中转”，但不会把完整文件落盘到本机，磁盘占用低，取消也更可控。

备选快速方案是“下载到临时目录 -> 上传到目标 -> 清理临时文件”。这个方案实现快，但风险更高：

- 大文件会占用本机磁盘。
- 中途失败要清理临时文件。
- 进度会天然分成下载和上传两段。
- 传输速度受临时磁盘和两段串行流程影响。

不论是哪个方案，在初次做远程-远程操作的时候，需要提示用户将通过本机中转，会产生在本机硬盘上的读写，并说明下次传输1GB以内的文件或目录时将不再提醒（1GB以上依然提醒用户）。

## SFTPSession 需要新增的能力

为了支持远程 -> 远程流式中转，`SFTPSession` 可以新增 actor 方法：

```swift
func copyFileToRemote(
    sourcePath: String,
    destinationSession: SFTPSession,
    destinationPath: String,
    progress: @Sendable @escaping (Int64, Int64) -> Void
) async throws
```

不过要注意：一个 actor 方法内部再调用另一个 actor，会形成两个远程 session 的协作。更清晰的做法可能是把“读 chunk / 写 chunk”拆成较小的 actor 方法，由 `TransferEngine` 负责调度：

```swift
func openReadHandle(path: String) async throws -> RemoteReadHandle
func openWriteHandle(path: String) async throws -> RemoteWriteHandle
func readChunk(handle: RemoteReadHandle, size: Int) async throws -> Data
func writeChunk(handle: RemoteWriteHandle, data: Data) async throws
func closeHandle(...)
```

但如果 Citadel 的文件句柄类型不适合跨 actor 暴露，则应把单文件复制封装在一个协调方法里，避免把非 `Sendable` 句柄传出 actor。

最终选择需要看 Citadel 文件句柄类型的并发约束。

## 拖拽数据模型

当前远程拖拽使用 `RemoteItemRef`，本地拖拽使用 `URL`。统一后建议新增：

```swift
enum TransferItemRef: Transferable, Sendable {
    case local(path: String, name: String, isDirectory: Bool)
    case remote(tabID: UUID, path: String, name: String, isDirectory: Bool)
}
```

需要注意：

- `Transferable` 的编码需要稳定。
- 远程 ref 需要能通过 `tabID` 找回所属 `RemoteTab` / `SFTPSession`。
- 如果用户拖拽后关闭源 tab，应拒绝传输并给出错误。
- `RemoteItemRef` 当前声明了私有 UTType；统一类型时要同步更新 `Models/RemoteItemRef.swift` 和 `make-app.sh` 里的 `UTExportedTypeDeclarations`，或新增一个新的 UTType。

## UI 调整方向

建议先保持双栏布局，但改变语义：

- 左右栏都显示“tab 栏 + 文件面板”。
- `+` 菜单可以提供：
  - 新建本地 tab。
  - 打开远程连接。
- 面板标题 / tab 图标标明本地或远程。
- 传输按钮改为：
  - “传输到右侧”
  - “传输到左侧”
- 拖放时以 drop 目标面板作为目标端，drag 源 ref 作为源端。

不建议一开始就做复杂的多源多目标 UI。先保证“当前选中项 -> 另一侧当前目录”稳定，再扩展批量和跨 tab 拖拽。

## 分阶段实施建议

### 阶段 1：改造 TransferEngine

目标：传输层支持四种端点组合，但 UI 暂时仍保持左本地、右远程。

任务：

- 定义 `TransferEndpoint` / `TransferItem` / `TransferRequest`。
- 将现有 upload / download 迁移到新模型。
- 增加本地 -> 本地复制。
- 增加远程 -> 远程的最小可用实现。

验收：

- 现有上传 / 下载行为不回归。
- 单文件和目录传输可取消、可记录日志。

### 阶段 2：统一拖拽 ref

目标：拖拽系统不再依赖“本地 URL vs 远程 RemoteItemRef”的二分。

任务：

- 新增统一 `TransferItemRef`。
- 本地和远程行都提供统一 draggable payload。
- drop 目标根据自己的 endpoint 调用统一传输入口。

验收：

- 本地 -> 远程拖拽仍可用。
- 远程 -> 本地拖拽仍可用。
- 同侧本地 -> 本地、远程 -> 远程具备基础路径。

### 阶段 3：统一左右 tab 容器

目标：左右两侧都能开本地或远程 tab。

任务：

- 引入 `BrowserTab` 或等价类型。
- 将 `localTabs` / `remoteTabs` 迁移为两个 `PaneColumnModel`。
- `ContentView` 不再使用 `activeLocalPane` / `activeRemoteTab` 这种固定语义。
- 顶栏服务器选择器重新定位，可能改到单个 tab 的连接配置区域。

验收：

- 左右任意组合都能浏览。
- 左右任意组合都能发起传输。
- 切 tab、关 tab、断开连接不会影响其他 tab。

### 阶段 4：体验与边界完善

目标：让功能适合真实使用。

任务：

- 同名冲突策略：覆盖、跳过、保留两者。
- 远程 -> 远程断线和权限错误处理。
- 传输中关闭源 / 目标 tab 的处理。
- 大文件进度、速度、剩余时间。
- 临时文件方案时的清理机制；流式方案时的句柄关闭保障。

## 复杂度评估

- 快速原型：约 1 天。
  - 可以验证远程 -> 远程是否能跑通。
  - 不保证 UI 完整，也不保证所有边界处理。

- 可用版本：约 2 到 4 天。
  - 四种传输组合完整。
  - 目录递归、取消、日志、基础错误提示可用。
  - UI 仍可能比较保守。

- 稳健版本：约 5 天以上。
  - 完整 tab 统一。
  - 远程互传流式中转。
  - 同名冲突、断线、关闭 tab、权限错误等边界都处理。

## 主要风险

- 现有 `AppModel`、`ContentView`、`FilePaneView` 对“左本地右远程”的假设较多，直接硬改容易造成状态混乱。
- 远程 -> 远程需要两个 `SFTPSession` 协作，必须小心 actor 边界和 Citadel 句柄的 `Sendable` 约束。
- 传输中关闭 tab 或断开连接需要明确策略。
- 拖拽 payload 需要能稳定定位源 tab，否则远程文件来源会丢失。
- 同名冲突如果不先设计，会在四种传输路径里重复出现。

## 建议结论

这个需求技术上可行，但应按架构改造处理。

推荐顺序是：

1. 先统一传输层端点模型。
2. 再统一拖拽数据模型。
3. 最后统一左右两侧 tab 容器。

不建议直接把远程互传逻辑塞进当前 `uploadSelection()` / `downloadSelection()`，否则短期能跑，后续会明显增加维护成本。
