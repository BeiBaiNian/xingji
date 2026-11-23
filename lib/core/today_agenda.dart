import 'models.dart';

/// A local-calendar view only. Passing a deadline never completes a memo.
class TodayAgenda {
  TodayAgenda(Iterable<Memo> memos, DateTime now) {
    final local = now.toLocal();
    day = DateTime(local.year, local.month, local.day);
    nextChange = DateTime(local.year, local.month, local.day + 1);
    final tomorrow = nextChange;
    for (final memo in memos) {
      if (memo.done || memo.deleted) continue;
      hasOpenMemos = true;
      final time = memo.reminderAt;
      if (time == null || time.isBefore(day) || !time.isBefore(tomorrow)) {
        continue;
      }
      if (time.isAfter(now)) {
        pending.add(memo);
        if (time.isBefore(nextChange)) nextChange = time;
      } else {
        elapsed.add(memo);
      }
    }
    pending.sort(_compare);
    elapsed.sort(_compare);
  }

  late final DateTime day;
  late DateTime nextChange;
  bool hasOpenMemos = false;
  final List<Memo> pending = [], elapsed = [];
  int get length => pending.length + elapsed.length;

  static int _compare(Memo a, Memo b) {
    final priority = b.priority.compareTo(a.priority);
    if (priority != 0) return priority;
    final time = a.reminderAt!.compareTo(b.reminderAt!);
    if (time != 0) return time;
    final created = a.createdAt.compareTo(b.createdAt);
    return created != 0 ? created : a.id.compareTo(b.id);
  }
}
