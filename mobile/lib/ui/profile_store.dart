import 'package:flutter/foundation.dart';

import '../core/next_api.dart';

/// The person's name and the assistant's name, shared by every tab (Home greets with it,
/// Profile edits it, onboarding sets it first).
class ProfileStore {
  ProfileStore._();

  static final ValueNotifier<SnapyProfile> notifier = ValueNotifier(const SnapyProfile());
  static SnapyProfile get current => notifier.value;

  static Future<SnapyProfile> load() async {
    final p = await NextApi.profile();
    notifier.value = p;
    return p;
  }

  /// Saves and updates every listener right away (the screen never waits on the phone).
  static Future<bool> save({String? name, String? assistantName, String? iceNotes}) async {
    final old = notifier.value;
    notifier.value = SnapyProfile(
      name: name ?? old.name,
      assistantName: (assistantName == null || assistantName.trim().isEmpty) ? old.assistantName : assistantName.trim(),
      iceNotes: iceNotes ?? old.iceNotes,
    );
    final stored = await NextApi.setProfile(name: name, assistantName: assistantName, iceNotes: iceNotes);
    return stored != null;
  }

  /// Tests.
  static void reset() => notifier.value = const SnapyProfile();
}
