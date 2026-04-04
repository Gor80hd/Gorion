import 'package:gorion_clean/features/profiles/model/profile_entity.dart';

/// Returns profiles ordered for display. In gorion_clean there is no
/// custom display order, so the list is returned as-is.
List<ProfileEntity> sortProfilesForDisplay(
  List<ProfileEntity> profiles,
  List<String> storedOrder,
) {
  if (storedOrder.isEmpty) return profiles;

  final indexed = {for (var i = 0; i < storedOrder.length; i++) storedOrder[i]: i};
  return [...profiles]..sort((a, b) {
    final ia = indexed[a.id] ?? 9999;
    final ib = indexed[b.id] ?? 9999;
    return ia.compareTo(ib);
  });
}
