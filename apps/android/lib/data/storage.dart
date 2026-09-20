import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

abstract class LocalStore {
  Future<Json> read(String key);
  Future<void> write(String key, Json value);
  Future<String?> token(String hostId);
  Future<void> saveToken(String hostId, String token);
  Future<void> remove(String hostId);
}

class DeviceStore implements LocalStore {
  final FlutterSecureStorage secure = const FlutterSecureStorage();
  final Map<String, Future<void>> _writes = {};
  Future<File> _file(String key) async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}/$key.json');
  }

  @override
  Future<Json> read(String key) async {
    final file = await _file(key);
    if (!await file.exists()) return {};
    try {
      return asJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      return {};
    }
  }

  @override
  Future<void> write(String key, Json value) {
    final encoded = jsonEncode(value);
    final previous = _writes[key] ?? Future.value();
    final operation = previous.catchError((_) {}).then((_) async {
      final file = await _file(key);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(file.path);
    });
    _writes[key] = operation;
    return operation;
  }

  @override
  Future<String?> token(String hostId) =>
      secure.read(key: 'bridge-token-$hostId');
  @override
  Future<void> saveToken(String hostId, String token) =>
      secure.write(key: 'bridge-token-$hostId', value: token);
  @override
  Future<void> remove(String hostId) async {
    await secure.delete(key: 'bridge-token-$hostId');
    final file = await _file('cache-$hostId');
    if (await file.exists()) await file.delete();
  }
}
