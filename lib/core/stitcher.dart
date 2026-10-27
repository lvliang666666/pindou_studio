/// 多图拼合引擎：多张图片合成一张拼豆图纸。
///
/// 纯 Dart 实现，无 UI 依赖，便于单元测试。
/// 处理流程：
/// 1. 每张图按「单张最长边」约束独立转换（复用 [BeadConverter] 全参数）
/// 2. 各子图纸 pad 到统一网格尺寸（居中，空白格填背景色）
/// 3. 按「每行张数」网格拼合为一张 [BeadPattern]
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'converter.dart';
import 'palette.dart';

/// 拼合参数。
class StitchOptions {
  const StitchOptions({
    this.perImageMaxSize = 29,
    this.columns = 2,
    this.dither = true,
    this.brightness = 0,
    this.contrast = 0,
    this.colorLimit = 0,
    this.backgroundColor,
  });

  /// 单张图转换后的最长边（豆数）。每张图按原图比例缩到该约束内。
  final int perImageMaxSize;

  /// 每行放置的子图数量（最后一张不足时右侧留空）。
  final int columns;

  /// 传递给 [BeadConverter] 的转换参数。
  final bool dither;
  final int brightness;
  final int contrast;
  final int colorLimit;

  /// 拼合空白区填充色（null = 用当前色卡第一个颜色，通常为白色）。
  final BeadColor? backgroundColor;

  StitchOptions copyWith({
    int? perImageMaxSize,
    int? columns,
    bool? dither,
    int? brightness,
    int? contrast,
    int? colorLimit,
    BeadColor? backgroundColor,
  }) {
    return StitchOptions(
      perImageMaxSize: perImageMaxSize ?? this.perImageMaxSize,
      columns: columns ?? this.columns,
      dither: dither ?? this.dither,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      colorLimit: colorLimit ?? this.colorLimit,
      backgroundColor: backgroundColor ?? this.backgroundColor,
    );
  }
}

/// 拼合结果：图纸 + 各子图在成品中的位置（预览/说明用）。
class StitchResult {
  const StitchResult({
    required this.pattern,
    required this.placements,
  });

  /// 拼合后的完整图纸。
  final BeadPattern pattern;

  /// 各子图位置：(列索引, 行索引, 子图纸)。行优先，与输入顺序一致。
  final List<(int, int, BeadPattern)> placements;
}

/// 拼合引擎。
class BeadStitcher {
  BeadStitcher._();

  /// 将多张 RGBA 像素图拼合为一张图纸。
  ///
  /// [images] 为 (RGBA 像素, 宽, 高) 列表，至少 1 张。
  /// [StitchOptions.columns] 至少为 1。
  ///
  /// 布局规则：
  /// - 每张图独立转换为不超过 [StitchOptions.perImageMaxSize] 的网格
  ///   （保持原图宽高比，短边按比例缩小，最小 1）
  /// - 所有子图 pad 到统一尺寸（取各子图宽/高的最大值，居中放置）
  /// - 按 [StitchOptions.columns] 列网格排列，行数 = ceil(n / columns)
  /// - 总尺寸 = 统一尺寸 x 列数/行数（末行不满时右侧留空白格）
  static StitchResult stitch({
    required List<(Uint8List, int, int)> images,
    required StitchOptions options,
  }) {
    if (images.isEmpty) {
      throw ArgumentError('至少需要一张图片');
    }
    final cols = options.columns.clamp(1, images.length);
    final maxSize = options.perImageMaxSize.clamp(1, 500);

    // 1. 逐张独立转换（保持比例，约束最长边）。
    final converted = <BeadPattern>[];
    for (final (pixels, w, h) in images) {
      final (gw, gh) = _fitSize(w, h, maxSize);
      final pattern = BeadConverter.convert(
        pixels: pixels,
        srcWidth: w,
        srcHeight: h,
        options: ConvertOptions(
          gridWidth: gw,
          gridHeight: gh,
          dither: options.dither,
          brightness: options.brightness,
          contrast: options.contrast,
          colorLimit: options.colorLimit,
        ),
      );
      converted.add(pattern);
    }

    // 2. 统一子图尺寸（取最大宽/高），各自居中 pad。
    final cellW = converted.map((p) => p.width).reduce(math.max);
    final cellH = converted.map((p) => p.height).reduce(math.max);
    final filler = options.backgroundColor ?? BeadPalette.colors.first;
    final cellsList = [
      for (final p in converted) _padCentered(p, cellW, cellH, filler),
    ];

    // 3. 网格拼合。
    final rows = (converted.length + cols - 1) ~/ cols;
    final totalW = cellW * cols;
    final totalH = cellH * rows;
    final cells = List<BeadColor>.filled(totalW * totalH, filler);
    for (var i = 0; i < cellsList.length; i++) {
      final cx = i % cols;
      final cy = i ~/ cols;
      final sub = cellsList[i];
      for (int y = 0; y < cellH; y++) {
        for (int x = 0; x < cellW; x++) {
          cells[(cy * cellH + y) * totalW + cx * cellW + x] =
              sub[y * cellW + x];
        }
      }
    }

    return StitchResult(
      pattern: _buildPattern(cells, totalW, totalH),
      placements: [
        for (var i = 0; i < converted.length; i++)
          (i % cols, i ~/ cols, converted[i]),
      ],
    );
  }

  /// 按原图比例计算目标网格尺寸：最长边 = maxSize，短边按比例（最小 1）。
  /// 公开供单元测试（stitchTestFitSize 为测试别名）。
  static (int, int) _fitSize(int srcW, int srcH, int maxSize) => fitSize(srcW, srcH, maxSize);

  /// 按原图比例计算目标网格尺寸（公开版本，测试与预览共用）。
  static (int, int) fitSize(int srcW, int srcH, int maxSize) {
    if (srcW <= 0 || srcH <= 0) return (1, 1);
    if (srcW >= srcH) {
      final w = srcW.clamp(1, maxSize);
      final h = (srcH * w / srcW).round().clamp(1, maxSize);
      return (w, h);
    }
    final h = srcH.clamp(1, maxSize);
    final w = (srcW * h / srcH).round().clamp(1, maxSize);
    return (w, h);
  }

  /// 子图居中 pad 到 cellW x cellH（空白填 filler）。
  static List<BeadColor> _padCentered(
    BeadPattern p,
    int cellW,
    int cellH,
    BeadColor filler,
  ) {
    final out = List<BeadColor>.filled(cellW * cellH, filler);
    final offX = (cellW - p.width) ~/ 2;
    final offY = (cellH - p.height) ~/ 2;
    for (int y = 0; y < p.height; y++) {
      for (int x = 0; x < p.width; x++) {
        out[(y + offY) * cellW + x + offX] = p.cellAt(x, y);
      }
    }
    return out;
  }

  /// 统计用量并生成图纸对象（与 BeadConverter._buildPattern 同规则）。
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
