import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/desktop_service.dart';
import '../platform/device_services.dart';
import 'image_attachment.dart';
import 'local_store.dart';
import 'dated_memos.dart';
import 'device_trust_policy.dart';
import 'models.dart';
import 'sync_engine.dart';
import 'vault_crypto.dart';

class AppController extends ChangeNotifier {
  AppController(this.store, this.crypto, this.dataDirectory) {
    desktop = DesktopService(store, notifyListeners);
    sync = SyncEngine(
      store,
      crypto,
      onChanged: _dataChanged,
      onState: notifyListeners,
    );
  }
  final LocalStore store;
  final VaultCrypto crypto;
  final String dataDirectory;
  late final DesktopService desktop;
  late final SyncEngine sync;
  List<Memo> memos = [];
  String? selectedId;
  String filter = 'all', search = '';
  DateTime browseDate = DateTime.now();
  String dateStatus = 'all', dateBasis = 'activity';
  String? activeTag;
  String? message, pendingActivation;
  String? recoveryCode;
  bool busy = false;
  Future<void> Function()? flushEditor;
  Future<void> Function()? submitEditor;
  Timer? _reminderTimer;
  final Map<String, ({CipherRecord packet, Memo memo})> _decoded = {};
  bool _matches(CipherRecord a, CipherRecord b) =>
      a.aad == b.aad && a.nonce == b.nonce && a.payload == b.payload;
  bool get darkMode => store.getMeta('appearance') == 'dark';
  Future<void> toggleTheme() async {
    store.setMeta('appearance', darkMode ? 'light' : 'dark');
    notifyListeners();
    await desktop.setTheme(darkMode);
  }

  bool get unlocked => crypto.unlocked;
  bool get exists => store.envelope != null;
  bool get remember => store.getMeta('trusted_key') != null;
  bool get notificationsEnabled => store.getMeta('notifications') != 'false';
  bool get showTitles => store.getMeta('show_titles') == 'true';
  bool get quiet => store.getMeta('quiet') == 'true';
  bool get startup => store.getMeta('startup') == 'true';
  bool get backgroundSync => store.getMeta('background_sync') != 'false';
  bool get alarmReminders => store.getMeta('alarm_reminders') == 'true';
  bool get hasForceAlarmMemos => memos.any(
    (m) => m.forceAlarm && !m.done && !m.deleted && m.dueAt != null,
  );
  bool get trustPeriodValid => DeviceTrustPolicy.valid(
    store.getMeta('password_verified_at'),
    DateTime.now(),
  );
  void _verifiedSecret() => store.setMeta(
    'password_verified_at',
    DateTime.now().toUtc().toIso8601String(),
  );
  Memo? get selected => memos.where((m) => m.id == selectedId).firstOrNull;
  List<String> get tags =>
      memos.where((m) => !m.deleted).expand((m) => m.tags).toSet().toList()
        ..sort();

  Future<void> initialize() async {
    desktop.onEvent = (event) => unawaited(handleEvent(event));
    await desktop.initialize();
    await desktop.setTheme(darkMode);
    pendingActivation = desktop.initialActivation.isEmpty
        ? null
        : desktop.initialActivation;
    final protected = store.getMeta('trusted_key');
    if (exists &&
        protected != null &&
        (!DeviceServices.mobile ||
            (store.getMeta('background_locked') != 'true' &&
                trustPeriodValid))) {
      try {
        final raw = await DeviceServices.unprotect(base64Decode(protected));
        try {
          crypto.unlockTrusted(store.envelope!['vault_id'] as String, raw);
        } finally {
          raw.fillRange(0, raw.length, 0);
        }
        await _afterUnlock();
      } catch (_) {
        crypto.lock();
        message = '此设备需要重新输入主密码解锁';
      }
    }
    if (DeviceServices.mobile && exists && remember && !trustPeriodValid) {
      message = '请验证一次主密码，之后三天内可直接打开。';
    }
    _reminderTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (unlocked) {
        notifyListeners();
        unawaited(schedule(force: true));
      }
    });
    notifyListeners();
  }

  Future<void> create(String password, {required bool trust}) async {
    if (exists) throw StateError('资料库已存在');
    final created = await crypto.create(password);
    store.setMeta('envelope', jsonEncode(created.envelope));
    recoveryCode = created.recoveryCode;
    _verifiedSecret();
    await setTrust(trust);
    await _afterUnlock();
  }

  Future<void> unlock(
    String secret, {
    required bool trust,
    bool recovery = false,
  }) async {
    try {
      await crypto.unlock(store.envelope!, secret, recovery: recovery);
    } catch (_) {
      throw const FormatException('主密码或恢复码不正确，或密钥包已损坏');
    }
    _verifiedSecret();
    await setTrust(trust);
    await _afterUnlock();
  }

  Future<void> _afterUnlock() async {
    crypto.verifyEnvelope(store.envelope!);
    store.removeMeta('background_locked');
    _dataChanged();
    final connection = store.getMeta('connection');
    if (sync.config == null && connection != null) {
      try {
        final raw = await DeviceServices.unprotect(base64Decode(connection));
        try {
          sync.config = ConnectionConfig.fromJson(
            jsonDecode(utf8.decode(raw)) as Json,
          );
        } finally {
          raw.fillRange(0, raw.length, 0);
        }
      } catch (_) {
        message = '已解锁资料库，请重新填写数据库连接密码';
      }
    }
    sync.start();
    await updateBackground();
    if (pendingActivation != null) {
      final event = pendingActivation!;
      pendingActivation = null;
      await handleEvent(event);
    }
    notifyListeners();
  }

  Future<void> setTrust(bool enabled) async {
    if (enabled) {
      final raw = crypto.withKey(Uint8List.fromList);
      try {
        store.setMeta(
          'trusted_key',
          base64Encode(await DeviceServices.protect(raw)),
        );
      } finally {
        raw.fillRange(0, raw.length, 0);
      }
    } else {
      store.removeMeta('trusted_key');
    }
    notifyListeners();
    await updateBackground();
  }

  Future<void> updateBackground() => DeviceServices.background(
    unlocked &&
        remember &&
        backgroundSync &&
        store.getMeta('connection') != null &&
        store.getMeta('background_locked') != 'true',
  );

  Future<void> suspendMobile() async {
    if (!DeviceServices.mobile) return;
    await flushEditor?.call();
    _reminderTimer?.cancel();
    await sync.disconnect();
    await desktop.waitForPending();
  }

  Future<void> resumeMobile() async {
    if (!DeviceServices.mobile || !unlocked) return;
    if (remember && !trustPeriodValid) {
      await lock(manual: false);
      message = '已满三天，请验证主密码后继续。';
      notifyListeners();
      return;
    }
    _dataChanged();
    sync.start();
    _reminderTimer?.cancel();
    _reminderTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (unlocked) unawaited(schedule(force: true));
    });
    await desktop.refreshState();
    await schedule(force: true);
  }

  @override
  void dispose() {
    _reminderTimer?.cancel();
    desktop.onEvent = null;
    unawaited(sync.disconnect());
    crypto.lock();
    super.dispose();
  }

  Future<void> lock({bool manual = true}) async {
    await flushEditor?.call();
    if (DeviceServices.mobile && manual) {
      store.setMeta('background_locked', 'true');
      await DeviceServices.background(false);
    }
    await sync.disconnect();
    await desktop.waitForPending();
    memos = [];
    _decoded.clear();
    selectedId = null;
    search = '';
    recoveryCode = null;
    crypto.lock();
    notifyListeners();
  }

  void _dataChanged() {
    if (!unlocked) return;
    try {
      // Decode the entire set before replacing the current view.
      final rows = store.all();
      final next = <String, ({CipherRecord packet, Memo memo})>{};
      for (final row in rows) {
        final cached = _decoded[row.packet.recordId];
        next[row.packet.recordId] =
            cached != null && _matches(cached.packet, row.packet)
            ? cached
            : (packet: row.packet, memo: crypto.decrypt(row.packet));
      }
      // Older clients may have stored an authenticated purge marker as an
      // ordinary deleted row. Upgrade that row only after every row authenticates.
      for (final row in rows) {
        if (next[row.packet.recordId]!.memo.purged) {
          store.acceptPurge(row.packet, row.serverRevision);
          next.remove(row.packet.recordId);
        }
      }
      final loaded = next.values.map((r) => r.memo).toList();
      _decoded
        ..clear()
        ..addAll(next);
      memos = loaded;
      unawaited(schedule());
    } catch (_) {
      message = '发现无法认证的密文，已保留原数据，停止载入损坏记录';
    }
    notifyListeners();
  }

  Future<void> schedule({bool force = false}) async {
    if (!unlocked) return;
    try {
      final items = store
          .all()
          .map(
            (r) => (
              memo:
                  _decoded[r.packet.recordId] != null &&
                      _matches(_decoded[r.packet.recordId]!.packet, r.packet)
                  ? _decoded[r.packet.recordId]!.memo
                  : crypto.decrypt(r.packet),
              packet: r.packet,
            ),
          )
          .toList();
      await desktop.reconcile(
        items,
        enabled: notificationsEnabled,
        showTitles: showTitles,
        quiet: quiet,
        force: force,
      );
    } catch (_) {
      desktop.status = '密文认证失败，未修改现有提醒排程';
      notifyListeners();
    }
  }

  List<Memo> get visible {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final query = search.trim().toLowerCase();
    final result = memos.where((m) {
      if (m.purged) return false;
      if (filter == 'trash') {
        if (!m.deleted) return false;
      } else if (m.deleted) {
        return false;
      }
      if (activeTag != null && !m.tags.contains(activeTag)) return false;
      switch (filter) {
        case 'date':
          if (!matchesMemoDate(m, browseDate, dateStatus, dateBasis)) {
            return false;
          }
        case 'today':
          if (m.reminderAt == null ||
              m.reminderAt!.isBefore(today) ||
              !m.reminderAt!.isBefore(tomorrow)) {
            return false;
          }
        case 'upcoming':
          if (m.done ||
              m.reminderAt == null ||
              m.reminderAt!.isBefore(tomorrow)) {
            return false;
          }
        case 'overdue':
          if (m.done || m.reminderAt == null || !m.reminderAt!.isBefore(now)) {
            return false;
          }
        case 'unscheduled':
          if (m.done || m.reminderAt != null) return false;
        case 'completed':
          if (!m.done) return false;
        case 'conflicts':
          if (m.conflictOf == null) return false;
      }
      if (query.isNotEmpty &&
          !'${m.title}\n${m.body}\n${m.tags.join(' ')}\n${m.checklist.map((e) => e.text).join(' ')}'
              .toLowerCase()
              .contains(query)) {
        return false;
      }
      return true;
    }).toList();
    result.sort((a, b) {
      if (filter == 'date') return compareDatedMemos(a, b, dateBasis);
      if (a.done != b.done) return a.done ? 1 : -1;
      if (a.done && b.done) {
        return (b.completedAt ?? b.updatedAt).compareTo(
          a.completedAt ?? a.updatedAt,
        );
      }
      final due = (a.reminderAt ?? DateTime(9999)).compareTo(
        b.reminderAt ?? DateTime(9999),
      );
      if (due != 0) return due;
      if (a.priority != b.priority) return b.priority.compareTo(a.priority);
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return result;
  }

  void navigate(String value, {String? tag}) {
    filter = value;
    activeTag = tag;
    selectedId = null;
    notifyListeners();
  }

  void changeDateView({DateTime? day, String? status, String? basis}) {
    if (day != null) browseDate = DateTime(day.year, day.month, day.day);
    if (status != null) dateStatus = status;
    if (basis != null) dateBasis = basis;
    if (dateBasis == 'completed') dateStatus = 'done';
    selectedId = null;
    notifyListeners();
  }

  void select(String? id) {
    selectedId = id;
    notifyListeners();
  }

  void setSearch(String value) {
    search = value;
    notifyListeners();
  }

  void dismissMessage() {
    message = null;
    notifyListeners();
  }

  Future<void> save(Memo memo, {String? copyImagesFrom}) async {
    if (!unlocked) throw const FormatException('请先解锁资料库');
    if (memo.title.trim().isEmpty) throw const FormatException('请填写标题');
    if (memo.title.length > 200 ||
        memo.body.length > 200000 ||
        memo.checklist.length > 100 ||
        memo.tags.length > 20) {
      throw const FormatException('内容过长：标题最多 200 字，正文最多 20 万字，清单最多 100 项');
    }
    store.saveLocalBatch(
      [crypto.encrypt(memo)],
      copyImages: copyImagesFrom == null
          ? null
          : (from: copyImagesFrom, to: memo.id, sign: crypto.relinkImage),
    );
    selectedId = memo.id;
    _dataChanged();
    unawaited(sync.sync());
  }

  bool _sameVersion(Memo a, Memo b) =>
      jsonEncode(a.toJson()..remove('updated_at')) ==
      jsonEncode(b.toJson()..remove('updated_at'));

  String _editableImageMemo(String id) {
    if (!unlocked) throw const FormatException('请先解锁资料库');
    final packet = store.get(id)?.packet;
    if (packet == null || packet.deleted || crypto.decrypt(packet).done) {
      throw const FormatException('只能修改进行中备忘录的图片');
    }
    return packet.operationId;
  }

  void addImage(String memoId, ProcessedImage processed) {
    final operation = _editableImageMemo(memoId);
    final image = ImageAttachment(
      uuid.v4(),
      memoId,
      processed.width,
      processed.height,
      processed.jpeg.length,
    );
    final link = crypto.linkImage(memoId, image);
    store.addImage(link, crypto.encryptImage(image, processed.jpeg), operation);
    notifyListeners();
  }

  Uint8List readImage(String memoId, String imageId) {
    if (!unlocked) throw const FormatException('请先解锁资料库');
    final link = store
        .imageLinks(memoId)
        .where((l) => l.image.id == imageId)
        .firstOrNull;
    if (link == null) throw const FormatException('图片已移除');
    return crypto.decryptImage(link, store.imageChunks(link.image));
  }

  void removeImage(String memoId, String imageId) {
    store.removeImage(memoId, imageId, _editableImageMemo(memoId));
    notifyListeners();
  }

  /// Autosaves remain durable; only explicit Save creates an editing checkpoint.
  void saveVersion(String id) {
    if (!unlocked) throw const FormatException('请先解锁资料库');
    final current = store.get(id);
    if (current == null || store.isPurged(id)) {
      throw const FormatException('这条备忘录已不存在');
    }
    final memo = crypto.decrypt(current.packet);
    final latest = store.history(id).firstOrNull;
    if (latest != null && _sameVersion(crypto.decrypt(latest), memo)) return;
    store.checkpoint(crypto.encrypt(memo.edit({})));
  }

  Future<void> restoreVersion(
    String id,
    CipherRecord version, {
    required String expectedOperationId,
  }) async {
    if (!unlocked) throw const FormatException('请先解锁资料库');
    final current = store.get(id);
    if (current == null || store.isPurged(id)) {
      throw const FormatException('这条备忘录已不存在');
    }
    if (current.packet.operationId != expectedOperationId) {
      throw const FormatException('备忘录已变化，请重新打开修改历史后再恢复');
    }
    if (version.recordId != id ||
        !store
            .history(id)
            .any(
              (p) => jsonEncode(p.toJson()) == jsonEncode(version.toJson()),
            )) {
      throw const FormatException('此历史版本已不存在');
    }
    final before = crypto.decrypt(current.packet);
    final old = crypto.decrypt(version);
    // Restore editable content without reopening an archive, undeleting a memo,
    // changing its identity, or rewinding recurrence completion bookkeeping.
    final restored = before.edit({
      ...old.toJson(),
      'id': before.id,
      'created_at': before.createdAt.toIso8601String(),
      'status': before.status,
      'completed_at': before.completedAt?.toIso8601String(),
      'deleted_at': before.deletedAt?.toIso8601String(),
      'completions': before.completions,
      'conflict_of': before.conflictOf,
    });
    if (_sameVersion(before, restored)) return;
    final latest = store.history(id).firstOrNull;
    store.saveLocal(
      crypto.encrypt(restored),
      recordHistory:
          latest == null || !_sameVersion(crypto.decrypt(latest), before),
      checkpoint: true,
    );
    selectedId = id;
    _dataChanged();
    unawaited(sync.sync());
  }

  Future<void> toggleDone(Memo memo) async {
    if (!unlocked) throw const FormatException('请先解锁资料库');
    if (!memo.done && memo.recurrence != 'none' && memo.dueAt != null) {
      final current = memos.where((m) => m.id == memo.id).firstOrNull;
      if (current == null ||
          current.occurrence != memo.occurrence ||
          current.done) {
        return;
      }
      final now = DateTime.now().toUtc();
      final archive = memo.complete(now: now, stopSeries: true).edit({
        'id': uuid.v5(memo.id, 'completed:${memo.occurrence}'),
        'pinned': false,
      });
      final next = memo.complete(now: now);
      store.saveLocalBatch(
        [crypto.encrypt(archive), crypto.encrypt(next)],
        copyImages: (from: memo.id, to: archive.id, sign: crypto.relinkImage),
      );
      selectedId = archive.id;
      _dataChanged();
      unawaited(sync.sync());
      return;
    }
    await save(
      memo.done
          ? memo.edit({'status': 'open', 'completed_at': null})
          : memo.complete(),
    );
  }

  Future<void> delete(Memo memo) =>
      save(memo.edit({'deleted_at': DateTime.now().toUtc().toIso8601String()}));
  Future<void> restore(Memo memo) => save(memo.edit({'deleted_at': null}));
  Future<void> purge(Memo memo) async {
    if (!unlocked) throw const FormatException('请先解锁资料库');
    final current = memos.where((m) => m.id == memo.id).firstOrNull;
    if (current == null || !current.deleted) {
      throw const FormatException('只能永久删除回收站中的备忘录');
    }
    final marker = crypto.encrypt(Memo.purgeMarker(current.id));
    crypto.decrypt(marker);
    store.purgeLocal(marker);
    selectedId = null;
    _dataChanged();
    unawaited(sync.sync());
  }

  Future<void> snooze(Memo memo, int minutes) => save(
    memo.edit({
      'snoozed_until': DateTime.now()
          .toUtc()
          .add(Duration(minutes: minutes))
          .toIso8601String(),
    }),
  );

  Future<void> handleEvent(String event) async {
    if (event == 'exit') {
      await flushEditor?.call();
      await sync.disconnect();
      await desktop.waitForPending();
      crypto.lock();
      _reminderTimer?.cancel();
      await desktop.exit();
      return;
    }
    if (event == 'lock') {
      await lock();
      return;
    }
    if (event == 'resume') {
      await schedule(force: true);
      unawaited(sync.sync());
      return;
    }
    if (event == 'new') {
      if (unlocked) {
        await flushEditor?.call();
        selectedId = null;
        filter = 'all';
        message = 'new';
        notifyListeners();
      } else {
        pendingActivation = event;
      }
      return;
    }
    if (!event.startsWith('xingji://')) return;
    await desktop.show();
    if (!unlocked) {
      pendingActivation = event;
      notifyListeners();
      return;
    }
    final uri = Uri.tryParse(event);
    if (uri == null) return;
    final id = uri.queryParameters['id'];
    if (id == null) {
      navigate('today');
      return;
    }
    final memo = memos.where((m) => m.id == id).firstOrNull;
    if (memo == null || memo.deleted) {
      message = '这项备忘录已删除或尚未同步';
      notifyListeners();
      return;
    }
    await flushEditor?.call();
    selectedId = id;
    filter = memo.done ? 'completed' : 'all';
    activeTag = null;
    search = '';
    final stored = store.get(id)!;
    if (uri.host != 'open') {
      if (memo.occurrence != uri.queryParameters['occurrence'] ||
          stored.packet.operationId != uri.queryParameters['generation'] ||
          memo.done) {
        message = '这条提醒已经过期，请查看当前任务';
      } else if (uri.host == 'complete') {
        await toggleDone(memo);
      } else if (uri.host == 'snooze') {
        final minutes =
            int.tryParse(uri.queryParameters['minutes'] ?? '') ?? 10;
        if ([5, 10, 30].contains(minutes)) await snooze(memo, minutes);
      }
    }
    notifyListeners();
  }

  Future<void> configure(ConnectionConfig? config) async {
    if (config != null && config.remember) {
      final raw = Uint8List.fromList(utf8.encode(jsonEncode(config.toJson())));
      try {
        store.setMeta(
          'connection',
          base64Encode(await DeviceServices.protect(raw)),
        );
      } finally {
        raw.fillRange(0, raw.length, 0);
      }
    } else {
      store.removeMeta('connection');
    }
    await sync.configure(config);
    await updateBackground();
  }

  Future<void> join(
    ConnectionConfig config,
    Json remote,
    String secret,
    bool trust,
  ) async {
    if (exists) throw const FormatException('当前设备已有资料库');
    final envelope = Map<String, dynamic>.from(remote['envelope'] as Map);
    try {
      await crypto.unlock(envelope, secret);
    } catch (_) {
      throw const FormatException('主密码不正确，无法解锁服务器上的资料库');
    }
    store.transaction(() {
      store.setMeta('envelope', jsonEncode(envelope));
      store.setMeta(
        'envelope_revision',
        remote['envelope_revision'].toString(),
      );
    });
    _verifiedSecret();
    await setTrust(trust);
    await configure(config);
    await _afterUnlock();
  }

  Future<void> changePassword(String password) async {
    if (sync.running) throw const FormatException('正在同步，请稍后更改主密码');
    final envelope = await crypto.changePassword(store.envelope!, password);
    _verifiedSecret();
    store.transaction(() {
      store.setMeta('envelope', jsonEncode(envelope));
      store.setMeta('envelope_dirty', 'true');
    });
    notifyListeners();
    unawaited(sync.sync());
  }

  Future<void> setting(String key, bool value) async {
    if (key == 'startup') await desktop.setStartup(value);
    store.setMeta(key, value.toString());
    if (key == 'background_sync') await updateBackground();
    notifyListeners();
    await schedule(force: true);
  }

  String exportBackup() =>
      jsonEncode(crypto.encryptBackup(store.envelope!, store.snapshot()));

  Future<void> importBackup(
    String path,
    String secret, {
    bool recovery = false,
    required bool trust,
  }) async {
    if (exists) throw const FormatException('请在空的本地资料库中恢复备份');
    final file = File(path);
    if (await file.length() > 80 * 1024 * 1024) {
      throw const FormatException('备份文件超过 80 MB');
    }
    final backup = jsonDecode(await file.readAsString()) as Json;
    final isolated = await VaultCrypto.initialize();
    try {
      final envelope = Map<String, dynamic>.from(backup['envelope'] as Map);
      await isolated.unlock(envelope, secret, recovery: recovery);
      final snapshot = isolated.decryptBackup(backup);
      if (snapshot['format'] != 1) throw const FormatException('备份格式不兼容');
      final records = (snapshot['records'] as List)
          .map(
            (j) => CipherRecord.fromJson(Map<String, dynamic>.from(j as Map)),
          )
          .toList();
      final history = (snapshot['history'] as List)
          .map(
            (j) => CipherRecord.fromJson(Map<String, dynamic>.from(j as Map)),
          )
          .toList();
      final explicitPurges = (snapshot['purges'] as List? ?? [])
          .map(
            (j) => CipherRecord.fromJson(Map<String, dynamic>.from(j as Map)),
          )
          .toList();
      final purges = {
        for (final packet in explicitPurges) packet.recordId: packet,
        for (final packet in records)
          if (isolated.decrypt(packet).purged) packet.recordId: packet,
      }.values.toList();
      for (final marker in purges) {
        if (!isolated.decrypt(marker).purged) {
          throw const FormatException('无效删除标记');
        }
      }
      for (final record in [...records, ...history]) {
        isolated.decrypt(record);
      }
      // A restored snapshot is replayed as new operations. Existing server edits
      // become explicit conflicts; an old backup cannot silently overwrite them.
      final replay = records
          .map((r) => isolated.encrypt(isolated.decrypt(r)))
          .toList();
      store.restore(envelope, replay, history, purges: purges);
      isolated.withKey((raw) => crypto.unlockTrusted(isolated.vaultId!, raw));
      _verifiedSecret();
      await setTrust(trust);
      await _afterUnlock();
    } catch (_) {
      throw const FormatException('备份认证失败、密码不正确或文件损坏，未覆盖原有数据');
    } finally {
      isolated.lock();
    }
  }
}
