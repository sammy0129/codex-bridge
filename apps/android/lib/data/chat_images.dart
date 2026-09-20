import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'transport.dart';

const maxImageBytes = 20 * 1024 * 1024;

String imageMimeType(List<int> bytes) {
  bool starts(List<int> signature, [int offset = 0]) =>
      bytes.length >= signature.length + offset &&
      Iterable<int>.generate(signature.length)
          .every((index) => bytes[index + offset] == signature[index]);
  if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'image/png';
  if (starts([255, 216, 255])) return 'image/jpeg';
  if (starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a'))) {
    return 'image/gif';
  }
  if (starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8)) {
    return 'image/webp';
  }
  throw const RpcException('INVALID_IMAGE', '图片格式不支持');
}

void validateImageBytes(List<int> bytes, {bool upload = false}) {
  if (bytes.length > maxImageBytes) {
    throw const RpcException('IMAGE_TOO_LARGE', '单张图片不能超过 20 MiB');
  }
  final mime = imageMimeType(bytes);
  if (upload && mime != 'image/png' && mime != 'image/jpeg') {
    throw const RpcException('INVALID_IMAGE', '上传仅支持 PNG 或 JPEG 图片');
  }
}

String imageFailureMessage(Object? error) {
  if (error is RpcException) {
    return switch (error.code) {
      'IMAGE_READ_UNSUPPORTED' => '请升级主机 Bridge 后查看图片',
      'IMAGE_TOO_LARGE' => '单张图片不能超过 20 MiB',
      'INVALID_IMAGE' => '图片格式不支持或文件已损坏',
      'UNAUTHORIZED' => '设备授权已失效，请重新配对',
      'OUTCOME_UNKNOWN' => '上传结果未知，请检查主机后再操作',
      'OFFLINE' || 'UPSTREAM_LOST' => '连接主机后重试',
      _ => '图片不可用，原文件可能已删除或无法访问',
    };
  }
  return '图片不可用，请检查网络或图片文件';
}

class ChatImageCache {
  final int maxBytes;
  final int maxEntries;
  final _entries = <String, Uint8List>{};
  final _pending = <String, Future<Uint8List>>{};
  int _bytes = 0;
  int _generation = 0;
  ChatImageCache({this.maxBytes = 40 * 1024 * 1024, this.maxEntries = 48});

  Future<Uint8List> load(String key, Future<Uint8List> Function() fetch) {
    final cached = _entries.remove(key);
    if (cached != null) {
      _entries[key] = cached;
      return Future.value(cached);
    }
    if (_pending.containsKey(key)) return _pending[key]!;
    final generation = _generation;
    late final Future<Uint8List> future;
    future = Future<Uint8List>.sync(fetch)
        .then((bytes) {
          if (generation == _generation &&
              identical(_pending[key], future) &&
              bytes.length <= maxBytes) {
            while (_entries.isNotEmpty &&
                (_bytes + bytes.length > maxBytes ||
                    _entries.length >= maxEntries)) {
              _bytes -= _entries.remove(_entries.keys.first)!.length;
            }
            _entries[key] = bytes;
            _bytes += bytes.length;
          }
          return bytes;
        })
        .whenComplete(() {
          if (identical(_pending[key], future)) _pending.remove(key);
        });
    _pending[key] = future;
    return future;
  }

  void clear() {
    _generation++;
    _entries.clear();
    _pending.clear();
    _bytes = 0;
  }

  void removeWhere(bool Function(String) matches) {
    for (final key in _entries.keys.where(matches).toList()) {
      _bytes -= _entries.remove(key)!.length;
    }
    _pending.removeWhere((key, _) => matches(key));
  }
}

typedef ImageDownload = Future<Uint8List> Function(
  Uri uri, {
  String? fingerprint,
  String? token,
});

class ChatImageLoader {
  final ChatImageCache cache;
  final ImageDownload download;
  ChatImageLoader({ChatImageCache? cache, ImageDownload? download})
    : cache = cache ?? ChatImageCache(),
      download = download ?? httpImage;

  void forgetThread(String hostId, String threadId) {
    final prefix = '${jsonEncode([hostId, threadId])}:';
    cache.removeWhere((key) => key.startsWith(prefix));
  }

  Future<Uint8List> load({
    required Host host,
    required String projectId,
    required String threadId,
    required String itemId,
    required int contentIndex,
    required Json content,
    required bool supportsRead,
    required Future<String?> Function() token,
  }) {
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              host.id,
              host.url,
              host.fingerprint,
              host.deviceId,
              projectId,
              threadId,
              itemId,
              contentIndex,
              content,
            ]),
          ),
        )
        .toString();
    return cache.load('${jsonEncode([host.id, threadId])}:$key', () async {
      Uint8List bytes;
      if (content['type'] == 'localImage') {
        if (!supportsRead) {
          throw const RpcException('IMAGE_READ_UNSUPPORTED', '请升级主机 Bridge');
        }
        final credential = await token();
        if (credential == null) {
          throw const RpcException('UNAUTHORIZED', '请重新配对');
        }
        bytes = await download(
          Uri.parse(host.url).replace(
            path: '/v1/thread-images',
            queryParameters: {
              'projectId': projectId,
              'threadId': threadId,
              'itemId': itemId,
              'contentIndex': '$contentIndex',
            },
          ),
          fingerprint: host.fingerprint,
          token: credential,
        );
      } else {
        final url = content['url']?.toString() ?? '';
        if (url.startsWith('data:')) {
          if (url.length > maxImageBytes * 4 ~/ 3 + 1024) {
            throw const RpcException('IMAGE_TOO_LARGE', '图片过大');
          }
          try {
            final data = UriData.parse(url);
            if (!data.mimeType.startsWith('image/')) {
              throw const FormatException();
            }
            bytes = Uint8List.fromList(data.contentAsBytes());
          } on FormatException {
            throw const RpcException('INVALID_IMAGE', '图片数据无效');
          }
        } else {
          final uri = Uri.tryParse(url);
          if (uri == null ||
              uri.scheme != 'https' ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty) {
            throw const RpcException('INVALID_IMAGE', '仅支持 HTTPS 图片地址');
          }
          bytes = await download(uri);
        }
      }
      validateImageBytes(bytes);
      return bytes;
    });
  }
}
