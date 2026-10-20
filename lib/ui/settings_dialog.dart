import 'package:flutter/material.dart';

import '../theme/pindou_theme.dart';
import '../theme/theme_controller.dart';

/// 设置对话框：主题外观选择。
///
/// 点击卡片立即切换（对话框不关，可连续试看效果），「完成」关闭。
/// 卡片预览色取自各主题自身定义，不依赖当前主题。
Future<void> showSettingsDialog(BuildContext context, ThemeController controller) {
  return showDialog<void>(
    context: context,
    builder: (context) => _SettingsDialog(controller: controller),
  );
}

class _SettingsDialog extends StatelessWidget {
  const _SettingsDialog({required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
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
                listenable: controller,
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
                        selected: controller.current.id == theme.id,
                        onTap: () => controller.select(theme.id),
                      ),
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
