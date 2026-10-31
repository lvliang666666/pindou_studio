import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pindou_studio/core/converter.dart';
import 'package:pindou_studio/core/palette.dart';

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

/// 构造左右两半不同颜色的图像。
Uint8List halfImage(int w, int h, int leftRGB, int rightRGB) {
  final px = Uint8List(w * h * 4);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final rgb = x < w ~/ 2 ? leftRGB : rightRGB;
      final idx = (y * w + x) * 4;
      px[idx] = (rgb >> 16) & 0xFF;
      px[idx + 1] = (rgb >> 8) & 0xFF;
      px[idx + 2] = rgb & 0xFF;
      px[idx + 3] = 255;
    }
  }
  return px;
}

void main() {
  group('BeadPalette', () {
    test('色卡非空且编号唯一', () {
      expect(BeadPalette.colors, isNotEmpty);
      expect(BeadPalette.colors.length, greaterThanOrEqualTo(80));
      final codes = BeadPalette.colors.map((c) => c.code).toSet();
      expect(codes.length, BeadPalette.colors.length);
    });

    test('nearest 纯色精确命中', () {
      // 色卡中的颜色应精确返回自身。
      for (final c in BeadPalette.colors.take(20)) {
        expect(BeadPalette.nearest(c.red, c.green, c.blue), same(c));
      }
    });

    test('nearest 黑白两端正确', () {
      expect(BeadPalette.nearest(0, 0, 0).group, anyOf('黑色', '灰色'));
      expect(BeadPalette.nearest(255, 255, 255).group, '白色');
      expect(BeadPalette.nearest(255, 0, 0).group, '红色');
      expect(BeadPalette.nearest(0, 0, 255).group, '蓝色');
    });
  });

  group('BeadConverter 降采样', () {
    test('输出网格尺寸正确', () {
      final pattern = BeadConverter.convert(
        pixels: solidImage(100, 80, 255, 0, 0),
        srcWidth: 100,
        srcHeight: 80,
        options: const ConvertOptions(gridWidth: 29, gridHeight: 29),
      );
      expect(pattern.width, 29);
      expect(pattern.height, 29);
      expect(pattern.cells.length, 29 * 29);
      expect(pattern.totalBeads, 29 * 29);
    });

    test('纯色图整体映射为同一颜色', () {
      final pattern = BeadConverter.convert(
        pixels: solidImage(50, 50, 220, 30, 40), // 接近 D1 正红
        srcWidth: 50,
        srcHeight: 50,
        options: const ConvertOptions(gridWidth: 10, gridHeight: 10, dither: false),
      );
      expect(pattern.colorCount, 1);
      expect(pattern.cells.every((c) => c?.code == 'D1'), isTrue);
      expect(pattern.counts.single.count, 100);
    });

    test('左右分色图正确分区', () {
      final pattern = BeadConverter.convert(
        pixels: halfImage(100, 20, 0xFF0000, 0x0000FF),
        srcWidth: 100,
        srcHeight: 20,
        options: const ConvertOptions(gridWidth: 10, gridHeight: 4, dither: false),
      );
      // 左半应为红色系，右半应为蓝色系。
      for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 5; x++) {
          expect(pattern.cellAt(x, y)!.group, '红色');
        }
        for (int x = 5; x < 10; x++) {
          expect(pattern.cellAt(x, y)!.group, '蓝色');
        }
      }
    });
  });

  group('BeadConverter 量化与抖动', () {
    test('无抖动时纯色图不受抖动影响', () {
      final px = solidImage(20, 20, 245, 130, 30); // E1 橙色
      final noDither = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 20,
        options: const ConvertOptions(gridWidth: 5, gridHeight: 5, dither: false),
      );
      expect(noDither.colorCount, 1);
      expect(noDither.cells.first?.code, 'E1');
    });

    test('抖动开启时纯色图仍应基本保持原色', () {
      // 纯色图误差为 0，抖动不应改变结果。
      final px = solidImage(20, 20, 245, 130, 30);
      final dithered = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 20,
        options: const ConvertOptions(gridWidth: 5, gridHeight: 5, dither: true),
      );
      expect(dithered.colorCount, 1);
      expect(dithered.cells.first?.code, 'E1');
    });

    test('渐变图抖动后颜色种类不少于无抖动', () {
      // 构造水平渐变图。
      final w = 64, h = 8;
      final px = Uint8List(w * h * 4);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final idx = (y * w + x) * 4;
          px[idx] = x * 4;
          px[idx + 1] = 128;
          px[idx + 2] = 255 - x * 4;
          px[idx + 3] = 255;
        }
      }
      final noDither = BeadConverter.convert(
        pixels: px,
        srcWidth: w,
        srcHeight: h,
        options: const ConvertOptions(gridWidth: 32, gridHeight: 4, dither: false),
      );
      final dithered = BeadConverter.convert(
        pixels: px,
        srcWidth: w,
        srcHeight: h,
        options: const ConvertOptions(gridWidth: 32, gridHeight: 4, dither: true),
      );
      expect(dithered.colorCount, greaterThanOrEqualTo(noDither.colorCount));
    });
  });

  group('BeadConverter 亮度对比度', () {
    test('亮度提升使暗图变亮', () {
      final dark = solidImage(10, 10, 40, 40, 40);
      final bright = BeadConverter.convert(
        pixels: dark,
        srcWidth: 10,
        srcHeight: 10,
        options: const ConvertOptions(
          gridWidth: 5, gridHeight: 5, dither: false, brightness: 50),
      );
      final normal = BeadConverter.convert(
        pixels: dark,
        srcWidth: 10,
        srcHeight: 10,
        options: const ConvertOptions(gridWidth: 5, gridHeight: 5, dither: false),
      );
      double avgLuma(BeadPattern p) => p.counts.fold<double>(
          0, (s, c) => s + (0.299 * c.color.red + 0.587 * c.color.green + 0.114 * c.color.blue) * c.count) / p.totalBeads;
      expect(avgLuma(bright), greaterThan(avgLuma(normal)));
    });

    test('对比度提升扩大明暗差', () {
      // 左暗右亮。
      final px = halfImage(20, 10, 0x505050, 0xA0A0A0);
      final high = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 10,
        options: const ConvertOptions(
          gridWidth: 4, gridHeight: 2, dither: false, contrast: 80),
      );
      final low = BeadConverter.convert(
        pixels: px,
        srcWidth: 20,
        srcHeight: 10,
        options: const ConvertOptions(
          gridWidth: 4, gridHeight: 2, dither: false, contrast: -80),
      );
      // 高对比度下明暗差应更极端：最亮格与最暗格的亮度差更大。
      double spread(BeadPattern p) {
        double minL = 255, maxL = 0;
        for (final c in p.cells) {
          final l = 0.299 * c!.red + 0.587 * c.green + 0.114 * c.blue;
          if (l < minL) minL = l;
          if (l > maxL) maxL = l;
        }
        return maxL - minL;
      }
      expect(spread(high), greaterThanOrEqualTo(spread(low)));
    });
  });

  group('BeadConverter 颜色限制', () {
    test('colorLimit 限制颜色种类数', () {
      final px = halfImage(100, 20, 0xFF0000, 0x00FF00);
      final limited = BeadConverter.convert(
        pixels: px,
        srcWidth: 100,
        srcHeight: 20,
        options: const ConvertOptions(
          gridWidth: 10, gridHeight: 4, dither: false, colorLimit: 1),
      );
      expect(limited.colorCount, 1);
    });

    test('colorLimit=0 不限制', () {
      final px = halfImage(100, 20, 0xFF0000, 0x00FF00);
      final unlimited = BeadConverter.convert(
        pixels: px,
        srcWidth: 100,
        srcHeight: 20,
        options: const ConvertOptions(gridWidth: 10, gridHeight: 4, dither: false),
      );
      expect(unlimited.colorCount, 2);
    });
  });

  group('BeadPattern 统计', () {
    test('counts 总和等于总豆数', () {
      final pattern = BeadConverter.convert(
        pixels: halfImage(100, 20, 0xFF0000, 0x0000FF),
        srcWidth: 100,
        srcHeight: 20,
        options: const ConvertOptions(gridWidth: 12, gridHeight: 8, dither: true),
      );
      final sum = pattern.counts.fold<int>(0, (s, c) => s + c.count);
      expect(sum, pattern.totalBeads);
    });

    test('counts 按数量降序排列', () {
      final pattern = BeadConverter.convert(
        pixels: halfImage(100, 20, 0xFF0000, 0x0000FF),
        srcWidth: 100,
        srcHeight: 20,
        options: const ConvertOptions(gridWidth: 12, gridHeight: 8, dither: false),
      );
      for (int i = 1; i < pattern.counts.length; i++) {
        expect(
          pattern.counts[i - 1].count,
          greaterThanOrEqualTo(pattern.counts[i].count),
        );
      }
    });

    test('boardCount 底板数计算', () {
      // 29x29 -> 1 块；30x30 -> 4 块；58x29 -> 2 块。
      final px = solidImage(60, 60, 255, 255, 255);
      final p1 = BeadConverter.convert(
        pixels: px, srcWidth: 60, srcHeight: 60,
        options: const ConvertOptions(gridWidth: 29, gridHeight: 29, dither: false));
      expect(p1.boardCount, 1);
      final p2 = BeadConverter.convert(
        pixels: px, srcWidth: 60, srcHeight: 60,
        options: const ConvertOptions(gridWidth: 30, gridHeight: 30, dither: false));
      expect(p2.boardCount, 4);
      final p3 = BeadConverter.convert(
        pixels: px, srcWidth: 60, srcHeight: 60,
        options: const ConvertOptions(gridWidth: 58, gridHeight: 29, dither: false));
      expect(p3.boardCount, 2);
    });
  });
}
