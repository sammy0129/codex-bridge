import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/chat_images.dart';
import '../data/image_drafts.dart';
import '../data/models.dart';
import '../data/workbench.dart';

Future<void> showImagePreview(
  BuildContext context,
  Uint8List bytes,
  Workbench workbench,
) {
  final scope = [workbench.host?.id, workbench.projectId, workbench.threadId];
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('图片预览')),
        body: AnimatedBuilder(
          animation: workbench,
          builder: (context, _) {
            final current = [
              workbench.host?.id,
              workbench.projectId,
              workbench.threadId,
            ];
            if (jsonEncode(scope) != jsonEncode(current)) {
              return const Center(child: Text('任务已切换，请返回当前聊天'));
            }
            return SizedBox.expand(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    cacheWidth: 2048,
                    errorBuilder: (_, _, _) =>
                        const ImageUnavailable(message: '图片文件已损坏'),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class ImageUnavailable extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ImageUnavailable({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_outlined),
        const SizedBox(height: 6),
        const Text('图片不可用'),
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

class MessageImage extends StatefulWidget {
  final Workbench workbench;
  final String threadId;
  final String itemId;
  final int contentIndex;
  final Json content;
  const MessageImage({
    super.key,
    required this.workbench,
    required this.threadId,
    required this.itemId,
    required this.contentIndex,
    required this.content,
  });

  @override
  State<MessageImage> createState() => _MessageImageState();
}

class _MessageImageState extends State<MessageImage> {
  late Future<Uint8List> image;
  late String identity;

  String get currentIdentity => jsonEncode([
    widget.workbench.host?.id,
    widget.workbench.projectId,
    widget.threadId,
    widget.itemId,
    widget.contentIndex,
    widget.content,
  ]);

  void load() {
    identity = currentIdentity;
    image = widget.workbench.loadMessageImage(
      widget.threadId,
      widget.itemId,
      widget.contentIndex,
      widget.content,
    );
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant MessageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identity != currentIdentity ||
        oldWidget.workbench != widget.workbench) {
      load();
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 280,
        height: 200,
        child: FutureBuilder<Uint8List>(
          future: image,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError || !snapshot.hasData) {
              final error = snapshot.error;
              final retry =
                  error is! RpcException ||
                  !{
                    'IMAGE_READ_UNSUPPORTED',
                    'INVALID_IMAGE',
                    'IMAGE_TOO_LARGE',
                    'CONTEXT_CHANGED',
                    'UNAUTHORIZED',
                  }.contains(error.code);
              return ImageUnavailable(
                message: imageFailureMessage(error),
                onRetry: retry ? () => setState(load) : null,
              );
            }
            final bytes = snapshot.data!;
            return Semantics(
              label: '查看图片',
              button: true,
              child: InkWell(
                onTap: () => showImagePreview(context, bytes, widget.workbench),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  cacheWidth: 640,
                  errorBuilder: (_, _, _) =>
                      const ImageUnavailable(message: '图片文件已损坏'),
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
}

class DraftImageTray extends StatelessWidget {
  final ImageDraftController draft;
  final Workbench workbench;
  final bool sending;
  const DraftImageTray({
    super.key,
    required this.draft,
    required this.workbench,
    required this.sending,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (draft.error != null)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            draft.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (draft.images.isNotEmpty)
        SizedBox(
          height: 176,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: draft.images.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final image = draft.images[index];
              final label = switch (image.state) {
                ImageUploadState.ready => '已恢复，点击上传',
                ImageUploadState.uploading => '正在上传…',
                ImageUploadState.uploaded => '已添加',
                ImageUploadState.failed => image.error ?? '上传失败',
                ImageUploadState.unknown => image.error ?? '上传结果未知',
              };
              return SizedBox(
                key: ValueKey(image.id),
                width: 168,
                child: Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            InkWell(
                              onTap: () => showImagePreview(
                                context,
                                image.bytes,
                                workbench,
                              ),
                              child: Image.memory(
                                image.bytes,
                                fit: BoxFit.cover,
                                cacheWidth: 320,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Icon(Icons.broken_image_outlined),
                                ),
                              ),
                            ),
                            if (image.state == ImageUploadState.uploading)
                              const Center(child: CircularProgressIndicator()),
                            Positioned(
                              top: 0,
                              right: 0,
                              child: IconButton.filledTonal(
                                tooltip: '移除图片',
                                onPressed: sending
                                    ? null
                                    : () => draft.remove(image),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 56,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 8, right: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Tooltip(
                                  message: label,
                                  child: Text(
                                    label,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                              ),
                              if ([
                                ImageUploadState.ready,
                                ImageUploadState.failed,
                              ].contains(image.state))
                                IconButton(
                                  tooltip: image.state == ImageUploadState.ready
                                      ? '上传图片'
                                      : '重试上传',
                                  onPressed: sending || !workbench.online
                                      ? null
                                      : () => draft.uploadImage(image),
                                  icon: Icon(
                                    image.state == ImageUploadState.ready
                                        ? Icons.upload
                                        : Icons.refresh,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
    ],
  );
}
