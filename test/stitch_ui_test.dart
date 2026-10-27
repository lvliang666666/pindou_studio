import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/core/palette.dart';
import 'package:pindou_studio/core/stitcher.dart';
import 'package:pindou_studio/state/editor_state.dart';
import 'package:pindou_studio/theme/theme_controller.dart';
import 'package:pindou_studio/ui/editor/editor_page.dart';
import 'package:pindou_studio/ui/stitch_dialog.dart';

/// 生成纯色 RGBA 像素图。
Uint8List solidPixels(int w, int h, int r, int g, int b) {
  return Uint8List.fromList([
    for (int i = 0; i < w * h; i++) ...[r, g, b, 255],
  ]);
}

void main() {
  testWidgets('参数区显示多图拼合入口', (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MaterialApp(home: EditorPage(state: state, settings: settings)),
    );
    await tester.pumpAndSettle();

    expect(find.text('多图拼合'), findsOneWidget);
  });

  testWidgets('拼合对话框：打开后显示参数控件，取消关闭', (tester) async {
    StitchResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showStitchDialog(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('多图拼合'), findsOneWidget);
    expect(find.text('选择图片（可多选）'), findsOneWidget);
    expect(find.text('单张最长边：29 豆'), findsOneWidget);
    expect(find.text('每行张数：2'), findsOneWidget);
    expect(find.text('拼合后总尺寸：—'), findsOneWidget);

    // 取消关闭，无结果。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('loadPattern：拼合结果装入编辑器（无原图模式）', (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MaterialApp(home: EditorPage(state: state, settings: settings)),
    );
    await tester.pumpAndSettle();

    // 模拟拼合结果：两张 10x10 纯色图拼成 20x10。
    final result = BeadStitcher.stitch(
      images: [
        (solidPixels(10, 10, 255, 0, 0), 10, 10),
        (solidPixels(10, 10, 0, 0, 255), 10, 10),
      ],
      options: const StitchOptions(perImageMaxSize: 29, columns: 2),
    );
    state.loadPattern(result.pattern, name: '多图拼合');
    await tester.pumpAndSettle();

    // 编辑器状态：图纸已装入，无原图。
    expect(state.pattern, isNotNull);
    expect(state.pattern!.width, 20);
    expect(state.pattern!.height, 10);
    expect(state.projectName, '多图拼合');
    expect(state.hasUnsavedChanges, isTrue);
    expect(state.srcWidth, 0); // 无原图像素
    expect(state.previewImage, isNull);
    // 尺寸输入框同步。
    expect(state.gridWidthCtrl.text, '20');
    expect(state.gridHeightCtrl.text, '10');
  });

  testWidgets('loadPattern 后手动编辑与统计可用', (tester) async {
    final state = EditorState();
    addTearDown(state.dispose);
    final settings = AppSettings();
    addTearDown(settings.dispose);

    await tester.pumpWidget(
      MaterialApp(home: EditorPage(state: state, settings: settings)),
    );
    await tester.pumpAndSettle();

    final result = BeadStitcher.stitch(
      images: [(solidPixels(10, 10, 255, 0, 0), 10, 10)],
      options: const StitchOptions(perImageMaxSize: 29, columns: 1),
    );
    state.loadPattern(result.pattern);
    await tester.pumpAndSettle();

    // 手动编辑：把 (0,0) 涂成黑色系。
    final black = BeadPalette.colors
        .where((c) => c.red < 40 && c.green < 40 && c.blue < 40)
        .first;
    final applied = state.editCell(0, 0, black);
    expect(applied, isNotNull);
    expect(state.manualEdits['0,0'], black.code);
    expect(state.canUndo, isTrue);

    // 撤销恢复。
    state.undo();
    expect(state.manualEdits.isEmpty, isTrue);
  });
}
