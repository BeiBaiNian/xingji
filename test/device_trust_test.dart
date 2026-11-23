import 'package:flutter_test/flutter_test.dart';
import 'package:xingji/core/device_trust_policy.dart';

void main() {
  test('三天免密固定 72 小时窗口，不因反复打开而续期', () {
    final verified = DateTime.utc(2026, 10, 30, 2);
    final value = verified.toIso8601String();
    expect(DeviceTrustPolicy.valid(value, verified), true);
    expect(
      DeviceTrustPolicy.valid(value, verified.add(const Duration(days: 2))),
      true,
    );
    expect(
      DeviceTrustPolicy.valid(
        value,
        verified.add(const Duration(hours: 72, milliseconds: -1)),
      ),
      true,
    );
    expect(
      DeviceTrustPolicy.valid(value, verified.add(const Duration(hours: 72))),
      false,
    );
    expect(
      DeviceTrustPolicy.valid(value, verified.add(const Duration(days: 4))),
      false,
    );
  });
  test('未记录、损坏和时钟倒退不自动延长可信期限', () {
    final now = DateTime.utc(2026, 10, 30);
    expect(DeviceTrustPolicy.valid(null, now), false);
    expect(DeviceTrustPolicy.valid('invalid', now), false);
    expect(
      DeviceTrustPolicy.valid(
        now.add(const Duration(minutes: 1)).toIso8601String(),
        now,
      ),
      false,
    );
    expect(DeviceTrustPolicy.valid('2026-10-30T08:00:00+08:00', now), true);
  });
}
