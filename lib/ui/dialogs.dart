import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/sync_engine.dart';
import '../platform/device_services.dart';
import 'memo_actions.dart';
import 'theme.dart';

Future<ConnectionConfig?> connectionDialog(
  BuildContext context,
  ConnectionConfig? value,
) => showDialog<ConnectionConfig>(
  context: context,
  builder: (_) => ConnectionDialog(value: value),
);

class ConnectionDialog extends StatefulWidget {
  const ConnectionDialog({super.key, this.value});
  final ConnectionConfig? value;
  @override
  State<ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<ConnectionDialog> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name,
      host,
      port,
      database,
      username,
      password,
      ca;
  late bool tls, remember;
  bool busy = false, obscure = true, success = false;
  String? result;
  @override
  void initState() {
    super.initState();
    final v = widget.value ?? ConnectionConfig();
    name = TextEditingController(text: v.name);
    host = TextEditingController(text: v.host);
    port = TextEditingController(text: '${v.port}');
    database = TextEditingController(text: v.database);
    username = TextEditingController(text: v.username);
    password = TextEditingController(text: v.password);
    ca = TextEditingController(text: v.caPath);
    tls = v.tls;
    remember = v.remember;
  }

  @override
  void dispose() {
    for (final c in [name, host, port, database, username, password, ca]) {
      c.dispose();
    }
    super.dispose();
  }

  ConnectionConfig config() => ConnectionConfig(
    name: name.text.trim(),
    host: host.text.trim(),
    port: int.tryParse(port.text) ?? 0,
    database: database.text.trim(),
    username: username.text.trim(),
    password: password.text,
    caPath: ca.text.trim(),
    tls: tls,
    remember: remember,
  );
  Widget field(
    TextEditingController c,
    String label, {
    bool required = false,
    bool secret = false,
  }) => TextFormField(
    controller: c,
    obscureText: secret && obscure,
    autocorrect: false,
    enableSuggestions: !secret,
    validator: (value) =>
        required && (value?.trim().isEmpty ?? true) ? '请填写$label' : null,
    decoration: InputDecoration(
      labelText: label,
      suffixIcon: secret
          ? IconButton(
              onPressed: () => setState(() => obscure = !obscure),
              icon: Icon(
                obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
              ),
            )
          : null,
    ),
  );
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: SizedBox(
      width: 590,
      child: Padding(
        padding: EdgeInsets.all(
          MediaQuery.sizeOf(context).width < 600 ? 18 : 28,
        ),
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '连接 PostgreSQL',
                        style: TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        DeviceServices.mobile
                            ? '填写电脑的局域网或 VPN 地址，连接已有的加密资料库。'
                            : '连接你自己的数据库，自动同步加密内容。',
                        style: TextStyle(color: colorsOf(context).muted),
                      ),
                      SizedBox(height: 22),
                      field(name, '连接名称'),
                      SizedBox(height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: field(host, 'IP 或域名', required: true),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: port,
                              keyboardType: TextInputType.number,
                              validator: (v) {
                                final p = int.tryParse(v ?? '');
                                return p == null || p < 1 || p > 65535
                                    ? '端口无效'
                                    : null;
                              },
                              decoration: InputDecoration(labelText: '端口'),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: field(database, '数据库名', required: true),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: field(username, '用户名', required: true),
                          ),
                        ],
                      ),
                      SizedBox(height: 14),
                      field(password, '数据库密码', secret: true),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: tls,
                        onChanged: (v) => setState(() => tls = v),
                        title: Text('TLS 加密与证书校验'),
                        subtitle: Text(
                          '校验证书链与主机名',
                          style: TextStyle(
                            color: colorsOf(context).muted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      if (tls)
                        Row(
                          children: [
                            Expanded(child: field(ca, 'CA 证书（可选，默认系统信任库）')),
                            SizedBox(width: 8),
                            IconButton(
                              tooltip: '选择 CA PEM 文件',
                              onPressed: () async {
                                final file = await DeviceServices.pickFile(
                                  certificate: true,
                                );
                                if (file != null && mounted) {
                                  setState(() => ca.text = file);
                                }
                              },
                              icon: Icon(Icons.folder_open_outlined),
                            ),
                          ],
                        ),
                      if (!tls)
                        Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Text(
                            '已关闭传输加密。仅用于你信任的本机、局域网或 VPN 测试。',
                            style: TextStyle(
                              color: colorsOf(context).danger,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: remember,
                        onChanged: (v) => setState(() => remember = v!),
                        title: Text('记住连接信息', style: TextStyle(fontSize: 13)),
                        subtitle: Text(
                          '数据库密码由 ${DeviceServices.protection} 保护',
                          style: TextStyle(
                            fontSize: 11,
                            color: colorsOf(context).muted,
                          ),
                        ),
                      ),
                      if (result != null)
                        Padding(
                          padding: EdgeInsets.only(bottom: 14),
                          child: Text(
                            result!,
                            style: TextStyle(
                              color: success
                                  ? colorsOf(context).cyan
                                  : colorsOf(context).danger,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            if (!form.currentState!.validate()) return;
                            setState(() {
                              busy = true;
                              result = null;
                            });
                            try {
                              final text = await SyncEngine.test(config());
                              if (mounted) {
                                setState(() {
                                  result = text;
                                  success = true;
                                });
                              }
                            } catch (e) {
                              if (mounted) {
                                setState(() {
                                  result = safeError(e);
                                  success = false;
                                });
                              }
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                    icon: busy
                        ? SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.cable, size: 17),
                    label: Text('测试连接'),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => Navigator.pop(context),
                    child: Text('取消'),
                  ),
                  SizedBox(width: 8),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () {
                            if (form.currentState!.validate()) {
                              Navigator.pop(context, config());
                            }
                          },
                    child: Text('使用此连接'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<({String secret, bool recovery})?> secretDialog(
  BuildContext context, {
  String title = '解锁资料库',
  bool allowRecovery = true,
  bool newPassword = false,
}) async {
  final controller = TextEditingController();
  final confirm = TextEditingController();
  bool recovery = false;
  String? error;
  final result = await showDialog<({String secret, bool recovery})>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                obscureText: true,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: recovery
                      ? '恢复码 XJ1.…'
                      : newPassword
                      ? '新的主密码（至少 10 个字符）'
                      : '资料库主密码',
                ),
              ),
              if (newPassword) ...[
                SizedBox(height: 12),
                TextField(
                  controller: confirm,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(labelText: '再次输入主密码'),
                ),
              ],
              if (allowRecovery)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('使用恢复码', style: TextStyle(fontSize: 12)),
                  value: recovery,
                  onChanged: (v) => setState(() => recovery = v!),
                ),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(
                    color: colorsOf(context).danger,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.isEmpty ||
                  (newPassword && controller.text.length < 10)) {
                setState(() => error = '请填写有效的主密码');
                return;
              }
              if (newPassword && confirm.text != controller.text) {
                setState(() => error = '两次输入不一致');
                return;
              }
              Navigator.pop(context, (
                secret: controller.text,
                recovery: recovery,
              ));
            },
            child: Text('确认'),
          ),
        ],
      ),
    ),
  );
  controller.clear();
  confirm.clear();
  controller.dispose();
  confirm.dispose();
  return result;
}

Future<void> exportBackup(BuildContext context, AppController app) async {
  final bytes = Uint8List.fromList(utf8.encode(app.exportBackup()));
  final saved = await DeviceServices.saveBackup(
    '星记备份_${DateTime.now().toIso8601String().substring(0, 10)}.xingji',
    bytes,
  );
  if (!saved) return;
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('加密备份已保存。恢复时需要主密码或恢复码。')));
  }
}

Future<void> showHistory(
  BuildContext context,
  AppController app,
  Memo memo,
) async {
  final packets = app.store.history(memo.id);
  final versions = packets.map(app.crypto.decrypt).toList();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('修改历史'),
      content: SizedBox(
        width: 560,
        height: 390,
        child: Column(
          children: [
            const Text('点击保存才生成编辑版本，相同内容不重复记录。自动保存仍保护当前内容；本机保留最近 30 个版本。'),
            const SizedBox(height: 12),
            Expanded(
              child: versions.isEmpty
                  ? Center(
                      child: Text(
                        '还没有历史版本',
                        style: TextStyle(color: colorsOf(context).muted),
                      ),
                    )
                  : ListView.separated(
                      itemCount: versions.length,
                      separatorBuilder: (_, _) => Divider(),
                      itemBuilder: (context, index) {
                        final version = versions[index];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              version.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${dateLabel(version.updatedAt, full: true)}\n${version.body}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colorsOf(context).muted,
                                fontSize: 12,
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () async {
                                  final restored = await previewHistoryVersion(
                                    context,
                                    app,
                                    memo.id,
                                    packets[index],
                                  );
                                  if (restored && dialogContext.mounted) {
                                    final messenger = ScaffoldMessenger.of(
                                      dialogContext,
                                    );
                                    Navigator.pop(dialogContext);
                                    messenger.showSnackBar(
                                      const SnackBar(
                                        content: Text('已恢复，恢复前的内容保留在修改历史中'),
                                      ),
                                    );
                                  }
                                },
                                child: const Text('预览与恢复'),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text('关闭'),
        ),
      ],
    ),
  );
}

Future<bool> previewHistoryVersion(
  BuildContext context,
  AppController app,
  String id,
  CipherRecord packet,
) async {
  final version = app.crypto.decrypt(packet);
  final expected = app.store.get(id)?.packet.operationId ?? '';
  var busy = false;
  String? error;
  return await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: const Text('版本预览'),
            scrollable: true,
            content: SizedBox(
              width: 540,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dateLabel(version.updatedAt, full: true)),
                  const SizedBox(height: 12),
                  SelectableText(
                    version.title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(version.body.isEmpty ? '未填写正文' : version.body),
                  for (final item in version.checklist)
                    Text('${item.done ? '☑' : '☐'} ${item.text}'),
                  const Divider(),
                  Text(
                    '标签：${version.tags.isEmpty ? '无' : version.tags.join('、')}',
                  ),
                  Text(
                    '优先级：${priorityLabel(version.priority)} · ${version.pinned ? '置顶' : '未置顶'}',
                  ),
                  Text(
                    '提醒：${version.dueAt == null ? '未设置' : dateLabel(version.dueAt!, full: true)}（本机时间）',
                  ),
                  Text(
                    '事项时区：${version.timezone} · 重复：${recurrenceLabel(version.recurrence)}',
                  ),
                  Text('提前提醒：${version.reminderOffsets.join('、')} 分钟'),
                  if (version.snoozedUntil != null)
                    Text(
                      '稍后提醒：${dateLabel(version.snoozedUntil!, full: true)}',
                    ),
                  const SizedBox(height: 12),
                  const Text(
                    '恢复标题、正文、清单、标签和提醒等编辑内容；保留当前完成及回收站状态。恢复前的内容会保留在历史中，可再次预览并恢复回去。',
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await app.restoreVersion(
                            id,
                            packet,
                            expectedOperationId: expected,
                          );
                          if (context.mounted) Navigator.pop(context, true);
                        } catch (e) {
                          if (context.mounted) {
                            setState(() {
                              busy = false;
                              error = safeError(e);
                            });
                          }
                        }
                      },
                child: const Text('恢复此版本'),
              ),
            ],
          ),
        ),
      ) ??
      false;
}

Future<void> settingsDialog(BuildContext context, AppController app) =>
    showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(app: app),
    );

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.app});
  final AppController app;
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  String? result;
  bool busy = false;
  AppController get app => widget.app;
  Future<void> action(Future<void> Function() work) async {
    setState(() {
      busy = true;
      result = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => result = safeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget title(String text) => Padding(
    padding: EdgeInsets.only(top: 20, bottom: 12),
    child: Text(
      text,
      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
    ),
  );
  Widget info(String label, String value, {bool copy = false}) => Padding(
    padding: EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 115,
          child: Text(
            label,
            style: TextStyle(color: colorsOf(context).muted, fontSize: 12),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(fontSize: 12, height: 1.6),
          ),
        ),
        if (copy)
          IconButton(
            tooltip: '复制',
            visualDensity: VisualDensity.compact,
            onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            icon: Icon(Icons.copy_outlined, size: 15),
          ),
      ],
    ),
  );
  Widget tab(List<Widget> children) => SingleChildScrollView(
    padding: EdgeInsets.symmetric(horizontal: 26, vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: app,
    builder: (context, _) => Dialog(
      child: SizedBox(
        width: 780,
        height: 650,
        child: DefaultTabController(
          length: 4,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(26, 20, 14, 12),
                child: Row(
                  children: [
                    Icon(Icons.tune_rounded, color: colorsOf(context).cyan),
                    SizedBox(width: 12),
                    Text(
                      '设置',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              TabBar(
                tabs: [
                  Tab(text: '数据库连接'),
                  Tab(text: '安全与备份'),
                  Tab(text: '通知与启动'),
                  Tab(text: '诊断'),
                ],
              ),
              if (busy) LinearProgressIndicator(minHeight: 2),
              if (result != null)
                Padding(
                  padding: EdgeInsets.fromLTRB(26, 10, 26, 0),
                  child: Text(
                    result!,
                    style: TextStyle(
                      color: colorsOf(context).danger,
                      fontSize: 12,
                    ),
                  ),
                ),
              Expanded(
                child: TabBarView(
                  children: [
                    tab([
                      title('同步状态'),
                      StatusDot(
                        app.sync.status,
                        color: app.sync.hasError
                            ? colorsOf(context).danger
                            : colorsOf(context).cyan,
                      ),
                      SizedBox(height: 12),
                      info('待同步操作', '${app.store.pendingCount}'),
                      info(
                        '本机最后同步',
                        app.sync.lastSuccess == null
                            ? '尚未同步'
                            : dateLabel(app.sync.lastSuccess, full: true),
                      ),
                      if (app.sync.config != null) ...[
                        info('连接名称', app.sync.config!.name),
                        info(
                          '主机',
                          '${app.sync.config!.host}:${app.sync.config!.port}',
                        ),
                        info('数据库', app.sync.config!.database),
                        info(
                          '传输保护',
                          app.sync.config!.tls
                              ? 'TLS · 校验证书与主机名'
                              : '无 TLS（显式选择）',
                        ),
                      ],
                      SizedBox(height: 16),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          FilledButton.icon(
                            onPressed: busy
                                ? null
                                : () => action(() async {
                                    final config = await connectionDialog(
                                      context,
                                      app.sync.config,
                                    );
                                    if (config != null) {
                                      await app.configure(config);
                                    }
                                  }),
                            icon: Icon(Icons.storage_rounded, size: 18),
                            label: Text(
                              app.sync.config == null ? '配置数据库' : '修改连接',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: app.sync.config == null || busy
                                ? null
                                : () => action(app.sync.sync),
                            icon: Icon(Icons.sync, size: 18),
                            label: Text('立即同步'),
                          ),
                          TextButton(
                            onPressed: app.sync.config == null || busy
                                ? null
                                : () => action(() => app.configure(null)),
                            child: Text('切换离线模式'),
                          ),
                        ],
                      ),
                      title('设备'),
                      Text(
                        '“本机已同步”表示已上传和拉取，不表示另一设备已经收到。',
                        style: TextStyle(
                          color: colorsOf(context).muted,
                          fontSize: 12,
                        ),
                      ),
                      ...app.sync.devices.map(
                        (device) => ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            device['device_id'] == app.store.deviceId
                                ? Icons.computer_rounded
                                : Icons.devices_other_rounded,
                            color: colorsOf(context).muted,
                          ),
                          title: Text(
                            device['device_id'] == app.store.deviceId
                                ? '这台电脑'
                                : '设备 ${device['device_id'].toString().substring(0, 8)}',
                            style: TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            '已确认游标 ${device['cursor']} · ${device['last_seen']}',
                            style: TextStyle(
                              color: colorsOf(context).muted,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ]),
                    tab([
                      title('资料库保护'),
                      if (app.sync.envelopeConflict) ...[
                        Text(
                          '两台设备都更改了主密码。任务已保留，请选择接下来统一使用哪台设备的密码。',
                          style: TextStyle(
                            color: colorsOf(context).violet,
                            fontSize: 12,
                          ),
                        ),
                        SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            OutlinedButton(
                              onPressed: busy
                                  ? null
                                  : () => action(
                                      () => app.sync.resolveEnvelopeConflict(
                                        keepLocal: true,
                                      ),
                                    ),
                              child: Text('使用本机主密码'),
                            ),
                            OutlinedButton(
                              onPressed: busy
                                  ? null
                                  : () => action(
                                      () => app.sync.resolveEnvelopeConflict(
                                        keepLocal: false,
                                      ),
                                    ),
                              child: Text('使用另一设备的主密码'),
                            ),
                          ],
                        ),
                      ],
                      info('资料库 ID', app.crypto.vaultId ?? '', copy: true),
                      info(
                        '业务加密',
                        'XChaCha20-Poly1305 · Argon2id · 64 MiB / 3 次',
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: app.remember,
                        onChanged: busy
                            ? null
                            : (v) => action(() => app.setTrust(v)),
                        title: Text('记住此设备'),
                        subtitle: Text(
                          '下次启动自动解锁；密钥由当前 Windows 用户的 DPAPI 保护。',
                          style: TextStyle(
                            color: colorsOf(context).muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Text(
                        '手动锁定和 Windows 锁屏会清除应用内的解密密钥。主密码不会保存或传给数据库。',
                        style: TextStyle(
                          color: colorsOf(context).muted,
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => action(() async {
                                final value = await secretDialog(
                                  context,
                                  title: '更改主密码',
                                  allowRecovery: false,
                                  newPassword: true,
                                );
                                if (value != null) {
                                  await app.changePassword(value.secret);
                                  if (mounted) {
                                    setState(
                                      () =>
                                          result = '主密码已在本机更新，请重新导出备份，并等待同步完成。',
                                    );
                                  }
                                }
                              }),
                        icon: Icon(Icons.password_rounded, size: 18),
                        label: Text('更改主密码'),
                      ),
                      title('加密备份'),
                      Text(
                        '备份含任务、回收站和本机修改历史。本机图片未纳入备份。请同时离线保存主密码或恢复码。',
                        style: TextStyle(
                          color: colorsOf(context).muted,
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () => action(() => exportBackup(context, app)),
                        icon: Icon(Icons.save_alt_rounded, size: 18),
                        label: Text('导出加密备份'),
                      ),
                      SizedBox(height: 14),
                      Text(
                        '在新设备的欢迎页选择“恢复加密备份”。旧备份使用备份时的密码；更改主密码不会让已导出的旧备份失效。',
                        style: TextStyle(
                          color: colorsOf(context).muted,
                          fontSize: 12,
                        ),
                      ),
                    ]),
                    tab([
                      title('Windows 提醒'),
                      StatusDot(
                        app.desktop.status,
                        color: app.desktop.allowed
                            ? colorsOf(context).cyan
                            : colorsOf(context).danger,
                      ),
                      SizedBox(height: 12),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: app.notificationsEnabled,
                        onChanged: busy
                            ? null
                            : (v) =>
                                  action(() => app.setting('notifications', v)),
                        title: Text('在这台电脑提醒'),
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: app.showTitles,
                        onChanged: busy
                            ? null
                            : (v) =>
                                  action(() => app.setting('show_titles', v)),
                        title: Text('通知显示任务标题'),
                        subtitle: Text(
                          '开启后，标题会出现在 Windows 通知中心和历史记录中。',
                          style: TextStyle(
                            color: colorsOf(context).muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: app.quiet,
                        onChanged: busy
                            ? null
                            : (v) => action(() => app.setting('quiet', v)),
                        title: Text('夜间静默 22:00—08:00'),
                        subtitle: Text(
                          '按电脑本地时间，静默期间的提醒顺延到早上 08:00。',
                          style: TextStyle(
                            color: colorsOf(context).muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => action(app.desktop.test),
                            child: Text('发送测试通知'),
                          ),
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () => action(() => app.schedule(force: true)),
                            child: Text('重新安排提醒'),
                          ),
                          TextButton(
                            onPressed: () =>
                                app.desktop.openNotificationSettings(),
                            child: Text('Windows 通知设置'),
                          ),
                        ],
                      ),
                      title('运行方式'),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: app.startup,
                        onChanged: busy
                            ? null
                            : (v) => action(() => app.setting('startup', v)),
                        title: Text('随 Windows 登录启动'),
                      ),
                      Text(
                        '关闭窗口会保存并退出，释放内存。Ctrl+Shift+N 快速添加；Ctrl+S 保存；Ctrl+L 锁定。退出后已登记的计划通知仍由 Windows 管理。系统关机、免打扰或通知被禁用时可能延迟；重新运行后会补查逾期事项。',
                        style: TextStyle(
                          color: colorsOf(context).muted,
                          fontSize: 12,
                        ),
                      ),
                    ]),
                    tab([
                      title('星记 ${appBuildName ?? '0.5.1'} · Windows'),
                      info('本地资料目录', app.dataDirectory, copy: true),
                      info('设备 ID', app.store.deviceId, copy: true),
                      info('同步游标', '${app.store.cursor}'),
                      info(
                        '系统快捷键',
                        app.desktop.hotkey
                            ? '已注册 Ctrl+Shift+N'
                            : '快捷键被占用，可使用托盘新建',
                      ),
                      info('业务存储', 'SQLite 密文缓存；解锁后在内存中搜索'),
                      info('通知内容', app.showTitles ? '显示标题（已开启）' : '仅显示通用提醒'),
                      SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: () =>
                            Process.start('explorer.exe', [app.dataDirectory]),
                        icon: Icon(Icons.folder_open_rounded, size: 18),
                        label: Text('打开资料目录'),
                      ),
                      title('版本范围'),
                      TextButton.icon(
                        onPressed: () => showLicensePage(
                          context: context,
                          applicationName: '星记',
                          applicationVersion: appBuildName,
                        ),
                        icon: Icon(Icons.description_outlined, size: 18),
                        label: Text('开源组件许可证'),
                      ),
                      Text(
                        'Windows 和 Android 均支持本机图片。跨端同步、加密备份和修改历史仅保存事项内容。每条事项最多保留 30 个本机历史版本。',
                        style: TextStyle(
                          color: colorsOf(context).muted,
                          fontSize: 12,
                        ),
                      ),
                      title('提醒验证'),
                      Text(
                        '请使用测试通知确认你的 Windows 通知设置。系统设置报告允许发送，并不保证免打扰期间横幅一定出现。',
                        style: TextStyle(
                          color: colorsOf(context).muted,
                          fontSize: 12,
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
