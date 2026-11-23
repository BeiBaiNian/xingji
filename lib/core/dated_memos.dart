import 'models.dart';

DateTime? memoDate(Memo memo, String basis) => switch (basis) {
  'scheduled' => memo.reminderAt,
  'completed' => memo.done ? memo.completedAt : null,
  _ => memo.done ? memo.completedAt : memo.reminderAt,
};

bool matchesMemoDate(Memo memo, DateTime day, String status, String basis) {
  if (memo.deleted || memo.purged) return false;
  if (status == 'open' && memo.done || status == 'done' && !memo.done) {
    return false;
  }
  final time = memoDate(memo, basis)?.toLocal();
  return time != null &&
      time.year == day.year &&
      time.month == day.month &&
      time.day == day.day;
}

int compareDatedMemos(Memo a, Memo b, String basis) {
  if (a.done != b.done) return a.done ? 1 : -1;
  if (!a.done && a.priority != b.priority) {
    return b.priority.compareTo(a.priority);
  }
  final time = memoDate(a, basis)!.compareTo(memoDate(b, basis)!);
  if (time != 0) return a.done ? -time : time;
  return a.id.compareTo(b.id);
}
