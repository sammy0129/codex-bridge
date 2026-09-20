import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/workbench.dart';
import '../data/image_drafts.dart';
import 'chat_images.dart';
import 'common.dart';
import 'workspace.dart';
import 'command_composer.dart';
import 'approvals.dart';
export 'approvals.dart' show showApprovals;

Future<void> openLink(String? value) async {
  final uri = Uri.tryParse(value ?? '');
  if (uri != null && ['https', 'http'].contains(uri.scheme)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class ChatPane extends StatefulWidget {
  final Workbench workbench;
  const ChatPane({super.key, required this.workbench});
  @override
  State<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends State<ChatPane> {
  final composerKey = GlobalKey<CommandComposerState>();
  final scroll = ScrollController();
  ImageDraftController get imageDraft => widget.workbench.imageDrafts;
  bool sending = false;
  String? boundThread;
  String? boundDraftId;
  @override
  void initState() {
    super.initState();
    boundThread = widget.workbench.threadId;
    imageDraft.bind(
      widget.workbench.host?.id,
      widget.workbench.projectId,
      boundThread,
    );
    imageDraft.addListener(draftChanged);
    boundDraftId = imageDraft.id;
  }

  void draftChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ChatPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workbench != widget.workbench) {
      oldWidget.workbench.imageDrafts.removeListener(draftChanged);
      imageDraft.addListener(draftChanged);
    }
    if (boundThread != widget.workbench.threadId) {
      final sameDraft = boundDraftId == imageDraft.id;
      boundThread = widget.workbench.threadId;
      if (!sending || !sameDraft) {
        composerKey.currentState?.clear();
      }
    }
    imageDraft.bind(
      widget.workbench.host?.id,
      widget.workbench.projectId,
      boundThread,
    );
    boundDraftId = imageDraft.id;
  }

  @override
  void dispose() {
    imageDraft.removeListener(draftChanged);
    scroll.dispose();
    super.dispose();
  }

  Future<void> send() async {
    if (sending || !imageDraft.canSend || !widget.workbench.online) return;
    final draft = composerKey.currentState?.input ?? const <Json>[];
    final attachments = imageDraft.input;
    final draftId = imageDraft.id;
    if (draft.isEmpty && attachments.isEmpty) return;
    setState(() => sending = true);
    try {
      await widget.workbench.sendInput([...draft, ...attachments]);
      if (mounted && imageDraft.id == draftId) {
        setState(() {
          composerKey.currentState?.clear();
          imageDraft.complete(draftId);
        });
      }
    } catch (error) {
      widget.workbench.showError(error);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> attachment(String kind) async {
    final workbench = widget.workbench;
    final host = workbench.host?.id;
    final project = workbench.projectId;
    await guard(workbench, () async {
      if (kind == 'image' || kind == 'camera') {
        await imageDraft.pick(
          kind == 'camera' ? ImageSource.camera : ImageSource.gallery,
        );
      } else if (kind == 'file') {
        final path = await Navigator.push<String>(
          context,
          MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('引用项目文件')),
              body: FileBrowser(workbench: workbench, pickFile: true),
            ),
          ),
        );
        if (path != null &&
            mounted &&
            workbench.host?.id == host &&
            workbench.projectId == project) {
          composerKey.currentState?.addReference({
            'type': 'mention',
            'name': path.split('/').last,
            'path': path,
          });
        }
      } else {
        await workbench.loadTools();
        if (!mounted || workbench.host?.id != host) return;
        final skill = await showModalBottomSheet<Json>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (context) => SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: ToolsPane(workbench: workbench),
          ),
        );
        if (skill != null &&
            mounted &&
            workbench.host?.id == host &&
            workbench.projectId == project) {
          composerKey.currentState?.addReference({
            'type': 'skill',
            'name': skill['name'],
            'path': skill['path'],
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final workbench = widget.workbench;
    final activeTurn = workbench.running == null
        ? null
        : workbench.running?['turn']?.toString() ?? 'starting';
    final entries = _timelineEntries(workbench.items);
    if (activeTurn != null &&
        !entries.any((entry) => entry.process?.turnId == activeTurn)) {
      entries.add(
        _TimelineEntry.process(
          _ProcessBlock('turn:$activeTurn', activeTurn, []),
        ),
      );
    }
    final nearBottom =
        !scroll.hasClients ||
        scroll.position.maxScrollExtent - scroll.offset < 150;
    if (nearBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    }
    return Column(
      children: [
        Expanded(
          child: entries.isEmpty
              ? EmptyState(
                  icon: Icons.terminal,
                  title: workbench.project == null ? '选择一个项目开始' : '今天想完成什么？',
                  subtitle: workbench.project == null
                      ? '添加远程主机上的项目目录，即可开始新的编码任务。'
                      : '描述目标，Codex 会在 ${workbench.project?['name']} 中执行。你可以随时查看改动、追加指令或停止任务。',
                )
              : SelectionArea(
                  child: ListView.builder(
                    key: ValueKey(workbench.threadId),
                    controller: scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 20,
                    ),
                    itemCount: entries.length,
                    findChildIndexCallback: (key) {
                      final index = entries.indexWhere(
                        (entry) => ValueKey(entry.key) == key,
                      );
                      return index < 0 ? null : index;
                    },
                    itemBuilder: (_, index) {
                      final entry = entries[index];
                      final process = entry.process;
                      final active =
                          process != null &&
                          activeTurn != null &&
                          process.turnId == activeTurn;
                      return Align(
                        key: ValueKey(entry.key),
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 820),
                          child: process != null
                              ? _ProcessGroup(
                                  key: ValueKey(process.key),
                                  process: process,
                                  active: active,
                                )
                              : TimelineItem(
                                  item: entry.item!,
                                  workbench: workbench,
                                  threadId: workbench.threadId,
                                ),
                        ),
                      );
                    },
                  ),
                ),
        ),
        if (workbench.currentApprovals.isNotEmpty)
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: ListTile(
              leading: const Icon(Icons.pending_actions),
              title: Text('${workbench.currentApprovals.length} 项请求等待处理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showApprovals(context, workbench),
            ),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OptionsBar(workbench: workbench),
                  DraftImageTray(
                    draft: imageDraft,
                    workbench: workbench,
                    sending: sending,
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                    child: CommandComposer(
                      key: composerKey,
                      workbench: workbench,
                      enabled: workbench.online && !sending,
                      sending: sending,
                      running: workbench.running != null,
                      canSend:
                          workbench.online &&
                          workbench.projectId != null &&
                          imageDraft.canSend,
                      attachmentsEnabled: !imageDraft.picking,
                      hint: workbench.running != null
                          ? '补充指令，调整当前任务…'
                          : '描述任务，或提出问题…',
                      onSend: send,
                      onAttachment: attachment,
                      onStop: workbench.online
                          ? () => guard(workbench, workbench.stop)
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class OptionsBar extends StatelessWidget {
  final Workbench workbench;
  const OptionsBar({super.key, required this.workbench});
  @override
  Widget build(BuildContext context) {
    final selectedModel = workbench.models
        .where((entry) => entry['model'] == workbench.model)
        .firstOrNull;
    final efforts = asList(selectedModel?['supportedReasoningEfforts']);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          PopupMenuButton<String>(
            enabled:
                workbench.online &&
                workbench.running == null &&
                workbench.models.isNotEmpty,
            tooltip: '选择模型',
            onSelected: (value) {
              workbench.model = value;
              workbench.effort =
                  workbench.models
                          .where((entry) => entry['model'] == value)
                          .firstOrNull?['defaultReasoningEffort']
                      as String?;
              workbench.clearError();
            },
            itemBuilder: (_) => workbench.models
                .map(
                  (entry) => PopupMenuItem(
                    value: entry['model'] as String,
                    child: Text(
                      entry['displayName']?.toString() ??
                          entry['model'].toString(),
                    ),
                  ),
                )
                .toList(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                children: [
                  Text(
                    selectedModel?['displayName']?.toString() ?? '主机默认模型',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Icon(Icons.expand_more, size: 15),
                ],
              ),
            ),
          ),
          PopupMenuButton<String>(
            enabled:
                workbench.online &&
                workbench.running == null &&
                efforts.isNotEmpty,
            tooltip: '推理强度',
            onSelected: (value) {
              workbench.effort = value;
              workbench.clearError();
            },
            itemBuilder: (_) => efforts
                .map(
                  (entry) => PopupMenuItem(
                    value: entry['reasoningEffort'] as String,
                    child: Text(entry['reasoningEffort'] as String),
                  ),
                )
                .toList(),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                workbench.effort ?? '默认强度',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
          PopupMenuButton<String>(
            enabled:
                workbench.online &&
                workbench.running == null &&
                workbench.modes.isNotEmpty,
            tooltip: '协作模式',
            onSelected: (value) {
              workbench.mode = value;
              workbench.clearError();
            },
            itemBuilder: (_) => workbench.modes
                .map(
                  (entry) => PopupMenuItem(
                    value: entry['mode'] as String,
                    child: Text(
                      entry['name']?.toString() ?? entry['mode'].toString(),
                    ),
                  ),
                )
                .toList(),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                workbench.mode == 'plan' ? '计划' : '执行',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
          PopupMenuButton<String>(
            enabled: workbench.running == null,
            tooltip: '任务权限',
            onSelected: (value) {
              workbench.permissionMode = value;
              workbench.clearError();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'danger-full-access', child: Text('完整访问')),
              PopupMenuItem(value: 'workspace-write', child: Text('工作区写入')),
              PopupMenuItem(value: 'read-only', child: Text('只读')),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Icon(
                    workbench.permissionMode == 'danger-full-access'
                        ? Icons.lock_open_outlined
                        : Icons.shield_outlined,
                    size: 12,
                  ),
                  const SizedBox(width: 4),
                  Text(switch (workbench.permissionMode) {
                    'danger-full-access' => '完整访问',
                    'workspace-write' => '工作区写入',
                    _ => '只读',
                  }, style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _isProcessItem(Json item) => const {
  'reasoning',
  'plan',
  'commandExecution',
  'fileChange',
  'turnDiff',
  'mcpToolCall',
}.contains(item['type']);

class _ProcessBlock {
  final String key;
  final String? turnId;
  final List<Json> items;
  _ProcessBlock(this.key, this.turnId, this.items);
}

class _TimelineEntry {
  final Json? item;
  final _ProcessBlock? process;
  const _TimelineEntry.item(this.item) : process = null;
  const _TimelineEntry.process(this.process) : item = null;
  String get key => process?.key ?? 'item:${item!['id']}';
}

List<_TimelineEntry> _timelineEntries(List<Json> items) {
  final entries = <_TimelineEntry>[];
  final blocks = <String, _ProcessBlock>{};
  for (var index = 0; index < items.length; index++) {
    final item = items[index];
    if (item['type'] == 'reasoning' &&
        (item['text']?.toString().trim().isEmpty ?? true)) {
      continue;
    }
    if (!_isProcessItem(item)) {
      entries.add(_TimelineEntry.item(item));
      continue;
    }
    final turnId = item['turnId']?.toString();
    final itemId = item['id']?.toString() ?? index.toString();
    final key = turnId == null ? 'legacy:$itemId' : 'turn:$turnId';
    final existing = blocks[key];
    if (existing != null) {
      existing.items.add(item);
    } else {
      final block = _ProcessBlock(key, turnId, [item]);
      blocks[key] = block;
      entries.add(_TimelineEntry.process(block));
    }
  }
  return entries;
}

class _ProcessGroup extends StatefulWidget {
  final _ProcessBlock process;
  final bool active;
  const _ProcessGroup({super.key, required this.process, required this.active});

  @override
  State<_ProcessGroup> createState() => _ProcessGroupState();
}

class _ProcessGroupState extends State<_ProcessGroup>
    with AutomaticKeepAliveClientMixin {
  late bool expanded;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    expanded = widget.active;
  }

  @override
  void didUpdateWidget(covariant _ProcessGroup oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) expanded = widget.active;
  }

  void toggle() {
    setState(() {
      expanded = !expanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            ListTile(
              key: ValueKey('process-toggle:${widget.process.key}'),
              dense: true,
              minTileHeight: 48,
              minVerticalPadding: 8,
              leading: Icon(
                widget.active
                    ? Icons.auto_awesome
                    : Icons.psychology_alt_outlined,
                size: 18,
              ),
              title: Text(
                widget.active
                    ? '正在思考…'
                    : '思考过程 · ${widget.process.items.length} 项活动',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              trailing: Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                size: 20,
              ),
              onTap: toggle,
            ),
            if (expanded && widget.process.items.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in widget.process.items)
                        TimelineItem(item: item),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class TimelineItem extends StatelessWidget {
  final Json item;
  final Workbench? workbench;
  final String? threadId;
  const TimelineItem({
    super.key,
    required this.item,
    this.workbench,
    this.threadId,
  });
  @override
  Widget build(BuildContext context) {
    final type = item['type'];
    if (type == 'userMessage') {
      final content = asList(item['content']);
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 24, left: 32),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < content.length; index++)
                if (content[index]['type'] == 'localImage' ||
                    content[index]['type'] == 'image')
                  if (workbench != null && threadId != null)
                    MessageImage(
                      key: ValueKey('${item['id']}:$index'),
                      workbench: workbench!,
                      threadId: threadId!,
                      itemId: item['id']?.toString() ?? '',
                      contentIndex: index,
                      content: content[index],
                    )
                  else
                    const ImageUnavailable(message: '缺少原图引用或主机信息')
                else if (content[index]['text']?.toString().trim() == '[图片]')
                  const ImageUnavailable(message: '历史记录缺少原图引用')
                else
                  Text(
                    content[index]['text']?.toString() ??
                        content[index]['name']?.toString() ??
                        '',
                    style: const TextStyle(height: 1.55),
                  ),
            ],
          ),
        ),
      );
    }
    if (type == 'reasoning') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '思考摘要',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            MarkdownBody(
              data: item['text']?.toString() ?? '',
              onTapLink: (_, href, _) => openLink(href),
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  height: 1.5,
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (type == 'agentMessage' || type == 'plan') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.terminal, size: 15),
                const SizedBox(width: 8),
                Text(
                  type == 'plan' ? '计划' : 'Codex',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '复制内容',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: item['text']?.toString() ?? ''),
                  ),
                  icon: const Icon(Icons.copy, size: 14),
                ),
              ],
            ),
            MarkdownBody(
              data: item['text']?.toString() ?? '',
              onTapLink: (_, href, _) => openLink(href),
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(
                  height: 1.65,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
                code: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainer,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final command = type == 'commandExecution';
    final changed = type == 'fileChange' || type == 'turnDiff';
    final title = command
        ? item['command']?.toString() ?? '执行命令'
        : changed
        ? (type == 'turnDiff' ? '本轮改动' : '修改文件')
        : type == 'mcpToolCall'
        ? '${item['server']} / ${item['tool']}'
        : type?.toString() ?? '工具活动';
    final output = command
        ? item['aggregatedOutput']?.toString() ?? ''
        : type == 'turnDiff'
        ? item['text']?.toString() ?? ''
        : const JsonEncoder.withIndent('  ').convert(item);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          dense: true,
          leading: Icon(
            command
                ? Icons.terminal
                : changed
                ? Icons.difference_outlined
                : Icons.build_outlined,
            size: 16,
          ),
          title: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          ),
          subtitle: item['status'] == null
              ? null
              : Text(
                  '${item['status']}${item['exitCode'] == null ? '' : ' · exit ${item['exitCode']}'}',
                  style: const TextStyle(fontSize: 10),
                ),
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    output.isEmpty ? '等待输出…' : output,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ToolsPane extends StatelessWidget {
  final Workbench workbench;
  const ToolsPane({super.key, required this.workbench});
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('Skills', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 10),
      if (workbench.skills.isEmpty) const Text('主机未返回可用 Skills'),
      for (final skill in workbench.skills)
        ListTile(
          leading: const Icon(Icons.auto_fix_high_outlined, size: 18),
          title: Text(skill['name']?.toString() ?? ''),
          subtitle: Text(
            skill['description']?.toString() ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.pop(context, skill),
        ),
      const Divider(),
      const SizedBox(height: 16),
      Text('MCP', style: Theme.of(context).textTheme.titleLarge),
      if (workbench.mcp.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('主机未返回 MCP 服务'),
        ),
      for (final server in workbench.mcp)
        ListTile(
          leading: const Icon(Icons.extension_outlined, size: 18),
          title: Text(server['name']?.toString() ?? 'MCP'),
          subtitle: Text(
            '${server['authStatus'] ?? 'unknown'} · ${asJson(server['tools']).length} tools',
          ),
        ),
    ],
  );
}
