import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'storage/key_value_store.dart';

/// The person's own profile: a name and a chosen photo, kept on this phone only.
/// The name is also sent to the server so alerts read "Ada needs you" instead of
/// a phone number; the photo never leaves the phone.
class Profile extends ChangeNotifier {
  Profile(this._store);
  final KeyValueStore _store;
  static const _nameKey = 'profile.name.v1';
  static const _avatarKey = 'profile.avatar.v1';
  static const _iconKey = 'profile.avatar.icon.v1';
  static const _iconOnKey = 'profile.avatar.icon.on.v1';

  String _name = '';
  Uint8List? _avatar;
  int? _icon;
  bool _iconOn = false;
  bool _loaded = false;

  String get name => _name;
  Uint8List? get avatar => _avatar;

  /// Which of the app's 50 drawn Sentri faces is the person's pick (null = none).
  int? get avatarIcon => _icon;

  /// True when the app icon (not a gallery photo) is what the person chose last.
  bool get useIcon => _iconOn;
  bool get loaded => _loaded;

  // v42: every store call is wrapped. The profile lives in the phone's encrypted
  // key-value store, and on some devices a single failed read/write there used to
  // throw straight through into the UI - the profile sheet froze mid-save and the
  // app went blank until a restart. Storage problems now stop at this boundary:
  // the app keeps running, and a save that could not stick simply tries again next
  // time the sheet is used.
  Future<String?> _read(String key) async {
    try {
      return await _store.read(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (_) {}
  }

  Future<void> _delete(String key) async {
    try {
      await _store.delete(key);
    } catch (_) {}
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final n = await _read(_nameKey);
    if (n != null && n.isNotEmpty) _name = n;
    final a = await _read(_avatarKey);
    if (a != null && a.isNotEmpty) {
      try {
        _avatar = base64Decode(a);
      } catch (_) {
        _avatar = null;
      }
    }
    final i = int.tryParse(await _read(_iconKey) ?? '');
    if (i != null && i >= 0 && i < 50) _icon = i;
    _iconOn = (await _read(_iconOnKey)) == '1' && _icon != null;
    notifyListeners();
  }

  /// Save the name, and mirror it to the server (so alerts and inbox items use it).
  /// Server errors never wipe the local copy: an offline save still sticks here.
  ///
  /// v42: the local save completes first and this future resolves as soon as it has,
  /// while the server mirror runs in the background. Waiting for a server that is
  /// waking up from sleep used to hold the profile sheet's Save button for a minute
  /// or more - now the sheet closes the moment the name is safe on the phone. A
  /// mirror that fails (offline, signed out, the server said no) is retried the next
  /// time a save happens; it can never affect the UI.
  Future<void> setName(String value, {Future<void> Function(String)? syncToServer}) async {
    final clean = value.trim();
    if (clean == _name) return;
    _name = clean;
    await _write(_nameKey, clean);
    notifyListeners();
    if (syncToServer != null) {
      unawaited(() async {
        try {
          await syncToServer(clean);
        } catch (_) {
          // Offline or signed out: the name is safe on the phone; a later save sends it.
        }
      }());
    }
  }

  Future<void> setAvatar(Uint8List? bytes) async {
    _avatar = bytes;
    if (bytes == null || bytes.isEmpty) {
      _avatar = null;
      await _delete(_avatarKey);
    } else {
      await _write(_avatarKey, base64Encode(bytes));
    }
    // A gallery photo is the person's latest choice: it wins over the icon.
    _iconOn = false;
    await _write(_iconOnKey, '0');
    notifyListeners();
  }

  /// Picks one of the app's 50 drawn Sentri faces. Null clears the pick; the
  /// gallery photo (if any) shows again.
  Future<void> setIcon(int? i) async {
    _icon = (i == null || i < 0 || i >= 50) ? null : i;
    _iconOn = _icon != null;
    if (_icon == null) {
      await _delete(_iconKey);
      await _write(_iconOnKey, '0');
    } else {
      await _write(_iconKey, '$_icon');
      await _write(_iconOnKey, '1');
    }
    notifyListeners();
  }
}

/// Picks a photo from the phone's gallery. The picker itself shrinks and compresses
/// the image (about 512 px JPEG), which keeps it small enough to stay on the phone:
/// the profile photo lives in the phone's encrypted key-value store, and a photo
/// sized for a 74 px circle does not strain it. The circle shape happens at display
/// time, so no cropping tool is needed.
Future<Uint8List?> pickAvatarImage() async {
  try {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, maxHeight: 512, imageQuality: 78);
    if (x == null) return null;
    return await x.readAsBytes();
  } catch (_) {
    return null;
  }
}
