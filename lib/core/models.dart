import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

const uuid = Uuid();
typedef Json = Map<String, dynamic>;

class CheckItem {
  CheckItem({required this.text, this.done = false, String? id})
    : id = id ?? uuid.v4();
  final String id;
  final String text;
  final bool done;
  Json toJson() => {'id': id, 'text': text, 'done': done};
  factory CheckItem.fromJson(Json j) => CheckItem(
    id: j['id'] as String,
    text: j['text'] as String,
    done: j['done'] == true,
  );
  CheckItem copyWith({String? text, bool? done}) =>
      CheckItem(id: id, text: text ?? this.text, done: done ?? this.done);
}

class Memo {
  Memo({
    String? id,
    this.title = '',
    this.body = '',
    this.tags = const [],
    this.checklist = const [],
    this.priority = 1,
    this.pinned = false,
    this.status = 'open',
    this.dueAt,
    this.timezone = 'Asia/Shanghai',
    this.reminderOffsets = const [0],
    this.forceAlarm = false,
    this.recurrence = 'none',
    this.completedAt,
    this.deletedAt,
    this.snoozedUntil,
    this.conflictOf,
    this.completions = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : id = id ?? uuid.v4(),
       createdAt = createdAt ?? DateTime.now().toUtc(),
       updatedAt = updatedAt ?? DateTime.now().toUtc();

  final String id, title, body, status, timezone, recurrence;
  final List<String> tags;
  final List<CheckItem> checklist;
  final int priority, completions;
  final bool pinned, forceAlarm;
  final DateTime? dueAt, completedAt, deletedAt, snoozedUntil;
  final DateTime createdAt, updatedAt;
  final List<int> reminderOffsets;
  final String? conflictOf;

  bool get deleted => deletedAt != null;
  bool get done => status == 'done';
  bool get purged => status == 'purged';

  factory Memo.purgeMarker(String id, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    return Memo(
      id: id,
      status: 'purged',
      deletedAt: at,
      createdAt: at,
      updatedAt: at,
      reminderOffsets: const [],
    );
  }
  DateTime? get reminderAt => snoozedUntil ?? dueAt;
  bool get overdue =>
      !done && !deleted && dueAt != null && dueAt!.isBefore(DateTime.now());
  String get occurrence => '$id:${dueAt?.toUtc().toIso8601String() ?? "none"}';

  Json toJson() => {
    'schema_version': 1,
    'id': id,
    'title': title,
    'body': body,
    'tags': tags,
    'checklist': checklist.map((e) => e.toJson()).toList(),
    'priority': priority,
    'pinned': pinned,
    'status': status,
    'due_at_utc': dueAt?.toUtc().toIso8601String(),
    'timezone': timezone,
    'reminder_offsets': reminderOffsets,
    'force_alarm': forceAlarm,
    'recurrence': recurrence,
    'completed_at': completedAt?.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'snoozed_until': snoozedUntil?.toUtc().toIso8601String(),
    'conflict_of': conflictOf,
    'completions': completions,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory Memo.fromJson(Json j) {
    if (j['schema_version'] != 1) throw const FormatException('不支持的任务格式');
    DateTime? date(String field) =>
        j[field] == null ? null : DateTime.parse(j[field] as String).toUtc();
    return Memo(
      id: j['id'] as String,
      title: j['title'] as String,
      body: j['body'] as String,
      tags: (j['tags'] as List).cast<String>(),
      checklist: (j['checklist'] as List)
          .map((e) => CheckItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      priority: j['priority'] as int,
      pinned: j['pinned'] == true,
      status: j['status'] as String,
      dueAt: date('due_at_utc'),
      timezone: j['timezone'] as String,
      reminderOffsets: (j['reminder_offsets'] as List).cast<int>(),
      forceAlarm: j['force_alarm'] == true,
      recurrence: j['recurrence'] as String,
      completedAt: date('completed_at'),
      deletedAt: date('deleted_at'),
      snoozedUntil: date('snoozed_until'),
      conflictOf: j['conflict_of'] as String?,
      completions: j['completions'] as int? ?? 0,
      createdAt: date('created_at'),
      updatedAt: date('updated_at'),
    );
  }

  Memo edit(Json fields) => Memo.fromJson({
    ...toJson(),
    ...fields,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  });

  Memo complete({DateTime? now, bool stopSeries = false}) {
    final at = (now ?? DateTime.now()).toUtc();
    if (recurrence != 'none' && dueAt != null && !stopSeries) {
      final location = tz.getLocation(timezone);
      var next = tz.TZDateTime.from(dueAt!, location);
      // Missed occurrences are skipped; the next occurrence keeps local wall-clock time.
      do {
        next = tz.TZDateTime(
          location,
          next.year,
          next.month,
          next.day + (recurrence == 'weekly' ? 7 : 1),
          next.hour,
          next.minute,
        );
      } while (next.toUtc().isBefore(at) ||
          (recurrence == 'weekdays' && next.weekday > 5));
      return edit({
        'due_at_utc': next.toUtc().toIso8601String(),
        'status': 'open',
        'completed_at': at.toIso8601String(),
        'snoozed_until': null,
        'completions': completions + 1,
        'checklist': checklist
            .map((c) => c.copyWith(done: false).toJson())
            .toList(),
      });
    }
    return edit({
      'status': 'done',
      'completed_at': at.toIso8601String(),
      'snoozed_until': null,
      if (stopSeries) 'recurrence': 'none',
    });
  }
}

class CipherRecord {
  const CipherRecord({
    required this.vaultId,
    required this.recordId,
    required this.operationId,
    required this.nonce,
    required this.payload,
    this.deleted = false,
    this.format = 1,
    this.keyVersion = 1,
  });
  final String vaultId, recordId, operationId, nonce, payload;
  final bool deleted;
  final int format, keyVersion;
  String get aad => jsonEncode([
    'xingji-record',
    format,
    vaultId,
    recordId,
    operationId,
    keyVersion,
    deleted,
  ]);
  Json toJson() => {
    'vault_id': vaultId,
    'record_id': recordId,
    'operation_id': operationId,
    'nonce': nonce,
    'payload': payload,
    'deleted': deleted,
    'format': format,
    'key_version': keyVersion,
  };
  factory CipherRecord.fromJson(Json j) {
    if (j['format'] != 1 || j['key_version'] != 1) {
      throw const FormatException('不支持的密文版本，请升级星记');
    }
    return CipherRecord(
      vaultId: j['vault_id'] as String,
      recordId: j['record_id'] as String,
      operationId: j['operation_id'] as String,
      nonce: j['nonce'] as String,
      payload: j['payload'] as String,
      deleted: j['deleted'] as bool,
      format: j['format'] as int,
      keyVersion: j['key_version'] as int,
    );
  }
}

class ConnectionConfig {
  const ConnectionConfig({
    this.name = '我的备忘录',
    this.host = '',
    this.port = 5432,
    this.database = 'xingji',
    this.username = '',
    this.password = '',
    this.caPath = '',
    this.tls = true,
    this.remember = true,
  });
  final String name, host, database, username, password, caPath;
  final int port;
  final bool tls, remember;
  Json toJson() => {
    'name': name,
    'host': host,
    'port': port,
    'database': database,
    'username': username,
    'password': password,
    'ca_path': caPath,
    'tls': tls,
    'remember': remember,
  };
  factory ConnectionConfig.fromJson(Json j) => ConnectionConfig(
    name: j['name'] as String,
    host: j['host'] as String,
    port: j['port'] as int,
    database: j['database'] as String,
    username: j['username'] as String,
    password: j['password'] as String,
    caPath: j['ca_path'] as String,
    tls: j['tls'] == true,
    remember: j['remember'] == true,
  );
}
