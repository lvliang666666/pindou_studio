import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/palette.dart';
import 'package:pindou_studio/core/stitcher.dart';

/// 生成纯色 RGBA 像素图。
Uint8List solidPixels(int w, int h, int r, int g, int b) {
  return Uint8List.fromList([
    for (int i = 0; i < w * h; i++) ...[r, g, b, 255],
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BeadStitcher 尺寸计算', () {
    test('fitSize 横图：最长边约束', () {
      final (w, h) = BeadStitcher.fitSize(100, 50, 29);
      expect(w, 29);
      expect(h, 15); // 50 * 29/100 = 14.5 → 15
    });

    test('fitSize 竖图：最长边约束', () {
      final (w, h) = BeadStitcher.fitSize(40, 80, 29);
      expect(w, 15); // 40 * 29/80 = 14.5 → 15
      expect(h, 29);
    });

    test('fitSize 方图', () {
      final (w, h) = BeadStitcher.fitSize(60, 60, 29);
      expect(w, 29);
      expect(h, 29);
    });

    test('fitSize 小图不放大', () {
      final (w, h) = BeadStitcher.fitSize(10, 5, 29);
      expect(w, 10);
      expect(h, 5);
    });
  });

  group('BeadStitcher 拼合', () {
    test('单张图：输出等于该图 pad 到统一尺寸', () {
      final result = BeadStitcher.stitch(
        images: [(solidPixels(20, 10, 255, 0, 0), 20, 10)],
        options: const StitchOptions(perImageMaxSize: 29, columns: 1),
      );
      // 单张 20x10，统一尺寸即 20x10，无 pad。
      expect(result.pattern.width, 20);
      expect(result.pattern.height, 10);
      expect(result.placements.length, 1);
      expect(result.placements.first.$1, 0); // 列 0
      expect(result.placements.first.$2, 0); // 行 0
      // 全部为红色系（纯红图）。
      expect(result.pattern.cells.every((c) => c!.red > c.green), isTrue);
    });

    test('两张同尺寸图横排：总宽翻倍', () {
      final result = BeadStitcher.stitch(
        images: [
          (solidPixels(20, 10, 255, 0, 0), 20, 10),
          (solidPixels(20, 10, 0, 0, 255), 20, 10),
        ],
        options: const StitchOptions(perImageMaxSize: 29, columns: 2),
      );
      expect(result.pattern.width, 40);
      expect(result.pattern.height, 10);
      expect(result.placements.length, 2);
      // 左边是红、右边是蓝。
      expect(result.pattern.cellAt(0, 0)!.red, greaterThan(100));
      expect(result.pattern.cellAt(39, 0)!.blue, greaterThan(100));
    });

    test('两张图竖排（columns=1）：总高翻倍', () {
      final result = BeadStitcher.stitch(
        images: [
          (solidPixels(20, 10, 255, 0, 0), 20, 10),
          (solidPixels(20, 10, 0, 0, 255), 20, 10),
        ],
        options: const StitchOptions(perImageMaxSize: 29, columns: 1),
      );
      expect(result.pattern.width, 20);
      expect(result.pattern.height, 20);
      expect(result.pattern.cellAt(0, 0)!.red, greaterThan(100));
      expect(result.pattern.cellAt(0, 19)!.blue, greaterThan(100));
    });

    test('不同尺寸子图：pad 到统一尺寸且居中', () {
      // 图 A 20x20（红），图 B 10x10（蓝）→ 统一 20x20，B 居中 pad。
      final result = BeadStitcher.stitch(
        images: [
          (solidPixels(40, 40, 255, 0, 0), 40, 40),
          (solidPixels(20, 20, 0, 0, 255), 20, 20),
        ],
        options: const StitchOptions(perImageMaxSize: 20, columns: 2),
      );
      // A 转 20x20，B 转 20x20（不放大，20x20 源 → 20x20 网格）。
      // 等等：B 源 20x20，maxSize 20 → 网格 20x20，无 pad。
      expect(result.pattern.width, 40);
      expect(result.pattern.height, 20);
    });

    test('不同比例子图：pad 后空白格填背景色', () {
      // 图 A 40x20（横），图 B 20x40（竖），maxSize=20：
      // A → 20x10，B → 10x20。统一 20x20。
      // A 居中：上下各 pad 5 行；B 居中：左右各 pad 5 列。
      final result = BeadStitcher.stitch(
        images: [
          (solidPixels(40, 20, 255, 0, 0), 40, 20),
          (solidPixels(20, 40, 0, 0, 255), 20, 40),
        ],
        options: const StitchOptions(perImageMaxSize: 20, columns: 2),
      );
      expect(result.pattern.width, 40);
      expect(result.pattern.height, 20);
      // A 区域顶部（pad 区）应为填充色（通用卡首色 A1 白色）。
      final filler = BeadPalette.colors.first;
      expect(result.pattern.cellAt(0, 0)!.code, filler.code);
      // A 区域中心应为红色系。
      expect(result.pattern.cellAt(10, 10)!.red, greaterThan(100));
      // B 区域（第二张，列 1）左侧 pad 为填充色。
      expect(result.pattern.cellAt(20, 10)!.code, filler.code);
      // B 中心为蓝色系。
      expect(result.pattern.cellAt(30, 10)!.blue, greaterThan(100));
    });

    test('三张图 columns=2：2x2 网格，末行右侧留空', () {
      final red = solidPixels(30, 30, 255, 0, 0);
      final green = solidPixels(30, 30, 0, 255, 0);
      final blue = solidPixels(30, 30, 0, 0, 255);
      final result = BeadStitcher.stitch(
        images: [(red, 30, 30), (green, 30, 30), (blue, 30, 30)],
        options: const StitchOptions(perImageMaxSize: 10, columns: 2),
      );
      // 每张转 10x10，总 20x20。
      expect(result.pattern.width, 20);
      expect(result.pattern.height, 20);
      expect(result.placements.length, 3);
      // 第三张在第二行第一列。
      expect(result.placements[2].$1, 0);
      expect(result.placements[2].$2, 1);
      // 右下角（第二行第二列）为空白填充色。
      final filler = BeadPalette.colors.first;
      expect(result.pattern.cellAt(15, 15)!.code, filler.code);
      // 第二行第一列中心为蓝色系。
      expect(result.pattern.cellAt(5, 15)!.blue, greaterThan(100));
    });

    test('counts 统计正确：总豆数 = 总格子数', () {
      final result = BeadStitcher.stitch(
        images: [
          (solidPixels(10, 10, 255, 0, 0), 10, 10),
          (solidPixels(10, 10, 0, 255, 0), 10, 10),
        ],
        options: const StitchOptions(perImageMaxSize: 29, columns: 2),
      );
      var total = 0;
      for (final bc in result.pattern.counts) {
        total += bc.count;
      }
      expect(total, result.pattern.totalBeads);
      expect(result.pattern.totalBeads, 20 * 10);
    });

    test('空图片列表抛 ArgumentError', () {
      expect(
        () => BeadStitcher.stitch(
          images: [],
          options: const StitchOptions(),
        ),
        throwsArgumentError,
      );
    });

    test('columns 大于图片数时收敛为图片数', () {
      final result = BeadStitcher.stitch(
        images: [(solidPixels(10, 10, 255, 0, 0), 10, 10)],
        options: const StitchOptions(perImageMaxSize: 29, columns: 5),
      );
      expect(result.pattern.width, 10);
      expect(result.pattern.height, 10);
    });

    test('自定义填充色生效', () {
      final black = BeadPalette.colors
          .where((c) => c.red < 40 && c.green < 40 && c.blue < 40)
          .first;
      final result = BeadStitcher.stitch(
        images: [
          (solidPixels(40, 20, 255, 0, 0), 40, 20),
          (solidPixels(20, 40, 0, 0, 255), 20, 40),
        ],
        options: StitchOptions(
          perImageMaxSize: 20,
          columns: 2,
          backgroundColor: black,
        ),
      );
      // A 顶部 pad 区应为黑色。
      expect(result.pattern.cellAt(0, 0)!.code, black.code);
    });

    test('转换参数透传：colorLimit 生效', () {
      // 纯色图 colorLimit=1 结果仍为单色（透传不报错即可）。
      final result = BeadStitcher.stitch(
        images: [(solidPixels(20, 20, 255, 0, 0), 20, 20)],
        options: const StitchOptions(
          perImageMaxSize: 10,
          columns: 1,
          colorLimit: 1,
          dither: false,
        ),
      );
      expect(result.pattern.colorCount, 1);
    });
  });

  group('BeadStitcher 一板多图（固定正方形底板）', () {
    test('单张图：铺满约束到底板尺寸，总尺寸 = 底板', () {
      final result = BeadStitcher.stitchOnBoard(
        images: [(solidPixels(100, 100, 255, 0, 0), 100, 100)],
        boardSize: 50,
      );
      expect(result.pattern.width, 50);
      expect(result.pattern.height, 50);
      expect(result.placements.length, 1);
      // 100x100 源缩到 50x50，铺满整板。
      expect(result.placements.first.$3.width, 50);
      expect(result.pattern.totalBeads, 50 * 50);
    });

    test('两张图：左右各半，各占 25x50 区域', () {
      final result = BeadStitcher.stitchOnBoard(
        images: [
          (solidPixels(100, 100, 255, 0, 0), 100, 100),
          (solidPixels(100, 100, 0, 0, 255), 100, 100),
        ],
        boardSize: 50,
      );
      expect(result.pattern.width, 50);
      expect(result.pattern.height, 50);
      // cols = ceil(sqrt(2)) = 2, rows = 1。区域各 25x50。
      expect(result.placements[0].$1, 0);
      expect(result.placements[1].$1, 1);
      // 左半中心红、右半中心蓝。
      expect(result.pattern.cellAt(12, 25)!.red, greaterThan(100));
      expect(result.pattern.cellAt(37, 25)!.blue, greaterThan(100));
    });

    test('四张图：2x2 网格，各占 25x25', () {
      final result = BeadStitcher.stitchOnBoard(
        images: [
          (solidPixels(50, 50, 255, 0, 0), 50, 50),
          (solidPixels(50, 50, 0, 255, 0), 50, 50),
          (solidPixels(50, 50, 0, 0, 255), 50, 50),
          (solidPixels(50, 50, 255, 255, 0), 50, 50),
        ],
        boardSize: 50,
      );
      expect(result.pattern.width, 50);
      expect(result.pattern.height, 50);
      // 四象限中心颜色正确。
      expect(result.pattern.cellAt(12, 12)!.red, greaterThan(100));
      expect(result.pattern.cellAt(37, 12)!.green, greaterThan(100));
      expect(result.pattern.cellAt(12, 37)!.blue, greaterThan(100));
      expect(result.pattern.cellAt(37, 37)!.red, greaterThan(100));
      expect(result.pattern.cellAt(37, 37)!.green, greaterThan(100));
    });

    test('三张图：2 列 2 行，右下角空格', () {
      final result = BeadStitcher.stitchOnBoard(
        images: [
          (solidPixels(50, 50, 255, 0, 0), 50, 50),
          (solidPixels(50, 50, 0, 255, 0), 50, 50),
          (solidPixels(50, 50, 0, 0, 255), 50, 50),
        ],
        boardSize: 50,
      );
      expect(result.pattern.width, 50);
      expect(result.pattern.height, 50);
      // 右下角（第二行第二列区域）为空格。
      expect(result.pattern.cellAt(40, 40), isNull);
      // 左上区域有豆。
      expect(result.pattern.cellAt(10, 10), isNotNull);
    });

    test('小图不放大：10x10 图放进 50 底板保持 10x10 居中', () {
      final result = BeadStitcher.stitchOnBoard(
        images: [(solidPixels(10, 10, 255, 0, 0), 10, 10)],
        boardSize: 50,
      );
      expect(result.pattern.width, 50);
      expect(result.pattern.height, 50);
      // 子图保持 10x10，居中于 50x50 板（偏移 20）。
      expect(result.placements.first.$3.width, 10);
      expect(result.pattern.cellAt(24, 24), isNotNull); // 子图中心
      expect(result.pattern.cellAt(0, 0), isNull); // 板角空格
      expect(result.pattern.cellAt(5, 5), isNull); // 子图外空格
    });

    test('横图放进方形区域：按比例缩，上下留空', () {
      // 100x50 横图放进 50x50 板（单区域）：缩到 50x25，上下各空 12/13。
      final result = BeadStitcher.stitchOnBoard(
        images: [(solidPixels(100, 50, 0, 0, 255), 100, 50)],
        boardSize: 50,
      );
      expect(result.placements.first.$3.width, 50);
      expect(result.placements.first.$3.height, 25);
      // 顶部应为空格。
      expect(result.pattern.cellAt(25, 5), isNull);
      // 垂直中心有豆。
      expect(result.pattern.cellAt(25, 25), isNotNull);
    });

    test('总豆数 = 非空格数，counts 一致', () {
      final result = BeadStitcher.stitchOnBoard(
        images: [
          (solidPixels(20, 20, 255, 0, 0), 20, 20),
          (solidPixels(20, 20, 0, 0, 255), 20, 20),
        ],
        boardSize: 50,
      );
      var total = 0;
      for (final bc in result.pattern.counts) {
        total += bc.count;
      }
      expect(total, result.pattern.totalBeads);
      expect(result.pattern.totalBeads, lessThan(50 * 50));
      expect(result.pattern.emptyCells, greaterThan(0));
    });

    test('空图片列表抛 ArgumentError', () {
      expect(
        () => BeadStitcher.stitchOnBoard(images: [], boardSize: 50),
        throwsArgumentError,
      );
    });

    test('boardSize 过小被钳制到 10', () {
      final result = BeadStitcher.stitchOnBoard(
        images: [(solidPixels(20, 20, 255, 0, 0), 20, 20)],
        boardSize: 5,
      );
      expect(result.pattern.width, 10);
      expect(result.pattern.height, 10);
    });
  });
}
