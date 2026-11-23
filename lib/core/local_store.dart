import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'image_attachment.dart';
import 'models.dart';

class StoredRecord {
  StoredRecord(this.packet, this.revision, this.serverRevision);
  final CipherRecord packet;
  final int revision, serverRevision;
}

class PendingOperation {
  PendingOperation(this.packet, this.baseRevision);
  final CipherRecord packet;
  final int baseRevision;
}

class LocalStore {
  LocalStore(String path) : db = sqlite3.open(path) {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA busy_timeout=5000');
    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS records (
        id TEXT PRIMARY KEY, packet TEXT NOT NULL, revision INTEGER NOT NULL,
        server_revision INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL,
        record_id TEXT NOT NULL, base_revision INTEGER NOT NULL, packet TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS outbox_record ON outbox(record_id);
      CREATE TABLE IF NOT EXISTS history (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, record_id TEXT NOT NULL,
        operation_id TEXT UNIQUE NOT NULL, packet TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS reminders (
        id TEXT PRIMARY KEY, record_id TEXT NOT NULL, generation TEXT NOT NULL,
        occurrence TEXT NOT NULL, fire_at INTEGER NOT NULL, handled INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS purges (
        id TEXT PRIMARY KEY, packet TEXT NOT NULL,
        revision INTEGER NOT NULL DEFAULT 0, pending INTEGER NOT NULL DEFAULT 1);
      CREATE TABLE IF NOT EXISTS attachments (
        id TEXT PRIMARY KEY, origin_id TEXT NOT NULL,
        width INTEGER NOT NULL, height INTEGER NOT NULL, byte_length INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS attachment_chunks (
        attachment_id TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,
        part INTEGER NOT NULL, nonce BLOB NOT NULL, ciphertext BLOB NOT NULL,
        PRIMARY KEY(attachment_id, part));
      CREATE TABLE IF NOT EXISTS memo_images (
        record_id TEXT NOT NULL REFERENCES records(id) DEFERRABLE INITIALLY DEFERRED,
        attachment_id TEXT NOT NULL REFERENCES attachments(id), tag BLOB NOT NULL,
        PRIMARY KEY(record_id, attachment_id));
      CREATE INDEX IF NOT EXISTS memo_images_attachment ON memo_images(attachment_id);
      CREATE TRIGGER IF NOT EXISTS collect_unlinked_image AFTER DELETE ON memo_images
      BEGIN
        DELETE FROM attachments WHERE id=OLD.attachment_id
          AND NOT EXISTS (SELECT 1 FROM memo_images WHERE attachment_id=OLD.attachment_id);
      END;
      CREATE TRIGGER IF NOT EXISTS purge_memo_images BEFORE INSERT ON purges
      BEGIN
        DELETE FROM memo_images WHERE record_id=NEW.id;
      END;
    ''');
    if ((db.select('PRAGMA user_version').first.values.first as int) < 3) {
      db.execute('PRAGMA user_version=3');
    }
    if (getMeta('device_id') == null) setMeta('device_id', uuid.v4());
  }
  final Database db;
  String get deviceId => getMeta('device_id')!;
  String? getMeta(String key) =>
      db.select('SELECT value FROM meta WHERE key=?', [
            key,
          ]).firstOrNull?['value']
          as String?;
  void setMeta(String key, String value) => db.execute(
    'INSERT INTO meta(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  void removeMeta(String key) =>
      db.execute('DELETE FROM meta WHERE key=?', [key]);
  Json? get envelope => getMeta('envelope') == null
      ? null
      : jsonDecode(getMeta('envelope')!) as Json;
  int get cursor => int.tryParse(getMeta('cursor') ?? '') ?? 0;
  int get envelopeRevision =>
      int.tryParse(getMeta('envelope_revision') ?? '') ?? 1;
  bool get envelopeDirty => getMeta('envelope_dirty') == 'true';
  int get pendingPurgeCount =>
      db.select('SELECT count(*) AS n FROM purges WHERE pending=1').first['n']
          as int;
  int get pendingCount =>
      (db.select('SELECT count(*) AS n FROM outbox').first['n'] as int) +
      pendingPurgeCount;
  bool isPurged(String id) =>
      db.select('SELECT 1 FROM purges WHERE id=?', [id]).isNotEmpty;

  List<CipherRecord> purgeMarkers({bool pendingOnly = false}) => db
      .select(
        'SELECT packet FROM purges${pendingOnly ? ' WHERE pending=1' : ''}',
      )
      .map(
        (r) => CipherRecord.fromJson(jsonDecode(r['packet'] as String) as Json),
      )
      .toList();

  void _eraseContents(String id) {
    db.execute('DELETE FROM records WHERE id=?', [id]);
    db.execute('DELETE FROM history WHERE record_id=?', [id]);
    db.execute('DELETE FROM outbox WHERE record_id=?', [id]);
    db.execute('DELETE FROM reminders WHERE record_id=?', [id]);
  }

  // Callers authenticate and validate the content-free marker before storage.
  void purgeLocal(CipherRecord marker) => transaction(() {
    if (isPurged(marker.recordId)) return;
    if (!marker.deleted) throw const FormatException('删除标记无效');
    _eraseContents(marker.recordId);
    db.execute(
      'INSERT INTO purges(id,packet,revision,pending) VALUES(?,?,0,1)',
      [marker.recordId, jsonEncode(marker.toJson())],
    );
  });

  void _applyPurge(CipherRecord marker, int revision) {
    _eraseContents(marker.recordId);
    db.execute(
      '''INSERT INTO purges(id,packet,revision,pending) VALUES(?,?,?,0)
      ON CONFLICT(id) DO UPDATE SET packet=excluded.packet,
      revision=max(purges.revision,excluded.revision),pending=0''',
      [marker.recordId, jsonEncode(marker.toJson()), revision],
    );
  }

  void acceptPurge(CipherRecord marker, int revision) =>
      transaction(() => _applyPurge(marker, revision));
  bool hasPending(String id) => db.select(
    'SELECT 1 FROM outbox WHERE record_id=? LIMIT 1',
    [id],
  ).isNotEmpty;

  T transaction<T>(T Function() operation) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = operation();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  StoredRecord _row(Row row) => StoredRecord(
    CipherRecord.fromJson(jsonDecode(row['packet'] as String) as Json),
    row['revision'] as int,
    row['server_revision'] as int,
  );
  List<StoredRecord> all() =>
      db.select('SELECT * FROM records').map(_row).toList();
  StoredRecord? get(String id) {
    final rows = db.select('SELECT * FROM records WHERE id=?', [id]);
    return rows.isEmpty ? null : _row(rows.first);
  }

  void _history(CipherRecord packet) {
    if (isPurged(packet.recordId)) return;
    db.execute(
      'INSERT OR IGNORE INTO history(record_id,operation_id,packet) VALUES (?,?,?)',
      [packet.recordId, packet.operationId, jsonEncode(packet.toJson())],
    );
    db.execute(
      'DELETE FROM history WHERE record_id=? AND seq NOT IN (SELECT seq FROM history WHERE record_id=? ORDER BY seq DESC LIMIT 30)',
      [packet.recordId, packet.recordId],
    );
  }

  void checkpoint(CipherRecord packet) => transaction(() => _history(packet));

  void saveLocal(
    CipherRecord packet, {
    bool recordHistory = false,
    bool checkpoint = false,
  }) => transaction(() {
    _saveLocal(packet, recordHistory: recordHistory);
    if (checkpoint) _history(packet);
  });

  // A recurring completion archives this occurrence and advances the series
  // together, so a failed write cannot leave only half of that change.
  void saveLocalBatch(
    Iterable<CipherRecord> packets, {
    bool recordHistory = false,
    ({String from, String to, RelinkImage sign})? copyImages,
  }) => transaction(() {
    for (final packet in packets) {
      _saveLocal(packet, recordHistory: recordHistory);
    }
    if (copyImages != null) {
      _copyImages(copyImages.from, copyImages.to, copyImages.sign);
    }
  });

  void _saveLocal(CipherRecord packet, {required bool recordHistory}) {
    if (isPurged(packet.recordId)) throw const FormatException('这条备忘录已永久删除');
    final old = get(packet.recordId);
    final base = old?.revision ?? 0;
    if (recordHistory && old != null) _history(old.packet);
    db.execute(
      'INSERT INTO outbox(operation_id,record_id,base_revision,packet) VALUES (?,?,?,?)',
      [packet.operationId, packet.recordId, base, jsonEncode(packet.toJson())],
    );
    db.execute(
      'INSERT INTO records(id,packet,revision,server_revision) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET packet=excluded.packet, revision=excluded.revision',
      [
        packet.recordId,
        jsonEncode(packet.toJson()),
        base + 1,
        old?.serverRevision ?? 0,
      ],
    );
  }

  List<PendingOperation> pending() => db
      .select('SELECT * FROM outbox ORDER BY seq LIMIT 100')
      .map(
        (row) => PendingOperation(
          CipherRecord.fromJson(jsonDecode(row['packet'] as String) as Json),
          row['base_revision'] as int,
        ),
      )
      .toList();

  bool containsOperation(String id) =>
      db.select('SELECT 1 FROM outbox WHERE operation_id=?', [id]).isNotEmpty;

  void acknowledge(CipherRecord packet, int revision) => transaction(() {
    db.execute('DELETE FROM outbox WHERE operation_id=?', [packet.operationId]);
    db.execute(
      'UPDATE records SET server_revision=max(server_revision,?) WHERE id=?',
      [revision, packet.recordId],
    );
  });

  void prepareNewServer(List<CipherRecord> packets) => transaction(() {
    db.execute('DELETE FROM outbox');
    db.execute('DELETE FROM records');
    setMeta('cursor', '0');
    setMeta('envelope_revision', '1');
    removeMeta('envelope_dirty');
    db.execute('UPDATE purges SET pending=1,revision=0');
    for (final packet in packets) {
      db.execute(
        'INSERT INTO records(id,packet,revision,server_revision) VALUES (?,?,1,0)',
        [packet.recordId, jsonEncode(packet.toJson())],
      );
      db.execute(
        'INSERT INTO outbox(operation_id,record_id,base_revision,packet) VALUES (?,?,0,?)',
        [packet.operationId, packet.recordId, jsonEncode(packet.toJson())],
      );
    }
  });

  void _applyRemote(CipherRecord packet, int revision) {
    if (isPurged(packet.recordId)) return;
    final old = get(packet.recordId);
    if (old != null && old.serverRevision >= revision) return;
    if (hasPending(packet.recordId)) return;
    // Remote autosaves are not explicit local version checkpoints.
    db.execute(
      'INSERT INTO records(id,packet,revision,server_revision) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET packet=excluded.packet,revision=excluded.revision,server_revision=excluded.server_revision',
      [packet.recordId, jsonEncode(packet.toJson()), revision, revision],
    );
  }

  // All packets must have been authenticated before this transaction starts.
  void applyPage(
    List<({CipherRecord packet, int revision})> page,
    int newCursor, {
    Set<String> purgedIds = const {},
  }) => transaction(() {
    for (final item in page) {
      if (purgedIds.contains(item.packet.operationId)) {
        _applyPurge(item.packet, item.revision);
      } else {
        _applyRemote(item.packet, item.revision);
      }
    }
    setMeta('cursor', newCursor.toString());
  });

  void resolveConflict(
    String originalId,
    CipherRecord copy,
    CipherRecord? remote,
    int revision, {
    required RelinkImage relinkImage,
  }) => transaction(() {
    if (isPurged(originalId)) return;
    // The dedicated conflict copy already preserves the local edit.
    db.execute('DELETE FROM outbox WHERE record_id=?', [originalId]);
    db.execute('DELETE FROM records WHERE id=?', [originalId]);
    if (remote != null) _applyRemote(remote, revision);
    db.execute(
      'INSERT INTO records(id,packet,revision,server_revision) VALUES (?,?,1,0)',
      [copy.recordId, jsonEncode(copy.toJson())],
    );
    db.execute(
      'INSERT INTO outbox(operation_id,record_id,base_revision,packet) VALUES (?,?,0,?)',
      [copy.operationId, copy.recordId, jsonEncode(copy.toJson())],
    );
    _copyImages(originalId, copy.recordId, relinkImage);
    if (remote == null) {
      db.execute('DELETE FROM memo_images WHERE record_id=?', [originalId]);
    }
  });

  List<MemoImageLink> imageLinks(String memoId) => db
      .select(
        '''
    SELECT a.*, m.tag FROM memo_images m JOIN attachments a ON a.id=m.attachment_id
    WHERE m.record_id=? ORDER BY m.rowid
  ''',
        [memoId],
      )
      .map(
        (r) => (
          memoId: memoId,
          tag: r['tag'] as Uint8List,
          image: ImageAttachment(
            r['id'] as String,
            r['origin_id'] as String,
            r['width'] as int,
            r['height'] as int,
            r['byte_length'] as int,
          ),
        ),
      )
      .toList();

  List<ImageChunk> imageChunks(ImageAttachment image) {
    image.validate();
    final rows = db.select(
      'SELECT part,nonce,ciphertext FROM attachment_chunks WHERE attachment_id=? ORDER BY part LIMIT ?',
      [image.id, image.chunkCount + 1],
    );
    final chunks = <ImageChunk>[];
    for (final row in rows) {
      if (row['part'] != chunks.length) throw const FormatException('图片分块不连续');
      chunks.add((
        nonce: row['nonce'] as Uint8List,
        ciphertext: row['ciphertext'] as Uint8List,
      ));
    }
    return chunks;
  }

  void _insertImageLink(MemoImageLink link) => db.execute(
    'INSERT INTO memo_images(record_id,attachment_id,tag) VALUES(?,?,?)',
    [link.memoId, link.image.id, link.tag],
  );

  // Take the attachment snapshot in the same transaction as the new record.
  // Recurring occurrences may reuse an existing deterministic archive ID.
  void _copyImages(String from, String to, RelinkImage sign) {
    if (from == to) return;
    db.execute('DELETE FROM memo_images WHERE record_id=?', [to]);
    for (final source in imageLinks(from)) {
      _insertImageLink(sign(source, to));
    }
  }

  void _checkImageMemo(String memoId, String expectedOperation) {
    final packet = get(memoId)?.packet;
    if (packet == null ||
        packet.deleted ||
        packet.operationId != expectedOperation) {
      throw const FormatException('备忘录已变化，请重新打开后再修改图片');
    }
  }

  void addImage(
    MemoImageLink link,
    List<ImageChunk> chunks,
    String expectedOperation,
  ) => transaction(() {
    _checkImageMemo(link.memoId, expectedOperation);
    final image = link.image;
    image.validate();
    if (chunks.length != image.chunkCount) {
      throw const FormatException('图片分块不完整');
    }
    if (imageLinks(link.memoId).length >= ImageAttachment.maxPerMemo) {
      throw const FormatException(ImageAttachment.countLimitMessage);
    }
    final used =
        db
                .select(
                  'SELECT coalesce(sum(byte_length),0) AS n FROM attachments',
                )
                .first['n']
            as int;
    if (used + image.byteLength > ImageAttachment.maxVaultBytes) {
      throw const FormatException('本机资料库的图片已达 500 MiB 上限');
    }
    db.execute(
      'INSERT INTO attachments(id,origin_id,width,height,byte_length) VALUES(?,?,?,?,?)',
      [image.id, image.originId, image.width, image.height, image.byteLength],
    );
    for (var i = 0; i < chunks.length; i++) {
      db.execute(
        'INSERT INTO attachment_chunks(attachment_id,part,nonce,ciphertext) VALUES(?,?,?,?)',
        [image.id, i, chunks[i].nonce, chunks[i].ciphertext],
      );
    }
    _insertImageLink(link);
  });

  void removeImage(String memoId, String imageId, String expectedOperation) =>
      transaction(() {
        _checkImageMemo(memoId, expectedOperation);
        db.execute(
          'DELETE FROM memo_images WHERE record_id=? AND attachment_id=?',
          [memoId, imageId],
        );
      });

  List<CipherRecord> history(String id) => db
      .select(
        'SELECT packet FROM history WHERE record_id=? ORDER BY seq DESC',
        [id],
      )
      .map(
        (row) =>
            CipherRecord.fromJson(jsonDecode(row['packet'] as String) as Json),
      )
      .toList();

  Json snapshot() => {
    'format': 1,
    'records': all().map((r) => r.packet.toJson()).toList(),
    'history': db
        .select('SELECT packet FROM history ORDER BY seq')
        .map((r) => jsonDecode(r['packet'] as String))
        .toList(),
    'purges': purgeMarkers().map((p) => p.toJson()).toList(),
  };

  void restore(
    Json envelope,
    List<CipherRecord> packets,
    List<CipherRecord> historyPackets, {
    List<CipherRecord> purges = const [],
  }) => transaction(() {
    if (this.envelope != null) throw StateError('恢复备份需要一个空的本地资料库');
    setMeta('envelope', jsonEncode(envelope));
    for (final marker in purges) {
      db.execute(
        'INSERT INTO purges(id,packet,revision,pending) VALUES(?,?,0,1)',
        [marker.recordId, jsonEncode(marker.toJson())],
      );
    }
    for (final packet in packets) {
      if (isPurged(packet.recordId)) continue;
      db.execute(
        'INSERT INTO records(id,packet,revision,server_revision) VALUES (?,?,1,0)',
        [packet.recordId, jsonEncode(packet.toJson())],
      );
      db.execute(
        'INSERT INTO outbox(operation_id,record_id,base_revision,packet) VALUES (?,?,0,?)',
        [packet.operationId, packet.recordId, jsonEncode(packet.toJson())],
      );
    }
    for (final packet in historyPackets) {
      _history(packet);
    }
  });

  void close() {
    db.close();
  }
}
