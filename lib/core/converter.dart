/// 图片 -> 拼豆图纸 转换引擎。
///
/// 纯 Dart 实现，无 UI 依赖，便于单元测试。
/// 处理流程：
/// 1. 亮度/对比度调整（可选）
/// 2. 面积平均降采样到目标网格尺寸
/// 3. 颜色量化：逐像素匹配最近拼豆色（可选 Floyd-Steinberg 抖动）
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'palette.dart';

/// 转换参数。
class ConvertOptions {
  const ConvertOptions({
    required this.gridWidth,
    required this.gridHeight,
    this.dither = true,
    this.brightness = 0,
    this.contrast = 0,
    this.colorLimit = 0,
  });

  /// 目标网格宽度（豆子列数）。
  final int gridWidth;

  /// 目标网格高度（豆子行数）。
  final int gridHeight;

  /// 是否启用 Floyd-Steinberg 抖动。
  final bool dither;

  /// 亮度调整，范围 -100 ~ 100，0 为不变。
  final int brightness;

  /// 对比度调整，范围 -100 ~ 100，0 为不变。
  final int contrast;

  /// 限制使用的颜色数量上限（按使用频次保留最常用的 N 色）。
  /// 0 表示不限制。实际拼豆时颜色种类越少越省事。
  final int colorLimit;

  ConvertOptions copyWith({
    int? gridWidth,
    int? gridHeight,
    bool? dither,
    int? brightness,
    int? contrast,
    int? colorLimit,
  }) {
    return ConvertOptions(
      gridWidth: gridWidth ?? this.gridWidth,
      gridHeight: gridHeight ?? this.gridHeight,
      dither: dither ?? this.dither,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      colorLimit: colorLimit ?? this.colorLimit,
    );
  }
}

/// 转换结果：一张拼豆图纸。
class BeadPattern {
  const BeadPattern({
    required this.width,
    required this.height,
    required this.cells,
    required this.counts,
  });

  /// 网格宽度（列数）。
  final int width;

  /// 网格高度（行数）。
  final int height;

  /// 每格对应的拼豆颜色，按行优先排列，长度 = width * height。
  final List<BeadColor> cells;

  /// 各颜色用量（豆数），按数量降序。
  final List<BeadCount> counts;

  /// 总豆数。
  int get totalBeads => width * height;

  /// 使用的颜色种类数。
  int get colorCount => counts.length;

  /// 图纸所需底板数（29x29 标准底板，按覆盖面积向上取整）。
  int get boardCount {
    return ((width + 28) ~/ 29) * ((height + 28) ~/ 29);
  }

  /// 获取 (x, y) 处的颜色。
  BeadColor cellAt(int x, int y) => cells[y * width + x];
}

/// 单种颜色的用量统计。
class BeadCount {
  const BeadCount({required this.color, required this.count});

  final BeadColor color;
  final int count;
}

/// 转换引擎。
class BeadConverter {
  /// 将 RGBA 像素数据转换为拼豆图纸。
  ///
  /// [pixels] 为 RGBA 字节序列（每像素 4 字节），尺寸为 srcW x srcH。
  static BeadPattern convert({
    required Uint8List pixels,
    required int srcWidth,
    required int srcHeight,
    required ConvertOptions options,
  }) {
    final gw = options.gridWidth.clamp(1, srcWidth);
    final gh = options.gridHeight.clamp(1, srcHeight);

    // 1. 亮度/对比度调整（在源分辨率上做，避免降采样后失真放大）。
    var src = pixels;
    if (options.brightness != 0 || options.contrast != 0) {
      src = _adjustBrightnessContrast(
        pixels, options.brightness, options.contrast);
    }

    // 2. 面积平均降采样。
    final down = _downsample(src, srcWidth, srcHeight, gw, gh);

    // 3. 量化（可选抖动）。
    final cells = options.dither
        ? _quantizeDither(down, gw, gh)
        : _quantize(down, gw, gh);

    // 4. 颜色数量限制：按用量保留最常用的 N 色，其余并入最近色。
    final limited = options.colorLimit > 0
        ? _limitColors(cells, gw, gh, options.colorLimit)
        : cells;

    return _buildPattern(limited, gw, gh);
  }

  /// 亮度/对比度调整。
  static Uint8List _adjustBrightnessContrast(
    Uint8List pixels,
    int brightness,
    int contrast,
  ) {
    // 亮度：直接加减；对比度：以 128 为中心缩放。
    final b = brightness * 1.28; // -128 ~ 128
    final c = (contrast + 100) / 100; // 0 ~ 2
    final out = Uint8List(pixels.length);
    for (int i = 0; i < pixels.length; i += 4) {
      for (int ch = 0; ch < 3; ch++) {
        double v = pixels[i + ch] + b;
        v = (v - 128) * c + 128;
        out[i + ch] = v.clamp(0, 255).round();
      }
      out[i + 3] = pixels[i + 3];
    }
    return out;
  }

  /// 面积平均降采样：每个目标像素取源图中对应矩形区域的加权平均。
  /// 支持非整数缩放比（按重叠面积加权），避免摩尔纹与细节丢失。
  static Uint8List _downsample(
    Uint8List pixels,
    int srcW,
    int srcH,
    int dstW,
    int dstH,
  ) {
    final out = Uint8List(dstW * dstH * 4);
    final xRatio = srcW / dstW;
    final yRatio = srcH / dstH;

    for (int dy = 0; dy < dstH; dy++) {
      final sy0 = dy * yRatio;
      final sy1 = (dy + 1) * yRatio;
      for (int dx = 0; dx < dstW; dx++) {
        final sx0 = dx * xRatio;
        final sx1 = (dx + 1) * xRatio;
        double rSum = 0, gSum = 0, bSum = 0, aSum = 0, wSum = 0;

        final yStart = sy0.floor(), yEnd = sy1.ceil().clamp(0, srcH);
        final xStart = sx0.floor(), xEnd = sx1.ceil().clamp(0, srcW);
        for (int sy = yStart; sy < yEnd; sy++) {
          final wy = math.min(sy + 1, sy1) - math.max(sy, sy0);
          if (wy <= 0) continue;
          for (int sx = xStart; sx < xEnd; sx++) {
            final wx = math.min(sx + 1, sx1) - math.max(sx, sx0);
            if (wx <= 0) continue;
            final w = wx * wy;
            final idx = (sy * srcW + sx) * 4;
            final a = pixels[idx + 3] / 255.0;
            // 预乘 alpha 后平均，避免透明区域污染颜色。
            rSum += pixels[idx] * a * w;
            gSum += pixels[idx + 1] * a * w;
            bSum += pixels[idx + 2] * a * w;
            aSum += pixels[idx + 3] * w;
            wSum += w;
          }
        }
        final oIdx = (dy * dstW + dx) * 4;
        if (wSum > 0 && aSum > 0) {
          // avgA 为 0~255 的平均 alpha；rSum/wSum 是预乘平均，
          // 需除以 (avgA/255) 反预乘还原颜色。
          final avgA = aSum / wSum;
          final alphaRatio = avgA / 255.0;
          if (alphaRatio > 0.001) {
            out[oIdx] = (rSum / wSum / alphaRatio).clamp(0, 255).round();
            out[oIdx + 1] = (gSum / wSum / alphaRatio).clamp(0, 255).round();
            out[oIdx + 2] = (bSum / wSum / alphaRatio).clamp(0, 255).round();
          }
          out[oIdx + 3] = avgA.clamp(0, 255).round();
        }
      }
    }
    return out;
  }

  /// 最近色量化（无抖动）。
  static List<BeadColor> _quantize(Uint8List pixels, int w, int h) {
    final out = List<BeadColor>.filled(w * h, BeadPalette.colors.first);
    for (int i = 0, p = 0; i < out.length; i++, p += 4) {
      out[i] = BeadPalette.nearest(pixels[p], pixels[p + 1], pixels[p + 2]);
    }
    return out;
  }

  /// Floyd-Steinberg 抖动量化。
  static List<BeadColor> _quantizeDither(Uint8List pixels, int w, int h) {
    // 工作在浮点缓冲上传播误差。
    final buf = Float32List(w * h * 3);
    for (int i = 0, p = 0, q = 0; i < w * h; i++, p += 4, q += 3) {
      buf[q] = pixels[p].toDouble();
      buf[q + 1] = pixels[p + 1].toDouble();
      buf[q + 2] = pixels[p + 2].toDouble();
    }
    final out = List<BeadColor>.filled(w * h, BeadPalette.colors.first);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final q = (y * w + x) * 3;
        final r = buf[q].clamp(0, 255);
        final g = buf[q + 1].clamp(0, 255);
        final b = buf[q + 2].clamp(0, 255);
        final bead = BeadPalette.nearest(r.round(), g.round(), b.round());
        out[y * w + x] = bead;

        // 误差扩散。
        final er = r - bead.red, eg = g - bead.green, eb = b - bead.blue;
        void diffuse(int nx, int ny, double factor) {
          if (nx < 0 || nx >= w || ny < 0 || ny >= h) return;
          final nq = (ny * w + nx) * 3;
          buf[nq] += er * factor;
          buf[nq + 1] += eg * factor;
          buf[nq + 2] += eb * factor;
        }

        diffuse(x + 1, y, 7 / 16);
        diffuse(x - 1, y + 1, 3 / 16);
        diffuse(x, y + 1, 5 / 16);
        diffuse(x + 1, y + 1, 1 / 16);
      }
    }
    return out;
  }

  /// 限制颜色数量：保留用量最多的 N 色，其余格子替换为最接近的保留色。
  static List<BeadColor> _limitColors(
    List<BeadColor> cells,
    int w,
    int h,
    int limit,
  ) {
    final counts = <BeadColor, int>{};
    for (final c in cells) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    if (counts.length <= limit) return cells;

    final kept = (counts.keys.toList()
          ..sort((a, b) => counts[b]!.compareTo(counts[a]!)))
        .take(limit)
        .toSet();

    return [
      for (final c in cells)
        kept.contains(c) ? c : _nearestAmong(kept, c.red, c.green, c.blue),
    ];
  }

  static BeadColor _nearestAmong(Set<BeadColor> pool, int r, int g, int b) {
    BeadColor best = pool.first;
    double bestD = double.infinity;
    for (final c in pool) {
      final dr = c.red - r, dg = c.green - g, db = c.blue - b;
      final d = 2.0 * dr * dr + 4.0 * dg * dg + 3.0 * db * db;
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  /// 统计用量并生成图纸对象。
  static BeadPattern _buildPattern(List<BeadColor> cells, int w, int h) {
    final counts = <BeadColor, int>{};
    for (final c in cells) {
      counts[c] = (counts[c] ?? 0) + 1;
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.code.compareTo(b.key.code);
      });
    return BeadPattern(
      width: w,
      height: h,
      cells: List.unmodifiable(cells),
      counts: List.unmodifiable([
        for (final e in sorted) BeadCount(color: e.key, count: e.value),
      ]),
    );
  }
}
