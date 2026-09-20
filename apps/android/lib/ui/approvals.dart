import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/workbench.dart';
import 'common.dart';

Future<void> showApprovals(BuildContext context, Workbench workbench) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ListenableBuilder(
        listenable: workbench,
        builder: (context, _) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .85,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text('等待你处理', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 16),
              if (workbench.approvals.isEmpty)
                const EmptyState(
                  icon: Icons.check_circle_outline,
                  title: '没有待处理请求',
                  subtitle: '已解决或过期的请求不会再次提交。',
                ),
              for (final request in workbench.approvals)
                ApprovalCard(
                  key: ValueKey(request['id']),
                  request: request,
                  workbench: workbench,
                ),
            ],
          ),
        ),
      ),
    );

class ApprovalCard extends StatefulWidget {
  final Json request;
  final Workbench workbench;
  const ApprovalCard({
    super.key,
    required this.request,
    required this.workbench,
  });
  @override
  State<ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<ApprovalCard> {
  final Map<String, String> answers = {};
  final form = TextEditingController(text: '{}');
  bool busy = false;
  @override
  void dispose() {
    form.dispose();
    super.dispose();
  }

  Future<void> respond(Json result) async {
    setState(() => busy = true);
    await guard(
      widget.workbench,
      () => widget.workbench.respond(widget.request['id'] as String, result),
    );
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final method = widget.request['method'];
    final params = asJson(widget.request['params']);
    final question = method == 'item/tool/requestUserInput';
    final elicitation = method == 'mcpServer/elicitation/request';
    final permissions = method == 'item/permissions/requestApproval';
    final enabled = widget.workbench.online && !busy;
    final decisions =
        params['availableDecisions'] as List? ??
        ['accept', 'acceptForSession', 'decline', 'cancel'];
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              question
                  ? '需要补充信息'
                  : elicitation
                  ? 'MCP 请求'
                  : permissions
                  ? '额外权限请求'
                  : '操作审批',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '任务 ${params['threadId'] ?? ''}',
              style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            if (question) ...[
              for (final entry in asList(params['questions']))
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry['question']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      for (final option in asList(entry['options']))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: Icon(
                            answers[entry['id']] == option['label']
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                          ),
                          title: Text(option['label']?.toString() ?? ''),
                          subtitle: Text(
                            option['description']?.toString() ?? '',
                          ),
                          onTap: enabled
                              ? () => setState(
                                  () => answers[entry['id'] as String] =
                                      option['label'] as String,
                                )
                              : null,
                        ),
                      if (entry['isOther'] == true ||
                          asList(entry['options']).isEmpty)
                        TextField(
                          obscureText: entry['isSecret'] == true,
                          decoration: const InputDecoration(labelText: '你的回答'),
                          onChanged: (value) =>
                              answers[entry['id'] as String] = value,
                        ),
                    ],
                  ),
                ),
              FilledButton(
                onPressed: enabled
                    ? () {
                        final questions = asList(params['questions']);
                        if (questions.any(
                          (entry) => (answers[entry['id']] ?? '').isEmpty,
                        )) {
                          widget.workbench.showError(
                            const RpcException(
                              'ANSWER_REQUIRED',
                              'Please answer every question.',
                            ),
                          );
                          return;
                        }
                        unawaited(
                          respond({
                            'answers': {
                              for (final entry in questions)
                                entry['id']: {
                                  'answers': [answers[entry['id']]],
                                },
                            },
                          }),
                        );
                      }
                    : null,
                child: const Text('提交回答'),
              ),
            ] else if (elicitation) ...[
              Text(
                params['message']?.toString() ??
                    params['description']?.toString() ??
                    '',
              ),
              if (params['mode'] == 'url')
                TextButton(
                  onPressed: enabled
                      ? () {
                          final uri = Uri.tryParse(
                            params['url']?.toString() ?? '',
                          );
                          if (uri != null &&
                              ['http', 'https'].contains(uri.scheme)) {
                            unawaited(
                              launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              ),
                            );
                          }
                        }
                      : null,
                  child: Text(params['url']?.toString() ?? '打开链接'),
                ),
              if (params['requestedSchema'] != null) ...[
                ExpansionTile(
                  title: const Text('查看表单结构'),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent('  ')
                          .convert(params['requestedSchema']),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: form,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(labelText: '按表单结构填写 JSON'),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: enabled
                        ? () => respond({
                            'action': 'decline',
                            'content': null,
                            '_meta': null,
                          })
                        : null,
                    child: const Text('拒绝'),
                  ),
                  if (params['mode'] != 'openai/userVerification')
                    FilledButton(
                      onPressed: enabled
                          ? () {
                              try {
                                unawaited(
                                  respond({
                                    'action': 'accept',
                                    'content': params['requestedSchema'] == null
                                        ? null
                                        : jsonDecode(form.text),
                                    '_meta': null,
                                  }),
                                );
                              } catch (error) {
                                widget.workbench.showError(error);
                              }
                            }
                          : null,
                      child: const Text('确认'),
                    ),
                ],
              ),
            ] else if (permissions) ...[
              Text(params['reason']?.toString() ?? ''),
              const SizedBox(height: 8),
              SelectableText(
                const JsonEncoder.withIndent('  ')
                    .convert(params['permissions']),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: enabled
                        ? () => respond({
                            'permissions': <String, dynamic>{},
                            'scope': 'turn',
                          })
                        : null,
                    child: const Text('不授予'),
                  ),
                  FilledButton(
                    onPressed: enabled
                        ? () => respond({
                            'permissions': params['permissions'],
                            'scope': 'turn',
                          })
                        : null,
                    child: const Text('仅本轮授予'),
                  ),
                ],
              ),
            ] else ...[
              Text(params['reason']?.toString() ?? '主机正在等待你的决定。'),
              const SizedBox(height: 8),
              if (params['networkApprovalContext'] != null)
                SelectableText(
                  const JsonEncoder.withIndent('  ')
                      .convert(params['networkApprovalContext']),
                ),
              SelectableText(
                params['command']?.toString() ??
                    params['grantRoot']?.toString() ??
                    '',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final decision in decisions)
                    OutlinedButton(
                      onPressed: enabled
                          ? () => respond({'decision': decision})
                          : null,
                      child: Text(switch (decision) {
                        'accept' => '允许一次',
                        'acceptForSession' => '本会话允许',
                        'decline' => '拒绝',
                        'cancel' => '取消',
                        _ => jsonEncode(decision),
                      }),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
