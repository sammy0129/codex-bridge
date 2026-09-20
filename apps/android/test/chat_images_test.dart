import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:codex_bridge/data/chat_images.dart';
import 'package:codex_bridge/data/image_drafts.dart';
import 'package:codex_bridge/data/models.dart';
import 'package:codex_bridge/ui/chat.dart';
import 'package:codex_bridge/ui/chat_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'support.dart';

final photo = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1cAAAAASUVORK5CYII=',
);

class FakePicker extends ImagePicker {
  Future<XFile?> Function()? selection;
  ImageSource? source;
  LostDataResponse recovered = LostDataResponse.empty();
  int recoveryCalls = 0;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    this.source = source;
    return selection == null
        ? XFile.fromData(photo, name: 'photo.png')
        : selection!();
  }

  @override
  Future<LostDataResponse> retrieveLostData() async {
    recoveryCalls++;
    return recovered;
  }
}

Future<void> settleDraft() async {
  for (var attempt = 0; attempt < 8; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      for (final name in ['Roboto', 'Ahem']) {
        final loader = FontLoader(name)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
    final material = File(
      'D:/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (await material.exists()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(await material.readAsBytes())),
        );
      await loader.load();
    }
  });

  test(
    'camera and gallery validate, preview, upload, and retain failures',
    () async {
      final picker = FakePicker();
      final gate = Completer<Json>();
      final draft = ImageDraftController(
        MemoryStore(),
        picker: picker,
        recoverLostData: false,
        upload: (_) => gate.future,
      );
      addTearDown(draft.dispose);
      draft.bind('host', 'project', 'task');
      final selecting = draft.pick(ImageSource.camera);
      await settleDraft();
      expect(picker.source, ImageSource.camera);
      expect(draft.images.single.bytes, photo);
      expect(draft.images.single.state, ImageUploadState.uploading);
      expect(draft.canSend, isFalse);
      gate.complete({'type': 'localImage', 'path': '/project/photo.png'});
      await selecting;
      expect(draft.canSend, isTrue);
      expect(draft.input.single['type'], 'localImage');
      await draft.pick(ImageSource.gallery);
      expect(picker.source, ImageSource.gallery);
      expect(draft.images.length, 2);
      draft.remove(draft.images.first);
      expect(draft.images.length, 1);
    },
  );

  test(
    'cancel, denied permissions, invalid formats and oversize never upload',
    () async {
      final picker = FakePicker();
      var uploads = 0;
      final draft = ImageDraftController(
        MemoryStore(),
        picker: picker,
        recoverLostData: false,
        upload: (_) async {
          uploads++;
          return {};
        },
      );
      addTearDown(draft.dispose);
      draft.bind('host', 'project', 'task');
      picker.selection = () async => null;
      await draft.pick(ImageSource.camera);
      expect(draft.images, isEmpty);
      expect(draft.error, isNull);
      picker.selection = () async =>
          throw PlatformException(code: 'camera_access_denied');
      await draft.pick(ImageSource.camera);
      expect(draft.error, contains('权限'));
      picker.selection = () async =>
          throw PlatformException(code: 'no_available_camera');
      await draft.pick(ImageSource.camera);
      expect(draft.error, contains('相机'));
      picker.selection = () async =>
          XFile.fromData(Uint8List.fromList([1, 2, 3]));
      await draft.pick(ImageSource.gallery);
      expect(draft.error, contains('格式'));
      picker.selection = () async =>
          XFile.fromData(Uint8List(maxImageBytes + 1));
      await draft.pick(ImageSource.gallery);
      expect(draft.error, contains('20 MiB'));
      expect(uploads, 0);
    },
  );

  test(
    'failed uploads retain photos; unknown outcomes never resubmit',
    () async {
      var attempts = 0;
      final draft = ImageDraftController(
        MemoryStore(),
        picker: FakePicker(),
        recoverLostData: false,
        upload: (_) async {
          attempts++;
          throw RpcException(
            attempts == 1 ? 'INVALID_IMAGE' : 'OUTCOME_UNKNOWN',
            'failed',
          );
        },
      );
      addTearDown(draft.dispose);
      draft.bind('host', 'project', 'task');
      await draft.pick(ImageSource.gallery);
      expect(draft.images.single.state, ImageUploadState.failed);
      expect(draft.canSend, isFalse);
      await draft.uploadImage(draft.images.single);
      expect(draft.images.single.state, ImageUploadState.unknown);
      await draft.uploadImage(draft.images.single);
      expect(attempts, 2);
      expect(draft.images.single.bytes, photo);
    },
  );

  for (final target in [
    ['other-host', 'project', 'task'],
    ['host', 'other-project', 'task'],
    ['host', 'project', 'other-task'],
  ]) {
    test('late picks and uploads cannot enter $target', () async {
      final picker = FakePicker();
      final selection = Completer<XFile?>();
      picker.selection = () => selection.future;
      var uploads = 0;
      final upload = Completer<Json>();
      final draft = ImageDraftController(
        MemoryStore(),
        picker: picker,
        recoverLostData: false,
        upload: (_) {
          uploads++;
          return upload.future;
        },
      );
      addTearDown(draft.dispose);
      draft.bind('host', 'project', 'task');
      final picking = draft.pick(ImageSource.camera);
      await settleDraft();
      draft.bind(target[0], target[1], target[2]);
      selection.complete(XFile.fromData(photo));
      await picking;
      expect(draft.images, isEmpty);
      expect(uploads, 0);
      draft.bind('host', 'project', 'task');
      picker.selection = null;
      final pending = draft.pick(ImageSource.gallery);
      await settleDraft();
      expect(draft.images.single.state, ImageUploadState.uploading);
      draft.bind(target[0], target[1], target[2]);
      upload.complete({'type': 'localImage', 'path': '/old/photo.png'});
      await pending;
      expect(draft.images, isEmpty);
      expect(draft.threadId, target[2]);
    });
  }

  test('removed uploading photos do not reappear', () async {
    final gate = Completer<Json>();
    final draft = ImageDraftController(
      MemoryStore(),
      picker: FakePicker(),
      recoverLostData: false,
      upload: (_) => gate.future,
    );
    addTearDown(draft.dispose);
    draft.bind('host', 'project', 'task');
    final pending = draft.pick(ImageSource.camera);
    await settleDraft();
    draft.remove(draft.images.single);
    gate.complete({'type': 'localImage', 'path': '/old/photo.png'});
    await pending;
    expect(draft.images, isEmpty);
  });

  test(
    'Android recovery restores only original context, without upload',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bridge-recovery-',
      );
      final file = File('${directory.path}/photo.png');
      await file.writeAsBytes(photo);
      addTearDown(() => directory.delete(recursive: true));
      final store = MemoryStore();
      await store.write('pending-image-selection', {
        'hostId': 'host',
        'projectId': 'project',
        'threadId': 'task',
        'draftId': 'original-draft',
      });
      final picker = FakePicker()
        ..recovered = LostDataResponse(files: [XFile(file.path)]);
      var uploads = 0;
      final draft = ImageDraftController(
        store,
        picker: picker,
        recoverLostData: true,
        upload: (_) async {
          uploads++;
          return {'type': 'localImage', 'path': '/photo.png'};
        },
      );
      addTearDown(draft.dispose);
      draft.bind('host', 'project', 'other-task');
      await settleDraft();
      expect(draft.images, isEmpty);
      expect(await store.read('recovered-image-selection'), isNotEmpty);
      draft.bind('host', 'project', 'task');
      for (var attempt = 0; attempt < 50 && draft.images.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(draft.images.single.state, ImageUploadState.ready);
      expect(draft.id, 'original-draft');
      expect(draft.canSend, isFalse);
      expect(uploads, 0);
      expect(picker.recoveryCalls, 1);
      await draft.uploadImage(draft.images.single);
      expect(uploads, 1);
      expect(draft.canSend, isTrue);
    },
  );

  test('image cache deduplicates requests, evicts, isolates and clears pending results', () async {
    final cache = ChatImageCache(maxBytes: 4, maxEntries: 2);
    var calls = 0;
    Future<Uint8List> fetch() async {
      calls++;
      return Uint8List(3);
    }

    await Future.wait([
      cache.load('host-a', fetch),
      cache.load('host-a', fetch),
    ]);
    expect(calls, 1);
    await cache.load('host-b', fetch);
    await cache.load('host-a', fetch);
    expect(calls, 3);
    final pending = Completer<Uint8List>();
    final result = cache.load('stale', () => pending.future);
    cache.clear();
    pending.complete(Uint8List(2));
    await result;
    await cache.load('stale', fetch);
    expect(calls, 4);
  });

  test(
    'loader separates pinned Bridge downloads from credential-free HTTPS',
    () async {
      final requests = <Json>[];
      final loader = ChatImageLoader(
        download: (uri, {fingerprint, token}) async {
          requests.add({
            'uri': uri,
            'fingerprint': fingerprint,
            'token': token,
          });
          return photo;
        },
      );
      final host = Host(
        id: 'a',
        name: 'A',
        url: 'https://bridge.test:8787',
        deviceId: 'device',
        fingerprint: 'pin',
      );
      Future<Uint8List> load(
        Json content, {
        Host? selected,
        bool supports = true,
      }) => loader.load(
        host: selected ?? host,
        projectId: 'project',
        threadId: 'task',
        itemId: 'message',
        contentIndex: 2,
        content: content,
        supportsRead: supports,
        token: () async => 'secret',
      );
      final local = {'type': 'localImage', 'path': 'C:/desktop/photo.png'};
      await load(local);
      expect(requests.single['token'], 'secret');
      expect(requests.single['fingerprint'], 'pin');
      final uri = requests.single['uri'] as Uri;
      expect(uri.path, '/v1/thread-images');
      expect(uri.queryParameters, {
        'projectId': 'project',
        'threadId': 'task',
        'itemId': 'message',
        'contentIndex': '2',
      });
      expect(uri.toString(), isNot(contains('desktop')));
      await load({'type': 'image', 'url': 'https://external.test/photo.png'});
      expect(requests.last['token'], isNull);
      expect(requests.last['fingerprint'], isNull);
      await load(
        local,
        selected: const Host(
          id: 'b',
          name: 'B',
          url: 'https://other.test',
          deviceId: 'other',
        ),
      );
      expect(requests.length, 3);
      await expectLater(
        load({'type': 'localImage', 'path': '/old.png'}, supports: false),
        throwsA(isA<RpcException>()),
      );
      await expectLater(
        load({'type': 'image', 'url': 'http://external.test/photo.png'}),
        throwsA(isA<RpcException>()),
      );
      final data = await load({
        'type': 'image',
        'url': 'data:image/png;base64,${base64Encode(photo)}',
      });
      expect(data, photo);
      expect(requests.length, 3);
      await expectLater(
        load({'type': 'image', 'url': 'data:image/png;base64,invalid'}),
        throwsA(isA<RpcException>()),
      );
    },
  );

  testWidgets('camera and gallery are visible in attachment menu', (
    tester,
  ) async {
    final workbench = fixtureWorkbench();
    addTearDown(workbench.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPane(workbench: workbench)),
      ),
    );
    await tester.tap(find.byTooltip('添加图片、文件或 Skill'));
    await tester.pumpAndSettle();
    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('相册图片'), findsOneWidget);
    expect(find.text('项目文件'), findsOneWidget);
  });

  testWidgets(
    'pure-image sending retains failed draft and clears successful draft',
    (tester) async {
      final workbench = fixtureWorkbench();
      addTearDown(workbench.dispose);
      final transport = workbench.transport! as FakeTransport;
      final sent = <Json>[];
      var fail = true;
      transport.handler = (method, params) async {
        if (method == 'turn/start') {
          sent.add(params);
          if (fail) throw const RpcException('TEST_FAILURE', 'failed');
        }
        return {};
      };
      final draft = workbench.imageDrafts;
      draft.bind(sampleHost.id, 'project', 'task');
      draft.images.add(
        DraftImage(photo)
          ..state = ImageUploadState.uploaded
          ..input = {'type': 'localImage', 'path': '/photo.png'},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPane(workbench: workbench)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('发送任务'));
      await tester.pumpAndSettle();
      expect(sent.single['input'], [
        {'type': 'localImage', 'path': '/photo.png'},
      ]);
      expect(draft.images, hasLength(1));
      fail = false;
      await tester.tap(find.byTooltip('发送任务'));
      await tester.pumpAndSettle();
      expect(draft.images, isEmpty);
      expect(sent, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('incomplete uploads disable sending and support removal', (
    tester,
  ) async {
    final workbench = fixtureWorkbench();
    addTearDown(workbench.dispose);
    final draft = workbench.imageDrafts;
    draft.bind(sampleHost.id, 'project', 'task');
    draft.images.add(DraftImage(photo)..state = ImageUploadState.uploading);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatPane(workbench: workbench)),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '发送任务',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('移除图片'));
    await tester.pumpAndSettle();
    expect(draft.images, isEmpty);
  });

  testWidgets(
    'mixed historical images render in order and open a zoomable preview',
    (tester) async {
      final workbench = fixtureWorkbench();
      addTearDown(workbench.dispose);
      workbench.timelines['task'] = [
        {
          'id': 'historical',
          'type': 'userMessage',
          'content': [
            {'type': 'text', 'text': '第一张照片'},
            {
              'type': 'image',
              'url': 'data:image/png;base64,${base64Encode(photo)}',
            },
            {'type': 'text', 'text': '第二张照片'},
            {
              'type': 'image',
              'url': 'data:image/png;base64,${base64Encode(photo)}',
            },
          ],
        },
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPane(workbench: workbench)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MessageImage), findsNWidgets(2));
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.text('[图片]'), findsNothing);
      expect(
        tester.getTopLeft(find.text('第一张照片')).dy,
        lessThan(tester.getTopLeft(find.byType(MessageImage).first).dy),
      );
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(find.text('图片预览'), findsOneWidget);
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .maxScale,
        5,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(MessageImage), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing, corrupt, and old-Bridge images show useful errors', (
    tester,
  ) async {
    final workbench = fixtureWorkbench();
    addTearDown(workbench.dispose);
    final inputs = [
      {'type': 'localImage', 'path': '/desktop/photo.png'},
      {
        'type': 'image',
        'url': 'data:image/png;base64,${base64Encode(photo.sublist(0, 8))}',
      },
      {'type': 'text', 'text': '[图片]'},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TimelineItem(
              workbench: workbench,
              threadId: 'task',
              item: {'type': 'userMessage', 'id': 'bad', 'content': inputs},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('请升级主机 Bridge 后查看图片'), findsOneWidget);
    expect(find.text('图片文件已损坏'), findsOneWidget);
    expect(find.text('历史记录缺少原图引用'), findsOneWidget);
    expect(find.text('[图片]'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('image layout is bounded at 320px in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 640, 420),
        Paint()..color = const Color(0xffb6d9ee),
      );
      canvas.drawCircle(
        const Offset(495, 104),
        52,
        Paint()..color = const Color(0xffedb960),
      );
      canvas.drawPath(
        Path()
          ..moveTo(0, 420)
          ..lineTo(245, 110)
          ..lineTo(460, 420)
          ..close(),
        Paint()..color = const Color(0xff497a78),
      );
      canvas.drawPath(
        Path()
          ..moveTo(200, 420)
          ..lineTo(490, 190)
          ..lineTo(640, 360)
          ..lineTo(640, 420)
          ..close(),
        Paint()..color = const Color(0xff284b50),
      );
      final picture = recorder.endRecording();
      final bytes = (await tester.runAsync(() async {
        final rendered = await picture.toImage(640, 420);
        final data = (await rendered.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        rendered.dispose();
        picture.dispose();
        return data;
      }))!;
      final workbench = fixtureWorkbench();
      addTearDown(workbench.dispose);
      workbench.timelines['task'] = [
        {
          'id': 'photo',
          'type': 'userMessage',
          'content': [
            {'type': 'text', 'text': '请查看这张照片'},
            {
              'type': 'image',
              'url': 'data:image/png;base64,${base64Encode(bytes)}',
            },
          ],
        },
      ];
      workbench.imageDrafts.bind(sampleHost.id, 'project', 'task');
      workbench.imageDrafts.images.add(
        DraftImage(bytes)
          ..state = ImageUploadState.uploaded
          ..input = {'type': 'localImage', 'path': '/photo.png'},
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(body: ChatPane(workbench: workbench)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsNWidgets(2));
      await tester.runAsync(() async {
        for (final widget in tester.widgetList<Image>(find.byType(Image))) {
          await precacheImage(widget.image, boundary.currentContext!);
        }
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final preview =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final png = await preview.toByteData(format: ui.ImageByteFormat.png);
        preview.dispose();
        final file = File(
          '../../.local/screenshots/chat-images-${brightness.name}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(png!.buffer.asUint8List());
      });
    });
  }
}
