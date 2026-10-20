import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/state/editor_state.dart';
import 'package:pindou_studio/theme/pindou_theme.dart';
import 'package:pindou_studio/theme/theme_controller.dart';
import 'package:pindou_studio/ui/export_service.dart';
import 'package:pindou_studio/ui/editor/editor_page.dart';
import 'package:pindou_studio/ui/pattern_canvas.dart';

void main() {
  testWidgets('编辑器渲染：标题与关键控件存在', (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    final themeController = ThemeController();
    addTearDown(themeController.dispose);

    await tester.pumpWidget(
      MaterialApp(home: EditorPage(state: state, themeController: themeController)),
    );
    await tester.pumpAndSettle();

    // AppBar 标题：未保存新项目显示默认名。
    expect(find.text('未命名项目'), findsOneWidget);
    expect(find.text('导入图片'), findsOneWidget);
    expect(find.text('图纸尺寸（豆数）'), findsOneWidget);
    expect(find.text('锁定宽高比'), findsOneWidget);
    expect(find.text('抖动（Floyd-Steinberg）'), findsOneWidget);
    // 测试视口较窄（默认 800x600），走两栏布局：统计面板需切到统计标签。
    expect(find.text('参数'), findsWidgets);
    expect(find.text('统计'), findsWidgets);
    expect(find.text('请先导入图片并生成图纸'), findsOneWidget);
  });

  testWidgets('画布渲染图纸并支持点击回调', (tester) async {
    // 构造 4x4 纯色图纸。
    final px = Uint8List(8 * 8 * 4);
    for (int i = 0; i < px.length; i += 4) {
      px[i] = 220;
      px[i + 1] = 30;
      px[i + 2] = 40;
      px[i + 3] = 255;
    }
    final pattern = BeadConverter.convert(
      pixels: px,
      srcWidth: 8,
      srcHeight: 8,
      options: const ConvertOptions(gridWidth: 4, gridHeight: 4, dither: false),
    );

    int? tappedX;
    int? tappedY;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PatternCanvas(
            pattern: pattern,
            colors: PindouCanvasColors.light,
            onCellTap: (x, y) {
              tappedX = x;
              tappedY = y;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 点击图纸区域中心（CustomPaint 即 4x4 网格子组件）-> 格子 (2, 2)。
    // 无论画布是否已自适应缩放，图纸子组件中心都对应格子 (2, 2)。
    final canvasCenter = tester.getCenter(find.byType(PatternCanvas));
    await tester.tapAt(canvasCenter);
    await tester.pumpAndSettle();
    expect(tappedX, 2);
    expect(tappedY, 2);
  });

  testWidgets('手动编辑格子后统计更新', (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);

    // 直接构造 pattern 注入（绕过文件加载）。
    final px = Uint8List(8 * 8 * 4);
    for (int i = 0; i < px.length; i += 4) {
      px[i] = 220;
      px[i + 1] = 30;
      px[i + 2] = 40;
      px[i + 3] = 255;
    }
    state.pattern = BeadConverter.convert(
      pixels: px,
      srcWidth: 8,
      srcHeight: 8,
      options: const ConvertOptions(gridWidth: 4, gridHeight: 4, dither: false),
    );

    // 编辑 (0,0) 为白色 A1。
    final white = BeadPalette.byCode['A1']!;
    state.editCell(0, 0, white);
    await tester.pump();

    expect(state.pattern!.cellAt(0, 0).code, 'A1');
    expect(state.manualEdits['0,0'], 'A1');
    // 统计中 A1 应有 1 个。
    final a1 = state.pattern!.counts.where((c) => c.color.code == 'A1');
    expect(a1.length, 1);
    expect(a1.first.count, 1);
  });

  test('CSV 导出包含表头与总计', () {
    final px = Uint8List(8 * 8 * 4);
    for (int i = 0; i < px.length; i += 4) {
      px[i] = 220;
      px[i + 1] = 30;
      px[i + 2] = 40;
      px[i + 3] = 255;
    }
    final pattern = BeadConverter.convert(
      pixels: px,
      srcWidth: 8,
      srcHeight: 8,
      options: const ConvertOptions(gridWidth: 4, gridHeight: 4, dither: false),
    );
    final csv = ExportService.buildCsv(pattern);
    expect(csv.startsWith('色号,颜色名称,数量'), isTrue);
    expect(csv.contains('总计,,16'), isTrue);
    expect(csv.contains('D1'), isTrue);
  });
}
