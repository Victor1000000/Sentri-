import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/i18n/i18n.dart';
import '../../core/platform/native_bridge.dart';

/// Shows which permissions Sentri needs and lets the user turn each on. Used in onboarding and in
/// Settings. Re-checks when the app returns from the system settings screens.
class PermissionsPanel extends StatefulWidget {
  const PermissionsPanel({super.key, required this.bridge, required this.i18n});
  final NativeBridge bridge;
  final I18n i18n;

  @override
  State<PermissionsPanel> createState() => _PermissionsPanelState();
}

class _PermissionsPanelState extends State<PermissionsPanel> with WidgetsBindingObserver {
  NativePermissions _native = const NativePermissions();
  bool _location = false, _notifications = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final native = await widget.bridge.permissions();
    final loc = await Permission.locationAlways.isGranted;
    final notif = await Permission.notification.isGranted;
    if (!mounted) return;
    setState(() {
      _native = native;
      _location = loc;
      _notifications = notif;
    });
  }

  Future<void> _askLocation() async {
    // Android requires "while using" first; "always" is a second, separate prompt.
    await Permission.locationWhenInUse.request();
    await Permission.locationAlways.request();
    await _refresh();
  }

  /// One permission: its name on the left, and either "On" or a button on the right.
  /// The button gets its own width. The app's buttons are full-width by default, and a full-width button inside
  /// a list row squeezes the name into a column of single letters.
  Widget _row(String key, bool on, Future<void> Function() action) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(widget.i18n.t(key))),
          const SizedBox(width: 12),
          if (on)
            Chip(label: Text(widget.i18n.t('perm.on')))
          else
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(96, 44), padding: const EdgeInsets.symmetric(horizontal: 20)),
              onPressed: () => unawaited(action()),
              child: Text(widget.i18n.t('perm.turn_on')),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final android = Platform.isAndroid;
    return Column(
      children: [
        _row('perm.location', _location, _askLocation),
        _row('perm.notifications', _notifications, () async {
          await Permission.notification.request();
          await _refresh();
        }),
        if (android) ...[
          _row('perm.overlay', _native.overlay, () => widget.bridge.openSettings('overlay')),
          _row('perm.accessibility', _native.accessibility, () => widget.bridge.openSettings('accessibility')),
          _row('perm.battery', _native.batteryUnrestricted, () => widget.bridge.openSettings('battery')),
        ],
      ],
    );
  }
}
