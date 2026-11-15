/// Per-brand battery guide data: which settings screens keep Snapy's counter alive.
/// Component names are tried in order (they differ across OS versions; many aren't exported,
/// then the next one or the generic Android screen is used). Overridable from config
/// `android.realcount.oem.<brand>`; the steps' wording lives in i18n (`oem.<brand>.steps`).
library;

class OemTarget {
  final String? pkg, cls, action;
  const OemTarget({this.pkg, this.cls, this.action});
  Map<String, String?> toArgs() => {'pkg': pkg, 'cls': cls, 'action': action};
  static OemTarget? fromJson(dynamic j) =>
      j is Map ? OemTarget(pkg: j['pkg'] as String?, cls: j['cls'] as String?, action: j['action'] as String?) : null;
}

const Map<String, List<OemTarget>> oemTargets = {
  'xiaomi': [
    OemTarget(pkg: 'com.miui.securitycenter', cls: 'com.miui.permcenter.autostart.AutoStartManagementActivity'),
    OemTarget(pkg: 'com.miui.powerkeeper', cls: 'com.miui.powerkeeper.ui.HiddenAppsConfigActivity'),
  ],
  'oppo': [
    OemTarget(pkg: 'com.coloros.safecenter', cls: 'com.coloros.safecenter.permission.startup.StartupAppListActivity'),
    OemTarget(pkg: 'com.coloros.safecenter', cls: 'com.coloros.safecenter.startupapp.StartupAppListActivity'),
    OemTarget(pkg: 'com.oppo.safe', cls: 'com.oppo.safe.permission.startup.StartupAppListActivity'),
  ],
  'vivo': [
    OemTarget(pkg: 'com.vivo.permissionmanager', cls: 'com.vivo.permissionmanager.activity.BgStartUpManagerActivity'),
    OemTarget(pkg: 'com.iqoo.secure', cls: 'com.iqoo.secure.ui.phoneoptimize.BgStartUpManager'),
  ],
  'samsung': [
    OemTarget(pkg: 'com.samsung.android.lool', cls: 'com.samsung.android.sm.battery.ui.BatteryActivity'),
    OemTarget(pkg: 'com.samsung.android.sm', cls: 'com.samsung.android.sm.ui.battery.BatteryActivity'),
  ],
  'oneplus': [
    OemTarget(pkg: 'com.oneplus.security', cls: 'com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity'),
  ],
  'other': [],
};

/// Always offered last: Android's own battery-optimisation list (no permission needed).
const genericTargets = [
  OemTarget(action: 'android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS'),
  OemTarget(action: 'android.settings.APPLICATION_DETAILS_SETTINGS'),
];

/// Build.MANUFACTURER / BRAND -> guide id.
String oemOf(String manufacturer, [String brand = '']) {
  final m = '${manufacturer.toLowerCase()} ${brand.toLowerCase()}';
  if (RegExp(r'xiaomi|redmi|poco').hasMatch(m)) return 'xiaomi';
  if (RegExp(r'oppo|realme').hasMatch(m)) return 'oppo';
  if (RegExp(r'vivo|iqoo').hasMatch(m)) return 'vivo';
  if (m.contains('samsung')) return 'samsung';
  if (m.contains('oneplus')) return 'oneplus';
  return 'other';
}

List<OemTarget> targetsFor(String oem, dynamic configOverride) {
  final o = configOverride is Map ? configOverride[oem] : null;
  final custom = o is List ? o.map(OemTarget.fromJson).whereType<OemTarget>().toList() : null;
  return [...(custom ?? oemTargets[oem] ?? const []), ...genericTargets];
}

const oemIds = ['xiaomi', 'oppo', 'vivo', 'samsung', 'oneplus', 'other'];
