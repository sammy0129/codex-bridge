import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/workbench.dart';

enum ComposerPartType { text, mention, skill }

class ComposerPart {
  final ComposerPartType type;
  String text;
  final String? name;
  final String? path;

  ComposerPart.text(this.text)
    : type = ComposerPartType.text,
      name = null,
      path = null;
  ComposerPart.reference({
    required this.type,
    required this.name,
    required this.path,
  }) : text = '';

  bool get isText => type == ComposerPartType.text;

  Json? toInput() {
    if (isText) {
      if (text.isEmpty) return null;
      return {'type': 'text', 'text': text, 'text_elements': <dynamic>[]};
    }
    return {
      'type': type == ComposerPartType.mention ? 'mention' : 'skill',
      'name': name,
      'path': path,
    };
  }
}

class CommandComposer extends StatefulWidget {
  final Workbench workbench;
  final bool enabled;
  final bool sending;
  final bool running;
  final bool canSend;
  final bool attachmentsEnabled;
  final String hint;
  final Future<void> Function() onSend;
  final Future<void> Function(String kind) onAttachment;
  final Future<void> Function()? onStop;

  const CommandComposer({
    super.key,
    required this.workbench,
    required this.enabled,
    required this.sending,
    required this.running,
    required this.canSend,
    this.attachmentsEnabled = true,
    required this.hint,
    required this.onSend,
    required this.onAttachment,
    this.onStop,
  });

  @override
  State<CommandComposer> createState() => CommandComposerState();
}

class CommandComposerState extends State<CommandComposer> {
  final parts = <ComposerPart>[ComposerPart.text('')];
  final controllers = <TextEditingController?>[];
  final focusNodes = <FocusNode?>[];
  final commands = const [
    _Command('/review', '检查当前改动并给出审查意见'),
    _Command('/compact', '压缩当前任务上下文'),
  ];
  Timer? searchTimer;
  String? menuMode;
  String menuQuery = '';
  List<Json> fileResults = [];
  int suggestionIndex = 0;
  int activeTextIndex = 0;
  int triggerStart = 0;
  int triggerEnd = 0;
  int searchGeneration = 0;

  List<Json> get input =>
      parts.map((part) => part.toInput()).whereType<Json>().toList();

  @override
  void initState() {
    super.initState();
    _recreateEditors();
  }

  @override
  void dispose() {
    searchTimer?.cancel();
    _disposeEditors();
    super.dispose();
  }

  void _disposeEditors() {
    for (final controller in controllers) {
      controller?.dispose();
    }
    for (final node in focusNodes) {
      node?.dispose();
    }
    controllers.clear();
    focusNodes.clear();
  }

  void _recreateEditors() {
    _disposeEditors();
    for (final part in parts) {
      if (part.isText) {
        controllers.add(TextEditingController(text: part.text));
        focusNodes.add(FocusNode());
      } else {
        controllers.add(null);
        focusNodes.add(null);
      }
    }
  }

  void clear() {
    setState(() {
      parts
        ..clear()
        ..add(ComposerPart.text(''));
      _recreateEditors();
      _closeMenu(notify: false);
    });
  }

  void addReference(Json reference) {
    final type = reference['type']?.toString();
    if (type != 'mention' && type != 'skill') return;
    final index = activeTextIndex.clamp(0, parts.length - 1);
    if (!parts[index].isText) return;
    final controller = controllers[index]!;
    final offset = controller.selection.baseOffset < 0
        ? controller.text.length
        : controller.selection.baseOffset.clamp(0, controller.text.length);
    _insertReference(
      index,
      offset,
      offset,
      ComposerPart.reference(
        type: type == 'mention'
            ? ComposerPartType.mention
            : ComposerPartType.skill,
        name: reference['name']?.toString() ?? '',
        path: reference['path']?.toString() ?? '',
      ),
    );
  }

  void _onTextChanged(int index, String value) {
    parts[index].text = value;
    activeTextIndex = index;
    _updateMenu(index);
    setState(() {});
  }

  void _onTextTap(int index) {
    activeTextIndex = index;
    _updateMenu(index);
  }

  void _updateMenu(int index) {
    if (!mounted || index >= controllers.length || controllers[index] == null) {
      return;
    }
    final controller = controllers[index]!;
    final offset = controller.selection.baseOffset < 0
        ? controller.text.length
        : controller.selection.baseOffset.clamp(0, controller.text.length);
    final prefix = controller.text.substring(0, offset);
    final match = RegExp(r'(^|\s)([/@])([^\s]*)$').firstMatch(prefix);
    if (match == null) {
      _closeMenu();
      return;
    }
    final mode = match.group(2)!;
    final query = match.group(3) ?? '';
    final nextStart = offset - query.length - 1;
    final changed =
        menuMode != mode || menuQuery != query || triggerStart != nextStart;
    menuMode = mode;
    menuQuery = query;
    triggerStart = nextStart;
    triggerEnd = offset;
    suggestionIndex = 0;
    if (changed) {
      if (mode == '@') {
        _scheduleReferenceSearch(query);
      } else {
        searchTimer?.cancel();
        fileResults = [];
      }
      setState(() {});
    }
  }

  void _closeMenu({bool notify = true}) {
    searchTimer?.cancel();
    if (menuMode == null && !notify) return;
    menuMode = null;
    menuQuery = '';
    fileResults = [];
    suggestionIndex = 0;
    if (notify && mounted) setState(() {});
  }

  void _scheduleReferenceSearch(String query) {
    searchTimer?.cancel();
    final request = ++searchGeneration;
    searchTimer = Timer(const Duration(milliseconds: 220), () async {
      final workbench = widget.workbench;
      var files = <Json>[];
      if (workbench.online && workbench.projectId != null) {
        try {
          files = await workbench.searchProjectFiles(query);
        } catch (_) {
          files = [];
        }
      }
      try {
        if (workbench.online && workbench.projectId != null) {
          await workbench.loadTools();
        }
      } catch (_) {}
      if (!mounted || request != searchGeneration || menuMode != '@') return;
      setState(() => fileResults = files);
    });
  }

  List<_Suggestion> get _suggestions {
    if (menuMode == '/') {
      final needle = menuQuery.toLowerCase();
      return [
        for (final command in commands)
          if (command.command.toLowerCase().contains(needle))
            _Suggestion.command(command),
      ];
    }
    if (menuMode != '@') return [];
    final needle = menuQuery.toLowerCase();
    final result = <_Suggestion>[
      for (final file in fileResults)
        if (needle.isEmpty ||
            file['name'].toString().toLowerCase().contains(needle) ||
            file['path'].toString().toLowerCase().contains(needle))
          _Suggestion.file(file),
      for (final skill in widget.workbench.skills)
        if ((skill['name']?.toString().toLowerCase().contains(needle) ??
                false) ||
            (skill['description']?.toString().toLowerCase().contains(needle) ??
                false) ||
            (skill['path']?.toString().toLowerCase().contains(needle) ?? false))
          _Suggestion.skill(skill),
    ];
    return result;
  }

  KeyEventResult _handleKey(int index, KeyEvent event) {
    if (event is! KeyDownEvent || menuMode == null) {
      return KeyEventResult.ignored;
    }
    final values = _suggestions;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && values.isNotEmpty) {
      setState(() => suggestionIndex = (suggestionIndex + 1) % values.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && values.isNotEmpty) {
      setState(
        () => suggestionIndex =
            (suggestionIndex - 1 + values.length) % values.length,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeMenu();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && values.isNotEmpty) {
      _select(values[suggestionIndex]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _select(_Suggestion suggestion) {
    if (suggestion.command != null) {
      final controller = controllers[activeTextIndex]!;
      final value = controller.text;
      final replacement = suggestion.command!.command == '/review'
          ? '/review '
          : suggestion.command!.command;
      final before = value.substring(0, triggerStart);
      final after = value.substring(triggerEnd);
      final text = before + replacement + after;
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: before.length + replacement.length,
        ),
      );
      parts[activeTextIndex].text = text;
      _closeMenu();
      focusNodes[activeTextIndex]?.requestFocus();
      setState(() {});
      return;
    }
    final token = suggestion.kind == 'mention'
        ? ComposerPart.reference(
            type: ComposerPartType.mention,
            name: suggestion.data['name']?.toString() ?? '',
            path: suggestion.data['path']?.toString() ?? '',
          )
        : ComposerPart.reference(
            type: ComposerPartType.skill,
            name: suggestion.data['name']?.toString() ?? '',
            path: suggestion.data['path']?.toString() ?? '',
          );
    _insertReference(activeTextIndex, triggerStart, triggerEnd, token);
  }

  void _insertReference(int index, int start, int end, ComposerPart token) {
    final controller = controllers[index]!;
    final value = controller.text;
    final before = value.substring(0, start);
    final after = value.substring(end);
    final next = <ComposerPart>[
      ...parts.take(index),
      ComposerPart.text(before),
      token,
      ComposerPart.text(after),
      ...parts.skip(index + 1),
    ];
    final focusIndex = index + 2;
    setState(() {
      parts
        ..clear()
        ..addAll(next);
      _recreateEditors();
      menuMode = null;
      menuQuery = '';
      fileResults = [];
      suggestionIndex = 0;
      activeTextIndex = focusIndex;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusIndex < focusNodes.length) {
        focusNodes[focusIndex]?.requestFocus();
      }
    });
  }

  void _removeToken(int index) {
    final previous = index > 0 && parts[index - 1].isText
        ? parts[index - 1]
        : null;
    final next = index + 1 < parts.length && parts[index + 1].isText
        ? parts[index + 1]
        : null;
    if (previous == null || next == null) return;
    final merged = previous.text + next.text;
    final replacement = <ComposerPart>[
      ...parts.take(index - 1),
      ComposerPart.text(merged),
      ...parts.skip(index + 2),
    ];
    final focusIndex = index - 1;
    setState(() {
      parts
        ..clear()
        ..addAll(replacement);
      _recreateEditors();
      activeTextIndex = focusIndex;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && focusIndex < controllers.length) {
        final controller = controllers[focusIndex]!;
        controller.selection = TextSelection.collapsed(
          offset: previous.text.length,
        );
        focusNodes[focusIndex]?.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final values = _suggestions;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (menuMode != null)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: Card(
              margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              clipBehavior: Clip.antiAlias,
              child: values.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        menuMode == '@' && widget.workbench.projectId == null
                            ? '请选择项目后引用文件或 Skill'
                            : '没有匹配项，可继续输入后直接发送',
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: values.length,
                      itemBuilder: (_, index) {
                        final value = values[index];
                        return ListTile(
                          selected: index == suggestionIndex,
                          leading: Icon(value.icon),
                          title: Text(
                            value.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            value.subtitle,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _select(value),
                        );
                      },
                    ),
            ),
          ),
        for (var index = 0; index < parts.length; index++)
          if (parts[index].isText)
            Focus(
              onKeyEvent: (_, event) => _handleKey(index, event),
              child: TextField(
                controller: controllers[index],
                focusNode: focusNodes[index],
                minLines: 1,
                maxLines: 6,
                enabled: widget.enabled,
                textCapitalization: TextCapitalization.sentences,
                onTap: () => _onTextTap(index),
                onChanged: (value) => _onTextChanged(index, value),
                decoration: InputDecoration(
                  hintText: index == parts.length - 1 ? widget.hint : null,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                ),
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                child: InputChip(
                  avatar: Icon(
                    parts[index].type == ComposerPartType.skill
                        ? Icons.auto_awesome_outlined
                        : Icons.insert_drive_file_outlined,
                    size: 17,
                  ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      parts[index].name ?? '',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  deleteButtonTooltipMessage: '移除引用',
                  onDeleted: widget.sending ? null : () => _removeToken(index),
                ),
              ),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 8, 6),
          child: Row(
            children: [
              PopupMenuButton<String>(
                enabled:
                    widget.enabled &&
                    widget.attachmentsEnabled &&
                    widget.workbench.projectId != null,
                tooltip: '添加图片、文件或 Skill',
                onSelected: widget.onAttachment,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'camera', child: Text('拍照')),
                  PopupMenuItem(value: 'image', child: Text('相册图片')),
                  PopupMenuItem(value: 'file', child: Text('项目文件')),
                  PopupMenuItem(value: 'skill', child: Text('Skills')),
                ],
                icon: const Icon(Icons.add),
              ),
              if (widget.running)
                const Expanded(
                  child: Row(
                    children: [
                      SizedBox(width: 8),
                      Icon(Icons.circle, size: 8, color: Colors.green),
                      SizedBox(width: 6),
                      Text('正在执行', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                )
              else
                const Spacer(),
              if (widget.running)
                IconButton(
                  tooltip: '停止当前任务',
                  onPressed: widget.onStop,
                  icon: const Icon(Icons.stop_circle_outlined),
                ),
              IconButton.filled(
                tooltip: widget.running ? '追加指令' : '发送任务',
                onPressed: widget.canSend && !widget.sending
                    ? widget.onSend
                    : null,
                icon: widget.sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_upward, size: 20),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Command {
  final String command;
  final String description;
  const _Command(this.command, this.description);
}

class _Suggestion {
  final String kind;
  final String title;
  final String subtitle;
  final IconData icon;
  final Json data;
  final _Command? command;

  const _Suggestion({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.data,
    this.command,
  });

  factory _Suggestion.command(_Command command) => _Suggestion(
    kind: 'command',
    title: command.command,
    subtitle: command.description,
    icon: Icons.terminal,
    data: const {},
    command: command,
  );

  factory _Suggestion.file(Json file) => _Suggestion(
    kind: 'mention',
    title: file['name']?.toString() ?? '',
    subtitle: file['path']?.toString() ?? '',
    icon: Icons.insert_drive_file_outlined,
    data: file,
  );

  factory _Suggestion.skill(Json skill) => _Suggestion(
    kind: 'skill',
    title: skill['name']?.toString() ?? '',
    subtitle:
        skill['description']?.toString() ?? skill['path']?.toString() ?? '',
    icon: Icons.auto_awesome_outlined,
    data: skill,
  );
}
