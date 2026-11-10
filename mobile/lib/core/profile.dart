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

  String _name = '';
  Uint8List? _avatar;
  bool _loaded = false;

  String get name => _name;
  Uint8List? get avatar => _avatar;
  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final n = await _store.read(_nameKey);
    if (n != null && n.isNotEmpty) _name = n;
    final a = await _store.read(_avatarKey);
    if (a != null && a.isNotEmpty) {
      try {
        _avatar = base64Decode(a);
      } catch (_) {
        _avatar = null;
      }
    }
    notifyListeners();
  }

  /// Save the name, and mirror it to the server (so alerts and inbox items use it).
  /// Server errors never wipe the local copy: an offline save still sticks here.
  Future<void> setName(String value, {Future<void> Function(String)? syncToServer}) async {
    final clean = value.trim();
    if (clean == _name) return;
    _name = clean;
    await _store.write(_nameKey, clean);
    notifyListeners();
    if (syncToServer != null) {
      try {
        await syncToServer(clean);
      } catch (_) {
        // Offline or signed out: the name is safe on the phone; a later save sends it.
      }
    }
  }

  Future<void> setAvatar(Uint8List? bytes) async {
    _avatar = bytes;
    if (bytes == null || bytes.isEmpty) {
      _avatar = null;
      await _store.delete(_avatarKey);
    } else {
      await _store.write(_avatarKey, base64Encode(bytes));
    }
    notifyListeners();
  }
}

/// Picks a photo from the phone's gallery. The picker itself shrinks and compresses
/// the image (about 512 px JPEG), which keeps it small enough to stay on the phone.
/// The circle shape happens at display time, so no cropping tool is needed.
Future<Uint8List?> pickAvatarImage() async {
  try {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 720, maxHeight: 720, imageQuality: 82);
    if (x == null) return null;
    return await x.readAsBytes();
  } catch (_) {
    return null;
  }
}
