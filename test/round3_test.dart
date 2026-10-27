import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/state/editor_state.dart';
import 'package:pindou_studio/ui/export_service.dart';

/// 构造 4x4 纯红图纸的 AppState（绕过文件加载）。
EditorState _makeState() {
  final state = EditorState();
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
  return state;
}

void main() {
  group('撤销/重做', () {
    test('单格编辑可撤销重做', () {
      final state = _makeState();
      final white = BeadPalette.byCode['A1']!;

      expect(state.canUndo, isFalse);
      state.editCell(0, 0, white);
      expect(state.canUndo, isTrue);
      expect(state.pattern!.cellAt(0, 0)!.code, 'A1');

      state.undo();
      expect(state.pattern!.cellAt(0, 0)!.code, 'D1'); // 恢复自动转换色
      expect(state.canRedo, isTrue);
      expect(state.manualEdits.isEmpty, isTrue);

      state.redo();
      expect(state.pattern!.cellAt(0, 0)!.code, 'A1');
      expect(state.manualEdits['0,0'], 'A1');
      state.dispose();
    });

    test('一笔多格涂色合并为一步撤销', () {
      final state = _makeState();
      final white = BeadPalette.byCode['A1']!;

      state.beginStroke();
      state.paintCell(0, 0, white);
      state.paintCell(1, 0, white);
      state.paintCell(2, 0, white);
      state.endStroke();

      expect(state.pattern!.cellAt(0, 0)!.code, 'A1');
      expect(state.pattern!.cellAt(1, 0)!.code, 'A1');
      expect(state.pattern!.cellAt(2, 0)!.code, 'A1');
      expect(state.manualEdits.length, 3);

      state.undo();
      expect(state.pattern!.cellAt(0, 0)!.code, 'D1');
      expect(state.pattern!.cellAt(1, 0)!.code, 'D1');
      expect(state.pattern!.cellAt(2, 0)!.code, 'D1');
      expect(state.manualEdits.isEmpty, isTrue);

      state.redo();
      expect(state.manualEdits.length, 3);
      state.dispose();
    });

    test('同一笔内重复涂同一格只保留最终结果', () {
      final state = _makeState();
      final white = BeadPalette.byCode['A1']!;
      final black = BeadPalette.byCode['B1']!;

      state.beginStroke();
      state.paintCell(0, 0, white);
      state.paintCell(0, 0, black);
      state.endStroke();

      expect(state.pattern!.cellAt(0, 0)!.code, 'B1');
      state.undo();
      expect(state.pattern!.cellAt(0, 0)!.code, 'D1'); // 一步回到最初
      state.dispose();
    });

    test('新编辑清空重做栈', () {
      final state = _makeState();
      final white = BeadPalette.byCode['A1']!;
      final black = BeadPalette.byCode['B1']!;

      state.editCell(0, 0, white);
      state.undo();
      expect(state.canRedo, isTrue);
      state.editCell(1, 1, black);
      expect(state.canRedo, isFalse); // 分叉后重做栈作废
      state.dispose();
    });

    test('涂回自动转换色即清除编辑记录', () {
      final state = _makeState();
      final white = BeadPalette.byCode['A1']!;

      state.editCell(0, 0, white);
      expect(state.manualEdits['0,0'], 'A1');
      state.editCell(0, 0, BeadPalette.byCode['D1']!); // 涂回 D1
      expect(state.manualEdits.isEmpty, isTrue);
      state.dispose();
    });
  });

  group('擦除', () {
    test('擦除恢复自动转换色并可撤销', () {
      final state = _makeState();
      final white = BeadPalette.byCode['A1']!;

      state.editCell(0, 0, white);
      state.eraseCell(0, 0);
      expect(state.pattern!.cellAt(0, 0)!.code, 'D1');
      expect(state.manualEdits.isEmpty, isTrue);

      state.undo(); // 撤销擦除 -> 回到 A1
      expect(state.pattern!.cellAt(0, 0)!.code, 'A1');
      state.dispose();
    });

    test('未编辑过的格子擦除 = 擦成空格（抠背景兜底）', () {
      final state = _makeState();
      state.eraseCell(3, 3);
      // 新语义：右键擦除自动转换色的格子 → 变空格（清除残留豆）。
      expect(state.pattern!.cellAt(3, 3), isNull);
      expect(state.canUndo, isTrue);
      // 撤销后恢复原豆。
      state.undo();
      expect(state.pattern!.cellAt(3, 3)!.code, 'D1');
      state.dispose();
    });
  });

  group('分板切分', () {
    test('29x29 为 1 块，30x30 为 4 块，58x29 为 2 块', () {
      Uint8List solid(int w, int h) {
        final px = Uint8List(w * h * 4);
        for (int i = 0; i < px.length; i += 4) {
          px[i] = 220;
          px[i + 1] = 30;
          px[i + 2] = 40;
          px[i + 3] = 255;
        }
        return px;
      }

      BeadPattern convert(int w, int h) => BeadConverter.convert(
            pixels: solid(w, h),
            srcWidth: w,
            srcHeight: h,
            options: ConvertOptions(
                gridWidth: w, gridHeight: h, dither: false),
          );

      expect(ExportService.splitByBoards(convert(29, 29)).length, 1);
      expect(ExportService.splitByBoards(convert(30, 30)).length, 4);
      expect(ExportService.splitByBoards(convert(58, 29)).length, 2);
    });

    test('切分后各块尺寸与内容正确', () {
      // 3x3 图纸按 2x2 切分 -> 4 块（含 1x1 / 1x2 边角块）。
      final px = Uint8List(3 * 3 * 4);
      for (int i = 0; i < px.length; i += 4) {
        px[i] = 220;
        px[i + 1] = 30;
        px[i + 2] = 40;
        px[i + 3] = 255;
      }
      final pattern = BeadConverter.convert(
        pixels: px,
        srcWidth: 3,
        srcHeight: 3,
        options: const ConvertOptions(gridWidth: 3, gridHeight: 3, dither: false),
      );
      final boards = ExportService.splitByBoards(pattern, boardSize: 2);
      expect(boards.length, 4);
      expect(boards[0].$1, 0);
      expect(boards[0].$2, 0);
      expect(boards[0].$3.width, 2);
      expect(boards[0].$3.height, 2);
      // 右下角块：1x1。
      final last = boards[3];
      expect(last.$1, 1);
      expect(last.$2, 1);
      expect(last.$3.width, 1);
      expect(last.$3.height, 1);
      // 内容一致：各块豆数之和 = 总豆数。
      final total = boards.fold<int>(0, (s, b) => s + b.$3.totalBeads);
      expect(total, 9);
    });
  });
}
