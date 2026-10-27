import 'package:flutter/material.dart';

import '../core/palette.dart';
import '../theme/pindou_theme.dart';
import '../theme/theme_controller.dart';

/// 设置对话框：主题外观 + 拼豆色卡选择。
///
/// 点击立即切换（对话框不关，可连续试看效果），「完成」关闭。
/// 卡片预览色取自各主题自身定义，不依赖当前主题。
Future<void> showSettingsDialog(BuildContext context, AppSettings settings) {
  return showDialog<void>(
    context: context,
    builder: (context) => _SettingsDialog(settings: settings),
  );
}

class _SettingsDialog extends StatelessWidget {
  _SettingsDialog({required this.settings});

  final AppSettings settings;

  /// 自定义底板尺寸输入框（对话框生命周期内共享）。
  final _boardCtrl = TextEditingController();

  static String? _boardError(int current) {
    if (current < 29 || current > 200) return '需在 29 ~ 200 之间';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('设置',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('主题外观',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: settings,
                builder: (context, _) => GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  childAspectRatio: 2.1,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    for (final theme in kPindouThemes)
                      _ThemeCard(
                        theme: theme,
                        selected: settings.theme.id == theme.id,
                        onTap: () => settings.setTheme(theme.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('拼豆色卡',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              ListenableBuilder(
                listenable: settings,
                builder: (context, _) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final set in BeadPalette.ordered)
                      ChoiceChip(
                        label: Text(set.displayName),
                        selected: settings.paletteId == set.id,
                        onSelected: (_) => settings.setPalette(set.id),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text('底板尺寸（正方形，豆数）',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('统计/分板导出/打印按此尺寸分板；画布虚线同步',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              ListenableBuilder(
                listenable: settings,
                builder: (context, _) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in const [29, 50, 58, 87])
                      ChoiceChip(
                        label: Text('$preset x $preset'),
                        selected: settings.boardSize == preset,
                        onSelected: (_) => settings.setBoardSize(preset),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              ListenableBuilder(
                listenable: settings,
                builder: (context, _) => Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: TextField(
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: '自定义',
                          border: const OutlineInputBorder(),
                          isDense: true,
                          errorText: _boardError(settings.boardSize),
                        ),
                        controller: _boardCtrl,
                        onSubmitted: (v) {
                          final n = int.tryParse(v);
                          if (n != null && n >= 29 && n <= 200) {
                            settings.setBoardSize(n);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('29 ~ 200（最小 29 兼容历史）',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成'),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// 单张主题卡片：迷你预览（背景 + 主色圆点 + 画布网格示意）+ 名称 + 选中标记。
class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final PindouTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = theme.preview;
    final borderColor = selected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outlineVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: borderColor, width: selected ? 2 : 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 迷你预览：主题底色上放主色圆点 + 画布色块（带网格示意线）。
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: p.background,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: p.gridLine),
                ),
                padding: const EdgeInsets.all(6),
                child: Row(
                  children: [
                    Container(
                      width: 18,
                      height: 18,
                      decoration:
                          BoxDecoration(color: p.primary, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: p.canvasBg,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: CustomPaint(
                          painter: _GridHintPainter(color: p.gridLine),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    theme.name,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (selected)
                  Icon(Icons.check_circle,
                      size: 18, color: Theme.of(context).colorScheme.primary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片预览里的网格示意线（横竖各两条）。
class _GridHintPainter extends CustomPainter {
  const _GridHintPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = color;
    final path = Path()
      ..moveTo(0, size.height / 2)
      ..lineTo(size.width, size.height / 2)
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width / 2, size.height);
    canvas.drawPath(path, paint);
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(covariant _GridHintPainter oldDelegate) =>
      oldDelegate.color != color;
}
