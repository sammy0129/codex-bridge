import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'chat_images.dart';
import 'models.dart';
import 'storage.dart';

enum ImageUploadState { ready, uploading, uploaded, failed, unknown }

class DraftImage {
  final String id = const Uuid().v4();
  final Uint8List bytes;
  ImageUploadState state = ImageUploadState.ready;
  Json? input;
  String? error;
  DraftImage(this.bytes);
}

class ImageDraftController extends ChangeNotifier {
  final LocalStore storage;
  final Future<Json> Function(List<int>) upload;
  final ImagePicker picker;
  final bool recoverLostData;
  final List<DraftImage> images = [];
  String id = const Uuid().v4();
  String? hostId;
  String? projectId;
  String? threadId;
  String? error;
  bool picking = false;
  bool _disposed = false;
  Future<void>? _recovery;
  int _binding = 0;
  ImageDraftController(
    this.storage, {
    required this.upload,
    ImagePicker? picker,
    bool? recoverLostData,
  }) : picker = picker ?? ImagePicker(),
       recoverLostData =
           recoverLostData ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  Json get context => {
    'hostId': hostId,
    'projectId': projectId,
    'threadId': threadId,
  };
  bool get canSend =>
      !picking &&
      images.every((image) => image.state == ImageUploadState.uploaded);
  List<Json> get input => images.map((image) => image.input!).toList();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void bind(String? host, String? project, String? thread) {
    if (hostId == host && projectId == project && threadId == thread) return;
    hostId = host;
    projectId = project;
    threadId = thread;
    id = const Uuid().v4();
    images.clear();
    error = null;
    final binding = ++_binding;
    unawaited(_restore(binding));
  }

  void adoptThread(String task) {
    threadId ??= task;
  }

  bool _current(String draft) => !_disposed && draft == id;

  Future<void> _recover() async {
    if (!recoverLostData) return;
    final pending = await storage.read('pending-image-selection');
    if (pending.isEmpty) return;
    final response = await picker.retrieveLostData();
    if (pending.isNotEmpty && !response.isEmpty) {
      await storage.write('recovered-image-selection', {
        ...pending,
        'paths': (response.files ?? [if (response.file != null) response.file!])
            .map((file) => file.path)
            .toList(),
        if (response.exception != null) 'error': '未能恢复照片，请重新拍照或选择图片',
      });
    }
    await storage.write('pending-image-selection', {});
  }

  Future<void> _restore(int binding) async {
    try {
      await (_recovery ??= _recover());
      if (_disposed || binding != _binding) return;
      final saved = await storage.read('recovered-image-selection');
      if (_disposed || binding != _binding || picking || images.isNotEmpty) {
        return;
      }
      if (saved['hostId'] != hostId ||
          saved['projectId'] != projectId ||
          saved['threadId'] != threadId ||
          saved.isEmpty) {
        return;
      }
      id = saved['draftId'] as String? ?? id;
      final draft = id;
      for (final path in (saved['paths'] as List? ?? []).whereType<String>()) {
        final bytes = await _read(XFile(path));
        if (!_current(draft)) return;
        images.add(DraftImage(bytes));
      }
      error = saved['error'] as String?;
      await storage.write('recovered-image-selection', {});
      if (_current(draft)) _notify();
    } catch (_) {
      if (!_disposed && binding == _binding) {
        error = '照片恢复失败，请重新拍照或选择图片';
        _notify();
      }
    }
  }

  Future<Uint8List> _read(XFile file) async {
    if (await file.length() > maxImageBytes) {
      throw const RpcException('IMAGE_TOO_LARGE', '单张图片不能超过 20 MiB');
    }
    final bytes = await file.readAsBytes();
    validateImageBytes(bytes, upload: true);
    return bytes;
  }

  Future<void> pick(ImageSource source) async {
    if (picking || hostId == null || projectId == null) return;
    final draft = id;
    picking = true;
    error = null;
    _notify();
    try {
      await (_recovery ??= _recover());
      if (!_current(draft)) return;
      await storage.write('pending-image-selection', {
        ...context,
        'draftId': draft,
      });
      if (!_current(draft)) return;
      final file = await picker.pickImage(
        source: source,
        requestFullMetadata: false,
      );
      if (file == null || !_current(draft)) return;
      final bytes = await _read(file);
      if (!_current(draft)) return;
      final image = DraftImage(bytes);
      images.add(image);
      _notify();
      await uploadImage(image);
    } on PlatformException catch (failure) {
      if (_current(draft)) {
        error = switch (failure.code) {
          'camera_access_denied' ||
          'photo_access_denied' ||
          'camera_access_restricted' ||
          'photo_access_restricted' => '相机或相册权限未允许，请在系统设置中开启',
          'camera_unavailable' ||
          'no_available_camera' => '当前设备没有可用相机，请从相册选择图片',
          _ => '无法打开相机或相册，请稍后重试',
        };
      }
    } catch (failure) {
      if (_current(draft)) error = imageFailureMessage(failure);
    } finally {
      try {
        await storage.write('pending-image-selection', {});
      } catch (_) {
        if (_current(draft)) error ??= '无法保存图片选择状态';
      }
      picking = false;
      _notify();
    }
  }

  Future<void> uploadImage(DraftImage image) async {
    if (!images.contains(image) ||
        ![
          ImageUploadState.ready,
          ImageUploadState.failed,
        ].contains(image.state)) {
      return;
    }
    final draft = id;
    image.state = ImageUploadState.uploading;
    image.error = null;
    _notify();
    try {
      final result = await upload(image.bytes);
      if (!_current(draft) || !images.contains(image)) return;
      image.input = result;
      image.state = ImageUploadState.uploaded;
    } catch (failure) {
      if (!_current(draft) || !images.contains(image)) return;
      final unknown =
          failure is TimeoutException ||
          (failure is RpcException && failure.code == 'OUTCOME_UNKNOWN');
      image.state = unknown
          ? ImageUploadState.unknown
          : ImageUploadState.failed;
      image.error = imageFailureMessage(
        unknown ? const RpcException('OUTCOME_UNKNOWN', '') : failure,
      );
    }
    if (_current(draft)) _notify();
  }

  void remove(DraftImage image) {
    images.remove(image);
    _notify();
  }

  void complete(String draft) {
    if (!_current(draft)) return;
    images.clear();
    error = null;
    id = const Uuid().v4();
    _binding++;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
