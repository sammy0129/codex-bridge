typedef Json = Map<String, dynamic>;

Json asJson(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Json> asList(dynamic value) =>
    value is List ? value.map(asJson).toList() : [];

class Host {
  final String id;
  final String name;
  final String url;
  final String? fingerprint;
  final String deviceId;
  final Json info;

  const Host({
    required this.id,
    required this.name,
    required this.url,
    required this.deviceId,
    this.fingerprint,
    this.info = const {},
  });

  factory Host.fromJson(Json value) => Host(
    id: value['id'] as String,
    name: value['name'] as String,
    url: value['url'] as String,
    deviceId: value['deviceId'] as String,
    fingerprint: value['fingerprint'] as String?,
    info: asJson(value['info']),
  );
  Json toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'deviceId': deviceId,
    'fingerprint': fingerprint,
    'info': info,
  };
}

class RpcException implements Exception {
  final String code;
  final String message;
  final dynamic details;
  const RpcException(this.code, this.message, [this.details]);
  factory RpcException.fromJson(Json error) => RpcException(
    error['code']?.toString() ?? 'ERROR',
    error['message']?.toString() ?? 'Request failed',
    error['details'],
  );
  @override
  String toString() => '$code: $message';
}

class Pairing {
  final Uri origin;
  final String code;
  final String? fingerprint;
  const Pairing(this.origin, this.code, this.fingerprint);

  factory Pairing.fromJson(Json data) {
    final uri = Uri.tryParse(data['url']?.toString() ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const RpcException(
        'INVALID_URL',
        'Use an HTTPS host address without a path or credentials.',
      );
    }
    final fingerprint = data['fingerprint']
        ?.toString()
        .replaceAll(':', '')
        .toLowerCase();
    if (fingerprint != null &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw const RpcException(
        'INVALID_PIN',
        'Certificate fingerprint must contain 64 hexadecimal characters.',
      );
    }
    final code = data['code']?.toString() ?? '';
    if (code.length < 20 || code.length > 128) {
      throw const RpcException(
        'INVALID_CODE',
        'Paste or scan the complete pairing code.',
      );
    }
    return Pairing(uri, code, fingerprint);
  }
}
