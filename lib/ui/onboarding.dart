import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../core/sync_engine.dart';
import '../platform/device_services.dart';
import 'dialogs.dart';
import 'theme.dart';

class VaultGate extends StatefulWidget {
  const VaultGate({super.key, required this.app});
  final AppController app;
  @override
  State<VaultGate> createState() => _VaultGateState();
}

class _VaultGateState extends State<VaultGate> {
  final password = TextEditingController(), confirm = TextEditingController();
  bool trust = true,
      recovery = false,
      busy = false,
      obscure = true,
      savedCode = false;
  String? error;
  AppController get app => widget.app;
  @override
  void dispose() {
    password.clear();
    confirm.clear();
    password.dispose();
    confirm.dispose();
    super.dispose();
  }

  Future<void> action(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
      password.clear();
      confirm.clear();
    } catch (e) {
      if (mounted) setState(() => error = safeError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() => action(() async {
    if (!app.exists) {
      if (password.text.length < 10) {
        throw FormatException('主密码至少需要 10 个字符，推荐使用一句长口令');
      }
      if (password.text != confirm.text) {
        throw FormatException('两次输入的主密码不一致');
      }
      await app.create(password.text, trust: trust);
    } else {
      await app.unlock(password.text, trust: trust, recovery: recovery);
    }
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: colorsOf(context).ink,
    appBar: AppBar(
      title: const Text('星记'),
      backgroundColor: Colors.transparent,
      shape: const Border(),
      actions: [
        TextButton.icon(
          onPressed: app.toggleTheme,
          icon: Icon(
            app.darkMode ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          ),
          label: Text(app.darkMode ? '浅色' : '深色'),
        ),
      ],
    ),
    body: AppAmbient(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 600 ? 12 : 28,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 470),
            child: GlassPanel(
              blur: true,
              radius: 28,
              padding: EdgeInsets.all(
                MediaQuery.sizeOf(context).width < 600 ? 20 : 30,
              ),
              child: app.recoveryCode != null ? recoveryPanel() : loginPanel(),
            ),
          ),
        ),
      ),
    ),
  );

  Widget recoveryPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.key_rounded, size: 36, color: colorsOf(context).cyan),
      SizedBox(height: 20),
      Text(
        '保存你的恢复码',
        style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
      ),
      SizedBox(height: 12),
      Text(
        '忘记主密码时，可以用它重新解锁资料库。请保存到独立、安全的位置。',
        style: TextStyle(color: colorsOf(context).muted, fontSize: 13),
      ),
      SizedBox(height: 24),
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: colorsOf(context).ink,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorsOf(context).line),
        ),
        child: SelectableText(
          app.recoveryCode!,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 14,
            height: 1.9,
            color: colorsOf(context).cyan,
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: () =>
              Clipboard.setData(ClipboardData(text: app.recoveryCode!)),
          icon: Icon(Icons.copy, size: 15),
          label: Text('复制恢复码'),
        ),
      ),
      Text(
        '此恢复码只在创建时显示。主密码、恢复码和可信设备全部丢失后，数据库密码无法帮助解密。',
        style: TextStyle(color: colorsOf(context).muted, fontSize: 12),
      ),
      SizedBox(height: 16),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: savedCode,
        onChanged: (v) => setState(() => savedCode = v!),
        title: Text('我已妥善保存恢复码', style: TextStyle(fontSize: 13)),
      ),
      SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: savedCode
              ? () {
                  app.recoveryCode = null;
                  app.navigate('all');
                }
              : null,
          child: Text('进入我的空间'),
        ),
      ),
    ],
  );

  Widget loginPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          const StarMark(size: 42),
          Spacer(),
          Text(
            'XINGJI / 01',
            style: TextStyle(
              color: colorsOf(context).muted,
              fontSize: 10,
              letterSpacing: 2,
            ),
          ),
        ],
      ),
      SizedBox(height: 22),
      Text(
        app.exists ? '欢迎回来' : '创建你的私人空间',
        style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
      ),
      SizedBox(height: 10),
      Text(
        app.exists ? '解锁后，继续记录今天的想法。' : '设置独立的加密主密码，即可开始离线使用。',
        style: TextStyle(color: colorsOf(context).muted, fontSize: 13),
      ),
      SizedBox(height: 28),
      TextField(
        controller: password,
        obscureText: obscure,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: (_) {
          if (!busy) submit();
        },
        decoration: InputDecoration(
          labelText: recovery
              ? '恢复码 XJ1.…'
              : app.exists
              ? '资料库主密码'
              : '主密码（至少 10 个字符）',
          prefixIcon: Icon(
            recovery ? Icons.key_rounded : Icons.lock_outline_rounded,
            size: 18,
          ),
          suffixIcon: IconButton(
            onPressed: () => setState(() => obscure = !obscure),
            icon: Icon(
              obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 18,
            ),
          ),
        ),
      ),
      if (!app.exists) ...[
        SizedBox(height: 14),
        TextField(
          controller: confirm,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) {
            if (!busy) submit();
          },
          decoration: InputDecoration(
            labelText: '再次输入主密码',
            prefixIcon: Icon(Icons.check_circle_outline, size: 18),
          ),
        ),
      ],
      SizedBox(height: 10),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: trust,
        onChanged: (v) => setState(() => trust = v!),
        title: Text(
          DeviceServices.mobile ? '三天内免输主密码' : '记住此设备',
          style: TextStyle(fontSize: 13),
        ),
        subtitle: Text(
          DeviceServices.mobile
              ? '使用设备密钥保护，每三天验证一次'
              : '使用 ${DeviceServices.protection} 保护，下次自动解锁',
          style: TextStyle(fontSize: 11, color: colorsOf(context).muted),
        ),
      ),
      if (app.exists)
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() => recovery = !recovery),
            child: Text(recovery ? '使用主密码' : '忘记密码？使用恢复码'),
          ),
        ),
      if (error != null)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Text(
            error!,
            style: TextStyle(color: colorsOf(context).danger, fontSize: 12),
          ),
        ),
      if (app.message != null && app.message != 'new')
        Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            app.message!,
            style: TextStyle(color: colorsOf(context).muted, fontSize: 12),
          ),
        ),
      SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: Pressable(
          child: FilledButton(
            onPressed: busy ? null : submit,
            child: busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(app.exists ? '解锁资料库' : '创建加密资料库'),
                      SizedBox(width: 10),
                      Icon(Icons.arrow_forward_rounded, size: 18),
                    ],
                  ),
          ),
        ),
      ),
      if (!app.exists) ...[
        SizedBox(height: 22),
        Divider(),
        SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: busy
                    ? null
                    : () => action(() async {
                        final config = await connectionDialog(context, null);
                        if (config == null) return;
                        final vaults = await SyncEngine.remoteVaults(config);
                        if (vaults.isEmpty) {
                          throw FormatException(
                            '当前账号没有可连接的资料库，请先在本机创建，或让管理员授权',
                          );
                        }
                        if (!mounted) return;
                        Json? remote = vaults.first;
                        if (vaults.length > 1) {
                          remote = await showDialog<Json>(
                            context: context,
                            builder: (c) => SimpleDialog(
                              title: Text('选择资料库'),
                              children: vaults
                                  .map(
                                    (v) => SimpleDialogOption(
                                      onPressed: () => Navigator.pop(c, v),
                                      child: Text(v['vault_id'] as String),
                                    ),
                                  )
                                  .toList(),
                            ),
                          );
                        }
                        if (remote == null || !mounted) return;
                        final value = await secretDialog(
                          context,
                          allowRecovery: false,
                        );
                        if (value == null) return;
                        await app.join(config, remote, value.secret, trust);
                      }),
                icon: Icon(Icons.cloud_outlined, size: 16),
                label: Text('连接已有资料库', style: TextStyle(fontSize: 12)),
              ),
            ),
            Expanded(
              child: TextButton.icon(
                onPressed: busy
                    ? null
                    : () => action(
                        () => DeviceServices.withBackupFile((file) async {
                          if (!mounted) return;
                          final value = await secretDialog(
                            context,
                            title: '恢复加密备份',
                          );
                          if (value == null) return;
                          await app.importBackup(
                            file,
                            value.secret,
                            recovery: value.recovery,
                            trust: trust,
                          );
                        }),
                      ),
                icon: Icon(Icons.restore_rounded, size: 16),
                label: Text('恢复加密备份', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ),
      ],
    ],
  );
}
