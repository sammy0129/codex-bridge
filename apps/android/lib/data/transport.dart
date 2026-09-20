import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

bool certificateMatches(List<int> der, String expected) =>
    sha256.convert(der).toString() ==
    expected.replaceAll(':', '').toLowerCase();

HttpClient secureClient(Uri origin, String? fingerprint) {
  final client = HttpClient(
    context: SecurityContext(withTrustedRoots: fingerprint == null),
  );
  client.connectionTimeout = const Duration(seconds: 12);
  client.badCertificateCallback = (certificate, host, port) =>
      fingerprint != null &&
      host == origin.host &&
      port == origin.port &&
      certificateMatches(certificate.der, fingerprint);
  return client;
}

Future<Json> httpJson(
  Uri origin,
  String path, {
  String? fingerprint,
  String? token,
  Json? body,
}) async {
  final client = secureClient(origin, fingerprint);
  try {
    final request = await client.openUrl(
      body == null ? 'GET' : 'POST',
      origin.replace(path: path),
    );
    request.followRedirects = false;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.isRedirect) {
      throw const RpcException(
        'REDIRECT_REJECTED',
        'Use the final HTTPS address; authenticated redirects are disabled.',
      );
    }
    final value = asJson(jsonDecode(await utf8.decoder.bind(response).join()));
    if (response.statusCode >= 400) {
      throw RpcException.fromJson(asJson(value['error']));
    }
    return value;
  } finally {
    client.close(force: true);
  }
}

Future<Uint8List> httpImage(
  Uri uri, {
  String? fingerprint,
  String? token,
}) async {
  if (uri.scheme != 'https') {
    throw const RpcException('INVALID_IMAGE', '图片请求必须使用 HTTPS');
  }
  final client = secureClient(uri, fingerprint);
  Future<Uint8List> read() async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    final response = await request.close();
    if (response.isRedirect) {
      throw const RpcException('REDIRECT_REJECTED', '图片重定向已拒绝');
    }
    const limit = 20 * 1024 * 1024;
    if (response.contentLength > limit) {
      throw const RpcException('IMAGE_TOO_LARGE', '图片超过 20 MiB');
    }
    final bytes = BytesBuilder(copy: false);
    final responseLimit = response.statusCode >= 400 ? 64 * 1024 : limit;
    await for (final chunk in response) {
      if (bytes.length + chunk.length > responseLimit) {
        throw const RpcException('IMAGE_TOO_LARGE', '图片响应过大');
      }
      bytes.add(chunk);
    }
    final result = bytes.takeBytes();
    if (response.statusCode >= 400) {
      if (token != null) {
        try {
          throw RpcException.fromJson(
            asJson(asJson(jsonDecode(utf8.decode(result)))['error']),
          );
        } on FormatException {
          throw const RpcException('IMAGE_UNAVAILABLE', '图片读取失败');
        }
      }
      throw const RpcException('IMAGE_UNAVAILABLE', '图片读取失败');
    }
    if (response.statusCode != 200 ||
        !(response.headers.contentType?.mimeType.startsWith('image/') ??
            false)) {
      throw const RpcException('INVALID_IMAGE', '响应不是图片');
    }
    return result;
  }

  try {
    return await read().timeout(const Duration(seconds: 30));
  } finally {
    client.close(force: true);
  }
}

abstract class BridgeTransport {
  Stream<Json> get messages;
  Stream<String> get statuses;
  Future<void> connect({required int afterSeq, required String? epoch});
  Future<dynamic> rpc(String method, Json params, {String? requestId});
  void updateCursor(int seq, String? epoch);
  void reconnect();
  Future<void> close();
}

class SocketBridge implements BridgeTransport {
  final Host host;
  final String token;
  final _messages = StreamController<Json>.broadcast();
  final _statuses = StreamController<String>.broadcast();
  final Map<String, Completer<dynamic>> _pending = {};
  WebSocket? _socket;
  HttpClient? _client;
  Timer? _retry;
  bool _closed = false;
  bool _connecting = false;
  bool _ready = false;
  int _attempt = 0;
  int _cursor = 0;
  String? _epoch;
  SocketBridge(this.host, this.token);
  @override
  Stream<Json> get messages => _messages.stream;
  @override
  Stream<String> get statuses => _statuses.stream;

  @override
  Future<void> connect({required int afterSeq, required String? epoch}) async {
    if (_closed || _connecting) return;
    _cursor = afterSeq;
    _epoch = epoch;
    _connecting = true;
    _statuses.add('connecting');
    try {
      final origin = Uri.parse(host.url);
      _client = secureClient(origin, host.fingerprint);
      final socket = await WebSocket.connect(
        origin.replace(scheme: 'wss', path: '/v1/ws').toString(),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
        customClient: _client,
      ).timeout(const Duration(seconds: 15));
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 20);
      socket.listen(
        (raw) {
          try {
            final message = asJson(jsonDecode(raw as String));
            if (message['type'] == 'response') {
              final waiter = _pending.remove(message['requestId']);
              if (message['error'] != null) {
                waiter?.completeError(
                  RpcException.fromJson(asJson(message['error'])),
                );
              } else {
                waiter?.complete(message['result']);
              }
            } else {
              if (message['type'] == 'synced') {
                _ready = true;
                _attempt = 0;
                _statuses.add('online');
              }
              _messages.add(message);
            }
          } catch (error) {
            _statuses.add('Protocol error: $error');
          }
        },
        onDone: _disconnected,
        onError: (_) => _disconnected(),
        cancelOnError: true,
      );
      socket.add(
        jsonEncode({
          'type': 'hello',
          'protocolVersion': 1,
          'afterSeq': _cursor,
          'epoch': _epoch,
        }),
      );
    } catch (error) {
      if (!_closed) _statuses.add('offline: $error');
      _scheduleRetry();
    } finally {
      _connecting = false;
    }
  }

  void _disconnected() {
    _ready = false;
    final closeCode = _socket?.closeCode;
    _socket = null;
    for (final waiter in _pending.values) {
      waiter.completeError(
        const RpcException(
          'OUTCOME_UNKNOWN',
          'Connection lost. A write may have executed; inspect host state before trying again.',
        ),
      );
    }
    _pending.clear();
    if (_closed) return;
    if (closeCode == 4001 || closeCode == 4002) {
      _statuses.add(
        closeCode == 4001
            ? 'Device revoked; pair again'
            : 'Protocol incompatible',
      );
      return;
    }
    _statuses.add('offline');
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed || _retry?.isActive == true) return;
    final seconds = min(30, 1 << min(_attempt++, 5));
    _retry = Timer(
      Duration(milliseconds: seconds * 1000 + Random().nextInt(400)),
      () => connect(afterSeq: _cursor, epoch: _epoch),
    );
  }

  @override
  Future<dynamic> rpc(String method, Json params, {String? requestId}) async {
    if (!_ready || _socket == null) {
      throw const RpcException(
        'OFFLINE',
        'Reconnect before sending. No command has been queued.',
      );
    }
    final id = requestId ?? const Uuid().v4();
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _socket!.add(
      jsonEncode({
        'type': 'request',
        'requestId': id,
        'method': method,
        'params': params,
      }),
    );
    try {
      return await completer.future.timeout(const Duration(seconds: 135));
    } on TimeoutException {
      throw const RpcException(
        'OUTCOME_UNKNOWN',
        'Response timed out. Inspect task history before issuing the operation again.',
      );
    } finally {
      _pending.remove(id);
    }
  }

  @override
  void updateCursor(int seq, String? epoch) {
    _cursor = seq;
    _epoch = epoch;
  }

  @override
  void reconnect() {
    if (!_ready && !_connecting) {
      _retry?.cancel();
      unawaited(connect(afterSeq: _cursor, epoch: _epoch));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _socket?.close();
    _disconnected();
    _client?.close(force: true);
    await _messages.close();
    await _statuses.close();
  }
}
