---
date: "2026-11-18"
updated: "2026-11-23"
---

# 星记开发交接

Windows 和 Android 共用 Flutter 业务层。编辑先写入本机 SQLite，启用同步后才向 PostgreSQL 发送业务密文。本文记录源码入口、影响数据兼容的规则和版本验收结果。安装与操作见[使用说明](USER_GUIDE.md)，复现测试和打包见[构建说明](BUILD.md)。

## 源码入口

| 修改什么 | 从哪里看 |
| --- | --- |
| 启动、设备资料目录、后台同步 | [正式入口](../lib/main.dart)、[设备服务](../lib/platform/device_services.dart)、[后台同步](../lib/platform/background_sync.dart)。Android 后台任务使用 `backgroundSync` VM 入口。 |
| 事项、时间与清单 | [数据模型](../lib/core/models.dart)、[控制器](../lib/core/app_controller.dart)、[今天清单](../lib/core/today_agenda.dart)、[按日期查看](../lib/core/dated_memos.dart)。 |
| 编辑、图片与平台布局 | [共用编辑器](../lib/ui/memo_editor.dart)、[图片组件](../lib/ui/memo_images.dart)、[桌面工作区](../lib/ui/workspace.dart)、[移动工作区](../lib/ui/mobile_workspace.dart)。 |
| 存储、密钥与同步 | [SQLite 与事务](../lib/core/local_store.dart)、[密钥包装与认证加密](../lib/core/vault_crypto.dart)、[同步引擎](../lib/core/sync_engine.dart)、[数据库结构与部署](../database/README.md)。 |
| 系统提醒与剪贴板 | [双端提醒排程](../lib/platform/desktop_service.dart)、[Windows 原生桥接](../windows/runner/desktop_bridge.cpp)、[Android 原生实现](../android/app/src/main/kotlin/app/xingji/memo/)。 |
| 构建、打包与路径解析 | [Windows 发布脚本](../tool/build.ps1)、[Android 发布脚本](../tool/build_android.ps1)、[路径解析](../tool/paths.ps1)、[发布流程](RELEASING.md)。 |

## 编辑、归档与历史

- 首页只列设备本地“今天”的未完成事项。未过时、已过时两组各按重要程度和时间排列。搜索和筛选作用于备忘录列表。日期页按设备自然日分组，未完成项看提醒时间，已完成项默认看实际完成时间。
- 提醒编辑按事项时区显示。`calendarOnly` 与 24 小时制的 `dialOnly` 分别处理日期与时间，确认后才由 `setDue` 转为 UTC。到点、跨天和回到前台时刷新投影。
- 编辑器有 650 毫秒防抖，并串行处理保存。自动保存更新当前内容，显式“保存并返回”才留下历史版本。每条最多 30 版，相邻内容相同会去重。恢复前校验预览所对应的版本，原内容、恢复结果和待同步修改在同一事务中保存，完成状态和回收站状态沿用当前值。
- 重复事项完成时，将本次归档和下一次安排一起写入。普通删除进入回收站。永久删除会清理本机记录、历史、待发修改和提醒，并保留带认证的删除标记，防止旧备份或离线副本复活。

## 存储与同步

- SQLite 结构为 v3。`records`、`history`、`outbox` 分别保存当前密文、历史和待上传操作。图片单独存入 `attachments` 和 `attachment_chunks`，`memo_images` 保存带认证的本机引用。归档和冲突副本可共享图片，最后一个引用移除后回收密文。
- 业务字段使用 XChaCha20-Poly1305 加密，身份信息纳入认证。主密码通过 Argon2id 包装资料库密钥。改密会重新包装，既有备份仍可用原密码打开。数据库中可见记录标识、游标、时间与密文长度等元数据。
- PostgreSQL API 为 v2。授权依据是 `session_user` 和 `vault_access`。先发送永久删除，再发送普通修改。操作 ID 用于幂等，基础版本用于检测冲突。拉取时先核对整页认证及游标连续性，再提交 SQLite 事务。通知仅提示有变化，断线后从持久游标续传。v1 服务端的永久删除保持排队，升级路径见[数据库部署](../database/README.md)。
- Android 的免密期从验证主密码或恢复码时开始计算，固定为 72 小时。手动锁定会暂停后台补同步，到期重新验证只影响前台解锁。设备密钥保护使用 Windows DPAPI 或 Android Keystore。平台解包返回可清理的字节副本。[免密规则](../lib/core/device_trust_policy.dart) · [设备服务](../lib/platform/device_services.dart)

## 本机图片

Windows 原生层在启动和剪贴板变更时检查 PNG、DIB、DIBV5 格式，向 Dart 发送可用状态。标题或正文收到 `Ctrl+V` 后才读取图片字节。缓存为空或显示无图时会再查一次格式，覆盖快捷键先于系统通知到达的情况。纯文本走文本框原有粘贴动作。Android 保留相册和粘贴按钮。

图片在内存中校正方向、重新编码后分块加密。源图最多 32 MiB，处理后最多 8 MiB，长边最多 2048 像素，每条最多 9 张，每库最多 500 MiB。当前附件只在本机保存，未纳入同步、文字修改历史或加密备份。[处理流程](../lib/platform/image_processing.dart) · [附件约束](../lib/core/image_attachment.dart)

## 原生提醒

| Android 排程 | 到点行为 |
| --- | --- |
| 事项单独开启闹铃 | 全局时钟开关和夜间静默均让位于事项时间。亮屏、息屏都请求系统时钟启动 1 秒倒计时。 |
| 普通事项开启全局时钟提醒 | 亮屏通过通知渠道给出一次提示音，息屏交给系统时钟。 |
| 仅开启本机提醒 | 走普通通知，遵循静默时段。 |

`AlarmManager` 保存完整的触发日期和代次。改期、完成和取消要撤销旧排程，接收端再核对到点时间。时钟交接按事项和触发时刻去重，`request_sent` 仅表示请求已发出。Android 10 及以上在后台启动时钟涉及系统授权，失败时回退至普通通知。重启后恢复未来排程，错过的事项补普通通知。[排程与通知](../android/app/src/main/kotlin/app/xingji/memo/Reminders.kt) · [系统时钟交接](../android/app/src/main/kotlin/app/xingji/memo/SystemClockReminders.kt)

Windows 的通知、托盘和协议激活由原生桥接处理。通知动作要匹配当前排程，锁定后操作需要先解锁。Android 后台补同步使用 JobScheduler，和前台同步共用互斥控制。

## 发布与验收记录

### 0.5.1 · 2026-11-20

本版的提醒日期与时间选择器、Windows 编辑框图片粘贴均已验收。

| 项目 | 已核对的结果 |
| --- | --- |
| 提醒日期与时间 | 双端工作流覆盖翻月选日、取消保留原值、小时切到分钟和事项时区跨 UTC 日期保存。Android API 26 模拟器完成触屏选日、拨盘确认与取消。 |
| Windows 图片粘贴 | 正文实测粘贴截图后显示缩略图，Chrome 复制图片可导入，普通文字可粘贴到标题和正文。快捷键回归另覆盖标题粘图、焦点范围、剪贴板通知晚到、处理中重复按键、损坏图片和配额。Android 编辑页保留两个导入按钮。[工作流回归](../test/workflow_test.dart) · [图片专项](../test/image_attachment_test.dart) |
| 自动检查 | 静态分析通过，默认 Flutter 回归通过 73 项，另有 5 项独立数据库用例按默认配置跳过。 |
| Windows 构建 | 安装器和程序文件版本均为 `0.5.1.9`。当时的 ZIP 中，安装器和安装说明逐字节核对通过。 |
| Android 构建 | 构建号 16，当时的 APK v2 签名通过原发布证书校验。含 ARMv7、ARM64、x86_64 三种架构，分发 APK 与该次构建输出一致。 |

### 早期版本

| 版本 | 已交付的改动与验证范围 |
| --- | --- |
| 0.5.0 | 双端加入本机图片、分块加密、配额与引用回收，SQLite 升为 v3。静态分析和 73 项 Flutter 测试通过，该轮包含 5 项隔离 PostgreSQL/TLS 用例。 |
| 0.3.6 | Android 全局闹铃增加亮屏通知、息屏交给时钟的分流。模拟器验证通知和时钟请求。修改历史加入显式保存、预览与事务恢复。 |
| 0.3.2–0.3.5 | Android 先修正到点重排和旧广播误触发，再引入前台 10 秒时钟测试，最后将正式事项接入系统时钟。API 26 模拟器观察到息屏后倒计时结束界面。实际扬声器声音和厂商后台策略属于真机验收项，需在真机上逐条确认。 |
| 0.3.0–0.3.1 | 已验证永久删除同步、旧备份防复活、数据库 v2 升级、双端密文互通和 Android 三天免密边界。 |
