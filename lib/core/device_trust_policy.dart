/// A fixed verification window. Merely opening the app never renews it.
class DeviceTrustPolicy {
  static const duration = Duration(days: 3);
  static bool valid(String? verifiedAt, DateTime now) {
    final verified = DateTime.tryParse(verifiedAt ?? '');
    if (verified == null) return false;
    final age = now.toUtc().difference(verified.toUtc());
    return !age.isNegative && age < duration;
  }
}
