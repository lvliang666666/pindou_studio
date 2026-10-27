/// 图片 -> 拼豆图纸 转换引擎。
///
/// 纯 Dart 实现，无 UI 依赖，便于单元测试。
/// 处理流程：
/// 1. 亮度/对比度调整（可选）
/// 2. 自动抠背景（可选）：flood fill 从边缘种子扩散，边缘检测
///    （Sobel 梯度）保护主体边界，只抠与边缘连通的背景区域
/// 3. 面积平均降采样到目标网格尺寸
/// 4. 颜色量化：逐像素匹配最近拼豆色（可选 Floyd-Steinberg 抖动）
library;

import 'dart:collection';
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
    this.removeBackground = false,
    this.bgTolerance = 32,
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

  /// 自动抠背景：flood fill 从边缘扩散抠掉与边缘连通的背景区域。
  final bool removeBackground;

  /// 抠背景容差（0~128）：与种子背景色的加权距离小于该值的像素视为背景。
  final int bgTolerance;

  ConvertOptions copyWith({
    int? gridWidth,
    int? gridHeight,
    bool? dither,
    int? brightness,
    int? contrast,
    int? colorLimit,
    bool? removeBackground,
    int? bgTolerance,
  }) {
    return ConvertOptions(
      gridWidth: gridWidth ?? this.gridWidth,
      gridHeight: gridHeight ?? this.gridHeight,
      dither: dither ?? this.dither,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      colorLimit: colorLimit ?? this.colorLimit,
      removeBackground: removeBackground ?? this.removeBackground,
      bgTolerance: bgTolerance ?? this.bgTolerance,
    );
  }
}

/// 转换结果：一张拼豆图纸。
///
/// 空格语义：cells 元素为 null 表示该格不放豆（底板留空）。
/// 抠背景/透明像素/手动擦除都会产生空格；counts/totalBeads 只统计实豆。
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
  /// null = 空格（不放豆，底板留空）。
  final List<BeadColor?> cells;

  /// 各颜色用量（豆数），按数量降序。不含空格。
  final List<BeadCount> counts;

  /// 总豆数（不含空格）。
  int get totalBeads => counts.fold(0, (s, bc) => s + bc.count);

  /// 空格数量。
  int get emptyCells {
    var n = 0;
    for (final c in cells) {
      if (c == null) n++;
    }
    return n;
  }

  /// 使用的颜色种类数。
  int get colorCount => counts.length;

  /// 图纸所需底板数（29x29 标准底板，按覆盖面积向上取整）。
  int get boardCount {
    return ((width + 28) ~/ 29) * ((height + 28) ~/ 29);
  }

  /// 获取 (x, y) 处的颜色；空格返回 null。
  BeadColor? cellAt(int x, int y) => cells[y * width + x];
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

    // 1.5 自动抠背景：flood fill 从边缘种子扩散，只抠与边缘连通的
    // 背景区域（Sobel 边缘检测保护主体边界）。在源分辨率上做，
    // 降采样的预乘 alpha 平均自然把"背景占比高"的格子 alpha 压低，
    // 与图片自带透明通道走同一条路。
    if (options.removeBackground) {
      src = _removeBackground(src, srcWidth, srcHeight, options.bgTolerance);
    }

    // 2. 面积平均降采样。
    final down = _downsample(src, srcWidth, srcHeight, gw, gh);

    // 3. 量化（可选抖动）。alpha 低于阈值的格子输出空格（null）。
    final cells = options.dither
        ? _quantizeDither(down, gw, gh)
        : _quantize(down, gw, gh);

    // 4. 颜色数量限制：按用量保留最常用的 N 色，其余并入最近色。
    final limited = options.colorLimit > 0
        ? _limitColors(cells, gw, gh, options.colorLimit)
        : cells;

    return _buildPattern(limited, gw, gh);
  }

  /// 抠背景容差对应的 alpha 阈值：格子平均 alpha 低于该值视为空格。
  /// 降采样后格子可能部分透明（主体边缘），alpha < 128 按空格处理。
  static const int emptyAlphaThreshold = 128;

  /// 自动抠背景：flood fill（种子填充）+ 边缘保护。
  ///
  /// 算法（比"全局颜色匹配"精细，能处理背景有轻微渐变/阴影的情况）：
  /// 1. Sobel 边缘检测：梯度大的像素（主体轮廓）视为屏障，flood fill
  ///    不越过它——即使主体颜色与背景接近，轮廓线也能挡住扩散。
  /// 2. 种子点：四角 + 四边中点共 8 个。每个种子各自代表"这里应该是
  ///    背景"；种子颜色即该区域的背景基准色。
  /// 3. BFS 扩散：从种子出发，相邻像素与**当前区域背景色**（种子色）
  ///    距离小于容差、且不是边缘像素时并入背景。区域背景色随扩散
  ///    缓慢更新（滑动平均），适应背景渐变。
  /// 4. 只有与边缘连通的背景被抠掉；主体内部的同色区域（如白脸里的
  ///    白色高光）不受影响——这是与全局颜色匹配的本质区别。
  ///
  /// [tolerance] 0~128：与背景色的加权距离阈值（内部放大到 0~255 尺度）。
  static Uint8List _removeBackground(
    Uint8List pixels,
    int w,
    int h,
    int tolerance,
  ) {
    if (w < 3 || h < 3) return pixels;
    final n = w * h;

    // ---- 1. 去噪 + Sobel 边缘检测 ----
    // 真实照片/JPEG 有噪声（±8/通道），原始 Sobel 会在噪声上产生
    // 假梯度（幅值可达 ~90），导致"满图都是边缘"——无主体守卫误触发、
    // 扩散屏障到处都是。先做 3x3 box blur 压噪，再检测边缘。
    // 模糊只用于边缘检测；flood fill 仍用原图颜色（保细节）。
    final blurred = _boxBlur3(pixels, w, h);
    final edge = _sobelMagnitude(blurred, w, h);
    // 边缘阈值：梯度幅值 > 该值的像素不参与扩散（屏障）。
    // 容差越大，边缘阈值越宽松（用户想要更激进的抠图时容忍越过弱边）。
    final edgeThreshold = 96.0 + tolerance * 1.2;

    // 无主体守卫：整图布满中等梯度（全幅渐变/纹理图，任何位置都有
    // 可见变化）时没有可辨识的主体边界，flood fill 会吞掉整张图，
    // 抠图无意义——原图返回（用户得到完整图纸而不是全空图纸）。
    // 用"弱边缘密度"判定：梯度 > 12 的像素占比超过 60% 视为无主体。
    // （去噪后真实照片的平坦区域梯度接近 0，不再误触发。）
    var edgeCount = 0;
    for (final m in edge) {
      if (m > 12) edgeCount++;
    }
    if (edgeCount > n * 0.6) return pixels;

    // ---- 2. 种子点：四角 + 四边中点 ----
    final seeds = <int>[
      0, // 左上
      w - 1, // 右上
      (h - 1) * w, // 左下
      n - 1, // 右下
      w ~/ 2, // 上中
      (h - 1) * w + w ~/ 2, // 下中
      (h ~/ 2) * w, // 左中
      (h ~/ 2) * w + w - 1, // 右中
    ];

    // 种子投票：主体可能紧贴边缘（如竖直色条顶到左边），此时部分种子
    // 落在主体上。对 8 个种子按颜色聚类（容差内归并），只保留最大簇的
    // 种子作为背景起点——落在主体上的种子被丢弃，防止主体被吃掉。
    final validSeeds = <int>[];
    {
      final seedColors = <(int, int, int)>[
        for (final s in seeds)
          (pixels[s * 4], pixels[s * 4 + 1], pixels[s * 4 + 2]),
      ];
      final voteTol2 = _toleranceToDistance2(math.max(tolerance, 24));
      var bestCluster = 0;
      (int, int, int)? bestColor;
      for (int i = 0; i < seedColors.length; i++) {
        var count = 0;
        for (int j = 0; j < seedColors.length; j++) {
          if (_colorDistance(seedColors[i], seedColors[j]) <= voteTol2) {
            count++;
          }
        }
        if (count > bestCluster) {
          bestCluster = count;
          bestColor = seedColors[i];
        }
      }
      if (bestColor != null && bestCluster >= 3) {
        for (int i = 0; i < seeds.length; i++) {
          if (_colorDistance(seedColors[i], bestColor) <= voteTol2) {
            validSeeds.add(seeds[i]);
          }
        }
      }
    }

    // ---- 3. BFS flood fill：从每个种子扩散 ----
    // isBg: 该像素属于背景（将被置透明）。
    final isBg = List<bool>.filled(n, false);
    // 每个种子独立扩散（种子色不同则区域不同，互不污染）。
    final tol2 = _toleranceToDistance2(tolerance);
    const maxDrift = 48; // 区域背景色最大漂移（适应渐变，防跑飞）。

    for (final seed in validSeeds) {
      final seedIdx = seed * 4;
      // 种子本身是边缘像素：跳过（不可信的起点）。
      if (edge[seed] > edgeThreshold) continue;
      var bgR = pixels[seedIdx].toDouble();
      var bgG = pixels[seedIdx + 1].toDouble();
      var bgB = pixels[seedIdx + 2].toDouble();
      var bgCount = 1;

      final queue = Queue<int>()..add(seed);
      final visited = List<bool>.filled(n, false);
      visited[seed] = true;

      while (queue.isNotEmpty) {
        final idx = queue.removeFirst();
        isBg[idx] = true;
        final p = idx * 4;

        // 滑动平均更新区域背景色（适应渐变）。
        bgCount++;
        final blend = 1.0 / bgCount.clamp(1, 200);
        bgR += (pixels[p] - bgR) * blend;
        bgG += (pixels[p + 1] - bgG) * blend;
        bgB += (pixels[p + 2] - bgB) * blend;

        final x = idx % w;
        final y = idx ~/ w;
        // 4 邻域扩散。
        for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
          final nIdx = ny * w + nx;
          if (visited[nIdx] || isBg[nIdx]) continue;
          // 边缘屏障：不越过主体轮廓。
          if (edge[nIdx] > edgeThreshold) continue;
          final np = nIdx * 4;
          // 与当前区域背景色的距离。
          final d = _colorDistance(
            (pixels[np], pixels[np + 1], pixels[np + 2]),
            (bgR.round(), bgG.round(), bgB.round()),
          );
          // 距离超限：不是背景（除非在漂移容忍内——渐变过渡带）。
          if (d > tol2) {
            // 渐变容忍：距离在 tol2 ~ tol2*2.5 之间且累计漂移未超限时，
            // 仍并入但更新背景色（缓慢跟随渐变）。
            if (d > tol2 * 2.5) continue;
            final drift = _colorDistance(
              (bgR.round(), bgG.round(), bgB.round()),
              (pixels[seedIdx], pixels[seedIdx + 1], pixels[seedIdx + 2]),
            );
            if (drift > maxDrift * maxDrift * 9) continue;
          }
          visited[nIdx] = true;
          queue.add(nIdx);
        }
      }
    }

    // ---- 4. 背景像素置透明 ----
    var bgTotal = 0;
    for (final b in isBg) {
      if (b) bgTotal++;
    }
    // 背景占比过低（<5%）：判定为误抠，放弃（保护纯色主体图）。
    if (bgTotal < n * 0.05) return pixels;

    final out = Uint8List.fromList(pixels);
    for (int i = 0; i < n; i++) {
      if (isBg[i]) out[i * 4 + 3] = 0;
    }
    return out;
  }

  /// Sobel 边缘检测：返回每像素的梯度幅值（灰度 + RGB 通道取最大）。
  static Float32List _sobelMagnitude(Uint8List pixels, int w, int h) {
    // 先转灰度。
    final gray = Float32List(w * h);
    for (int i = 0, p = 0; i < w * h; i++, p += 4) {
      gray[i] = 0.299 * pixels[p] + 0.587 * pixels[p + 1] + 0.114 * pixels[p + 2];
    }
    final mag = Float32List(w * h);
    for (int y = 1; y < h - 1; y++) {
      for (int x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final tl = gray[i - w - 1], t = gray[i - w], tr = gray[i - w + 1];
        final l = gray[i - 1], r = gray[i + 1];
        final bl = gray[i + w - 1], b = gray[i + w], br = gray[i + w + 1];
        // Sobel 算子（灰度）。
        final gx = (tr + 2 * r + br) - (tl + 2 * l + bl);
        final gy = (bl + 2 * b + br) - (tl + 2 * t + tr);
        // 彩色图还要考虑颜色突变（灰度相同但色相不同的边界）：
        // 用 RGB 分量分别 Sobel 取最大值。
        double maxC = gx * gx + gy * gy;
        for (int ch = 0; ch < 3; ch++) {
          final cTl = pixels[(i - w - 1) * 4 + ch].toDouble();
          final cT = pixels[(i - w) * 4 + ch].toDouble();
          final cTr = pixels[(i - w + 1) * 4 + ch].toDouble();
          final cL = pixels[(i - 1) * 4 + ch].toDouble();
          final cR = pixels[(i + 1) * 4 + ch].toDouble();
          final cBl = pixels[(i + w - 1) * 4 + ch].toDouble();
          final cB = pixels[(i + w) * 4 + ch].toDouble();
          final cBr = pixels[(i + w + 1) * 4 + ch].toDouble();
          final cgx = (cTr + 2 * cR + cBr) - (cTl + 2 * cL + cBl);
          final cgy = (cBl + 2 * cB + cBr) - (cTl + 2 * cT + cTr);
          final m = cgx * cgx + cgy * cgy;
          if (m > maxC) maxC = m;
        }
        mag[i] = math.sqrt(maxC);
      }
    }
    return mag;
  }

  /// 容差（0~128）转加权距离平方阈值。
  static int _toleranceToDistance2(int tolerance) {
    // 容差线性映射到每通道最大偏差，再转加权距离平方。
    // tolerance=32 时每通道约偏差 32，加权距离平方 ≈ 9*32² = 9216。
    final t = tolerance * 3;
    return t * t * 9;
  }

  /// 3x3 box blur（边缘检测前的去噪预处理）。
  /// 边界像素用 clamp 邻域；alpha 通道同样平滑（半透明边缘更稳定）。
  static Uint8List _boxBlur3(Uint8List pixels, int w, int h) {
    final out = Uint8List(pixels.length);
    for (int y = 0; y < h; y++) {
      final y0 = y == 0 ? 0 : y - 1;
      final y1 = y == h - 1 ? h - 1 : y + 1;
      for (int x = 0; x < w; x++) {
        final x0 = x == 0 ? 0 : x - 1;
        final x1 = x == w - 1 ? w - 1 : x + 1;
        final oIdx = (y * w + x) * 4;
        for (int ch = 0; ch < 4; ch++) {
          final sum = pixels[(y0 * w + x0) * 4 + ch] +
              pixels[(y0 * w + x) * 4 + ch] +
              pixels[(y0 * w + x1) * 4 + ch] +
              pixels[(y * w + x0) * 4 + ch] +
              pixels[oIdx + ch] +
              pixels[(y * w + x1) * 4 + ch] +
              pixels[(y1 * w + x0) * 4 + ch] +
              pixels[(y1 * w + x) * 4 + ch] +
              pixels[(y1 * w + x1) * 4 + ch];
          out[oIdx + ch] = (sum / 9).round();
        }
      }
    }
    return out;
  }

  /// 加权颜色距离平方（与量化权重一致：2r²+4g²+3b²）。
  static int _colorDistance((int, int, int) a, (int, int, int) b) {
    final dr = a.$1 - b.$1, dg = a.$2 - b.$2, db = a.$3 - b.$3;
    return 2 * dr * dr + 4 * dg * dg + 3 * db * db;
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

  /// 最近色量化（无抖动）。alpha 低于阈值的格子输出空格（null）。
  static List<BeadColor?> _quantize(Uint8List pixels, int w, int h) {
    final out = List<BeadColor?>.filled(w * h, BeadPalette.colors.first);
    for (int i = 0, p = 0; i < out.length; i++, p += 4) {
      if (pixels[p + 3] < emptyAlphaThreshold) {
        out[i] = null;
      } else {
        out[i] = BeadPalette.nearest(pixels[p], pixels[p + 1], pixels[p + 2]);
      }
    }
    return out;
  }

  /// Floyd-Steinberg 抖动量化。
  /// 空格（alpha 低于阈值）不参与误差扩散：不向邻居传播误差、
  /// 不接收邻居误差（背景格子保持干净，不被主体误差污染）。
  static List<BeadColor?> _quantizeDither(Uint8List pixels, int w, int h) {
    // 工作在浮点缓冲上传播误差。
    final buf = Float32List(w * h * 3);
    for (int i = 0, p = 0, q = 0; i < w * h; i++, p += 4, q += 3) {
      buf[q] = pixels[p].toDouble();
      buf[q + 1] = pixels[p + 1].toDouble();
      buf[q + 2] = pixels[p + 2].toDouble();
    }
    // 空格掩码：降采样后 alpha 低于阈值的格子。
    final isEmpty = List<bool>.filled(w * h, false);
    for (int i = 0, p = 3; i < w * h; i++, p += 4) {
      isEmpty[i] = pixels[p] < emptyAlphaThreshold;
    }
    final out = List<BeadColor?>.filled(w * h, BeadPalette.colors.first);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final idx = y * w + x;
        if (isEmpty[idx]) {
          out[idx] = null;
          continue; // 空格：不量化、不扩散误差。
        }
        final q = idx * 3;
        final r = buf[q].clamp(0, 255);
        final g = buf[q + 1].clamp(0, 255);
        final b = buf[q + 2].clamp(0, 255);
        final bead = BeadPalette.nearest(r.round(), g.round(), b.round());
        out[idx] = bead;

        // 误差扩散。
        final er = r - bead.red, eg = g - bead.green, eb = b - bead.blue;
        void diffuse(int nx, int ny, double factor) {
          if (nx < 0 || nx >= w || ny < 0 || ny >= h) return;
          if (isEmpty[ny * w + nx]) return; // 空格不接收误差。
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
  /// 空格（null）原样保留。
  static List<BeadColor?> _limitColors(
    List<BeadColor?> cells,
    int w,
    int h,
    int limit,
  ) {
    final counts = <BeadColor, int>{};
    for (final c in cells) {
      if (c == null) continue;
      counts[c] = (counts[c] ?? 0) + 1;
    }
    if (counts.length <= limit) return cells;

    final kept = (counts.keys.toList()
          ..sort((a, b) => counts[b]!.compareTo(counts[a]!)))
        .take(limit)
        .toSet();

    return [
      for (final c in cells)
        if (c == null)
          null
        else
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

  /// 统计用量并生成图纸对象。空格（null）不计入 counts。
  static BeadPattern _buildPattern(List<BeadColor?> cells, int w, int h) {
    final counts = <BeadColor, int>{};
    for (final c in cells) {
      if (c == null) continue;
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
