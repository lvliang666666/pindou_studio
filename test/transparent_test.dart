import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/data/project_model.dart';
import 'package:pindou_studio/state/editor_state.dart';

/// 构造纯色 RGBA 图像。
Uint8List solidImage(int w, int h, int r, int g, int b, [int a = 255]) {
  final px = Uint8List(w * h * 4);
  for (int i = 0; i < px.length; i += 4) {
    px[i] = r;
    px[i + 1] = g;
    px[i + 2] = b;
    px[i + 3] = a;
  }
  return px;
}

/// 构造"白底 + 中央红色方块"图像（抠背景测试的标准样本）。
Uint8List redSquareOnWhite(int w, int h, int square) {
  final px = Uint8List(w * h * 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final idx = (y * w + x) * 4;
      final inSquare = x >= (w - square) ~/ 2 &&
          x < (w - square) ~/ 2 + square &&
          y >= (h - square) ~/ 2 &&
          y < (h - square) ~/ 2 + square;
      if (inSquare) {
        px[idx] = 220;
        px[idx + 1] = 30;
        px[idx + 2] = 40;
      } else {
        px[idx] = 255;
        px[idx + 1] = 255;
        px[idx + 2] = 255;
      }
      px[idx + 3] = 255;
    }
  }
  return px;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BeadPattern 空格语义', () {
    test('totalBeads 只统计非空格', () {
      final red = BeadPalette.colors.first;
      final pattern = BeadPattern(
        width: 4,
        height: 2,
        cells: [red, null, red, null, null, red, red, red],
        counts: [BeadCount(color: red, count: 5)],
      );
      expect(pattern.emptyCells, 3);
      expect(pattern.totalBeads, 5);
    });

    test('cellAt 空格返回 null', () {
      final red = BeadPalette.colors.first;
      final pattern = BeadPattern(
        width: 2,
        height: 1,
        cells: [null, red],
        counts: const [],
      );
      expect(pattern.cellAt(0, 0), isNull);
      expect(pattern.cellAt(1, 0), same(red));
    });
  });

  group('透明像素转换', () {
    test('全透明图：全部格子为空格，counts 为空', () {
      final pattern = BeadConverter.convert(
        pixels: solidImage(20, 20, 255, 0, 0, 0), // 全透明
        srcWidth: 20,
        srcHeight: 20,
        options: const ConvertOptions(gridWidth: 10, gridHeight: 10),
      );
      expect(pattern.cells.every((c) => c == null), isTrue);
      expect(pattern.counts, isEmpty);
      expect(pattern.totalBeads, 0);
      expect(pattern.emptyCells, 100);
    });

    test('半透明分区：透明区空格、不透明区有豆', () {
      // 左半透明、右半不透明红色。
      final px = Uint8List(20 * 10 * 4);
      for (int y = 0; y < 10; y++) {
        for (int x = 0; x < 20; x++) {
          final idx = (y * 20 + x) * 4;
          px[idx] = 220;
          px[idx + 1] = 30;
          px[idx + 2] = 40;
          px[idx + 3] = x < 10 ? 0 : 255;
        }
      }
      final pattern = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 10,
        options: const ConvertOptions(gridWidth: 10, gridHeight: 5, dither: false),
      );
      // 左半（x<5）应为空格，右半应有豆。
      expect(pattern.cellAt(0, 2), isNull);
      expect(pattern.cellAt(9, 2), isNotNull);
      expect(pattern.totalBeads, greaterThan(0));
      expect(pattern.totalBeads, lessThan(50));
    });

    test('抖动模式：空格不接收误差扩散', () {
      // 透明区旁边放高误差颜色，空格必须保持空（不被染成豆色）。
      final px = Uint8List(20 * 10 * 4);
      for (int y = 0; y < 10; y++) {
        for (int x = 0; x < 20; x++) {
          final idx = (y * 20 + x) * 4;
          px[idx] = 255;
          px[idx + 1] = 255;
          px[idx + 2] = 255;
          px[idx + 3] = x < 10 ? 0 : 255;
        }
      }
      final pattern = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 10,
        options: const ConvertOptions(gridWidth: 10, gridHeight: 5, dither: true),
      );
      for (int y = 0; y < 5; y++) {
        expect(pattern.cellAt(0, y), isNull, reason: '空格列 (x=0, y=$y) 被误差污染');
        expect(pattern.cellAt(2, y), isNull);
      }
    });
  });

  group('自动抠背景', () {
    test('白底红方块：背景格变空格、主体保留', () {
      final pattern = BeadConverter.convert(
        pixels: redSquareOnWhite(50, 50, 30),
        srcWidth: 50,
        srcHeight: 50,
        options: const ConvertOptions(
          gridWidth: 25,
          gridHeight: 25,
          dither: false,
          removeBackground: true,
          bgTolerance: 32,
        ),
      );
      // 四角应为空格。
      expect(pattern.cellAt(0, 0), isNull);
      expect(pattern.cellAt(24, 0), isNull);
      expect(pattern.cellAt(0, 24), isNull);
      expect(pattern.cellAt(24, 24), isNull);
      // 中心应为红色系豆。
      final center = pattern.cellAt(12, 12)!;
      expect(center.red, greaterThan(center.green));
      expect(center.red, greaterThan(center.blue));
      // 总豆数应明显小于满格（背景被抠掉）。
      expect(pattern.totalBeads, lessThan(25 * 25 * 0.7));
      expect(pattern.emptyCells, greaterThan(0));
    });

    test('关闭抠背景：同样图片全部有豆', () {
      final pattern = BeadConverter.convert(
        pixels: redSquareOnWhite(50, 50, 30),
        srcWidth: 50,
        srcHeight: 50,
        options: const ConvertOptions(
          gridWidth: 25,
          gridHeight: 25,
          dither: false,
          removeBackground: false,
        ),
      );
      expect(pattern.cellAt(0, 0), isNotNull);
      expect(pattern.emptyCells, 0);
    });

    test('非纯色背景（渐变）：不误抠（采样点不同色不满足投票阈值）', () {
      // 四角各不同色的图：不应触发抠背景。
      final px = Uint8List(20 * 20 * 4);
      for (int y = 0; y < 20; y++) {
        for (int x = 0; x < 20; x++) {
          final idx = (y * 20 + x) * 4;
          px[idx] = (x * 12) % 256;
          px[idx + 1] = (y * 12) % 256;
          px[idx + 2] = 128;
          px[idx + 3] = 255;
        }
      }
      final pattern = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 20,
        options: const ConvertOptions(
          gridWidth: 10,
          gridHeight: 10,
          dither: false,
          removeBackground: true,
        ),
      );
      expect(pattern.emptyCells, 0);
    });

    test('容差生效：容差 0 时只有完全同色被抠', () {
      // 白底 + 近白（250,250,250）方块：容差 0 抠不掉近白。
      final px = Uint8List(20 * 20 * 4);
      for (int y = 0; y < 20; y++) {
        for (int x = 0; x < 20; x++) {
          final idx = (y * 20 + x) * 4;
          final nearWhite = x >= 5 && x < 15 && y >= 5 && y < 15;
          px[idx] = nearWhite ? 250 : 255;
          px[idx + 1] = nearWhite ? 250 : 255;
          px[idx + 2] = nearWhite ? 250 : 255;
          px[idx + 3] = 255;
        }
      }
      final strict = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 20,
        options: const ConvertOptions(
          gridWidth: 10,
          gridHeight: 10,
          dither: false,
          removeBackground: true,
          bgTolerance: 0,
        ),
      );
      // 容差 0：只有纯白被抠。近白方块内部（整格都是 250）保留，
      // 边缘格（与白色混合）因平均 alpha 低于阈值变空格——符合预期。
      final interior = strict.cellAt(5, 5);
      expect(interior, isNotNull);

      final loose = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 20,
        options: const ConvertOptions(
          gridWidth: 10,
          gridHeight: 10,
          dither: false,
          removeBackground: true,
          bgTolerance: 32,
        ),
      );
      // 容差 32 时近白方块内部也被抠掉。
      expect(loose.cellAt(5, 5), isNull);
    });
  });

  group('项目持久化：空格 RLE', () {
    test('空格编码为空字符串色号，往返一致', () {
      final red = BeadPalette.byCode['D1']!;
      final pattern = BeadPattern(
        width: 3,
        height: 1,
        cells: [red, null, red],
        counts: const [],
      );
      final project = SavedProject.fromPattern(
        id: 't1',
        name: '空格测试',
        pattern: pattern,
      );
      expect(project.cellCodes, ['D1', '', 'D1']);
      final json = project.toJsonString();
      final restored = SavedProject.tryParseJson(json)!.toPattern()!;
      expect(restored.cellAt(0, 0)!.code, 'D1');
      expect(restored.cellAt(1, 0), isNull);
      expect(restored.cellAt(2, 0)!.code, 'D1');
      expect(restored.totalBeads, 2);
    });

    test('旧项目（无空格字段）照常打开', () {
      final project = SavedProject(
        id: 'old',
        name: '旧项目',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        width: 1,
        height: 1,
        cellCodes: ['A1'],
      );
      final pattern = project.toPattern()!;
      expect(pattern.cellAt(0, 0)!.code, 'A1');
      expect(project.removeBackground, false);
    });
  });

  group('EditorState 手动擦成空格', () {
    test('eraseToEmpty 置空格子并可撤销', () async {
      final state = EditorState();
      addTearDown(state.dispose);
      // 编码真实 PNG（loadImage 需要可解码的图片字节）。
      final src = img.Image(width: 32, height: 32);
      for (final p in src) {
        p.r = 220;
        p.g = 30;
        p.b = 40;
        p.a = 255;
      }
      await state.loadImage(
          Uint8List.fromList(img.encodePng(src)), 'red.png');
      final p0 = state.pattern!;
      expect(p0.cellAt(0, 0), isNotNull);

      state.eraseToEmpty(0, 0);
      final p1 = state.pattern!;
      expect(p1.cellAt(0, 0), isNull);
      expect(p1.totalBeads, p0.totalBeads - 1);
      expect(state.manualEdits['0,0'], '');

      state.undo();
      expect(state.pattern!.cellAt(0, 0), isNotNull);
      expect(state.manualEdits['0,0'], isNull);
    });

    test('擦成空格后重转：编辑保留', () async {
      final state = EditorState();
      addTearDown(state.dispose);
      final src = img.Image(width: 32, height: 32);
      for (final p in src) {
        p.r = 220;
        p.g = 30;
        p.b = 40;
        p.a = 255;
      }
      await state.loadImage(
          Uint8List.fromList(img.encodePng(src)), 'red.png');
      state.eraseToEmpty(2, 2);
      expect(state.pattern!.cellAt(2, 2), isNull);
      // 重转后手动编辑仍保留（坐标有效）。
      await state.reconvert();
      expect(state.pattern!.cellAt(2, 2), isNull);
    });
  });
}
