import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/converter.dart';
import '../core/palette.dart';
import '../theme/pindou_theme.dart';

/// 图纸画布：绘制拼豆网格、色块、色号，支持缩放、平移与画笔涂色。
class PatternCanvas extends StatefulWidget {
  const PatternCanvas({
    super.key,
    required this.pattern,
    required this.colors,
    this.showGrid = true,
    this.showRuler = true,
    this.boardSize = 29,
    this.showBoard = false,
    this.partitionSize = 10,
    this.onCellTap,
    this.brushCode,
    this.onPaintCell,
    this.onEraseCell,
    this.onStrokeStart,
    this.onStrokeEnd,
  });

  final BeadPattern? pattern;

  /// 画布配色（网格线/标尺/虚线/遮罩），随主题切换。
  /// 变化时位图缓存失效并重新光栅化（见 didUpdateWidget）。
  final PindouCanvasColors colors;

  final bool showGrid;

  /// 是否显示行号/列号标尺与底板分界线。
  final bool showRuler;

  /// 底板尺寸（豆数）：分界虚线按此间距绘制。
  final int boardSize;

  /// 是否显示实体底板（白色底板铺在图纸下方，图纸小于底板时露出）。
  final bool showBoard;

  /// 底板分区尺寸（豆数）：每 N 颗豆一条分界线。
  final int partitionSize;

  /// 点击格子回调（未启用画笔时），参数为格子坐标 (x, y)。
  final void Function(int x, int y)? onCellTap;

  /// 画笔色号；非 null 时启用画笔模式（拖动涂色，右键擦除）。
  final String? brushCode;

  /// 画笔涂到某格（笔画过程中连续回调）。
  /// 返回 (是否有变化, 新内容)：新内容 null = 该格变为空格。
  final (bool, BeadColor?) Function(int x, int y)? onPaintCell;

  /// 右键擦除某格（恢复自动转换色或擦成空格）。
  /// 返回 (是否有变化, 新内容)：新内容 null = 该格变为空格。
  final (bool, BeadColor?) Function(int x, int y)? onEraseCell;

  /// 笔画开始/结束（用于把一次拖动合并为一步撤销）。
  final VoidCallback? onStrokeStart;
  final VoidCallback? onStrokeEnd;

  @override
  State<PatternCanvas> createState() => _PatternCanvasState();
}

class _PatternCanvasState extends State<PatternCanvas> {
  final TransformationController _transform = TransformationController();

  /// 当前缩放比例（供工具条百分比显示）。
  final ValueNotifier<double> _scale = ValueNotifier<double>(1);

  /// 预渲染图纸位图（含色块+网格线+外框，不含标尺）。
  /// 缩放/平移时 GPU 只需变换这一张纹理，大图也流畅。
  ui.Image? _rasterImage;

  /// 位图对应的 pattern 与参数（判断缓存是否有效）。
  BeadPattern? _rasterPattern;
  bool _rasterShowGrid = true;
  bool _rasterShowRuler = true;
  int _rasterBoardSize = 29;
  bool _rasterShowBoard = false;
  int _rasterPartitionSize = 10;
  PindouCanvasColors? _rasterColors;

  /// 位图中图纸相对位图左上角的偏移（格子数）：底板显示时图纸居中，
  /// 命中测试（_cellAt）与绘制都要用同一偏移换算。
  int _rasterOffX = 0;
  int _rasterOffY = 0;

  /// 正在光栅化（避免重复提交）。
  bool _rasterizing = false;

  // 画笔状态。
  bool _painting = false;
  int? _lastCellX;
  int? _lastCellY;
  bool _erasing = false;
  int _activeButtons = 0;

  /// 叠加层版本号：涂色时递增，触发画布重绘（不重建子树）。
  final ValueNotifier<int> _overlayVersion = ValueNotifier<int>(0);

  /// 本笔画中变化的格子与最新颜色（叠加层绘制内容）。
  /// bead 为 null = 该格被擦成空格（棋盘格显示）。
  final List<(int, int, BeadColor?)> _dirtyCells = [];

  /// 待增量光栅化的脏格子（笔画结束到光栅化完成期间持有）。
  /// 光栅化时只重绘这些格子（叠加到旧位图上），避免全图重绘。
  List<(int, int, BeadColor?)>? _pendingDirtyCells;

  void _onTransformChanged() {
    // 只更新缩放百分比显示（ValueListenableBuilder 局部刷新，不重建子树）。
    _scale.value = _transform.value.getMaxScaleOnAxis();
  }

  /// 缩放控制：围绕视口中心缩放。
  void _zoomBy(double factor) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final center = box.size.center(Offset.zero);
    final current = _transform.value.clone();
    final scale = current.getMaxScaleOnAxis();
    final newScale = (scale * factor).clamp(0.2, 8.0);
    final effective = newScale / scale;
    current
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(effective, effective, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
    _transform.value = current;
  }

  /// 适应窗口。
  void _fitToView(BeadPattern p) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final vpW = box.size.width - 32;
    final vpH = box.size.height - 32;
    if (vpW <= 0 || vpH <= 0) return;
    // 底板显示时按底板区域适配（图纸居中其中）。
    final w = widget.showBoard ? math.max(p.width, widget.boardSize) : p.width;
    final h = widget.showBoard ? math.max(p.height, widget.boardSize) : p.height;
    final cell = (vpW / w).clamp(1.0, vpH / h);
    final scale = cell / _baseCell;
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        (box.size.width - w * cell) / 2,
        (box.size.height - h * cell) / 2,
        0,
        1,
      )
      ..scaleByDouble(scale, scale, 1, 1);
    _scale.value = scale;
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    _rasterImage?.dispose();
    super.dispose();
  }


  @override
  void didUpdateWidget(PatternCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    final p = widget.pattern;
    if (p != null && (oldWidget.pattern == null ||
        p.width != oldWidget.pattern!.width ||
        p.height != oldWidget.pattern!.height)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView(p));
    }
    // 图纸/显示选项/主题配色变化：使位图缓存失效并重新光栅化。
    // 笔画中跳过：涂色由叠加层即时显示，笔画结束（onStrokeEnd）后统一重光栅化。
    // 延迟到帧渲染完成后执行，避免与状态层重建同帧叠加。
    if (!_painting &&
        (p != _rasterPattern ||
            widget.showGrid != _rasterShowGrid ||
            widget.showRuler != _rasterShowRuler ||
            widget.boardSize != _rasterBoardSize ||
            widget.showBoard != _rasterShowBoard ||
            widget.partitionSize != _rasterPartitionSize ||
            widget.colors != _rasterColors)) {
      _scheduleRasterizeAfterFrame();
    }
  }

  /// 将图纸光栅化为位图（异步光栅化，不阻塞 UI）。
  /// 完成后触发一次重绘，paint 只 drawImage，缩放平移由 GPU 变换纹理。
  ///
  /// [_pendingDirtyCells] 非空时走**增量光栅化**：旧位图 + 只重绘脏格子，
  /// 绘制指令从"全图 run-length + 网格线 + 标尺"缩减为
  /// "1 次 drawImage + N 个脏格子矩形"，笔画结束的收尾开销大幅下降。
  Future<void> _scheduleRasterize() async {
    if (_rasterizing) return;
    _rasterizing = true;
    final p = widget.pattern;
    if (p == null) {
      _rasterizing = false;
      return;
    }
    // 增量模式仅当：有脏格子、旧位图存在、旧位图对应同一 pattern 尺寸
    // 且显示选项与主题配色未变（否则内容结构不同，必须全量）。
    // 配色必须一致：新色补线画在旧色位图上必然错乱。
    final dirty = _pendingDirtyCells;
    final canIncremental = dirty != null &&
        dirty.isNotEmpty &&
        _rasterImage != null &&
        _rasterPattern != null &&
        _rasterPattern!.width == p.width &&
        _rasterPattern!.height == p.height &&
        _rasterShowGrid == widget.showGrid &&
        _rasterShowRuler == widget.showRuler &&
        _rasterBoardSize == widget.boardSize &&
        _rasterShowBoard == widget.showBoard &&
        _rasterPartitionSize == widget.partitionSize &&
        _rasterColors == widget.colors;
    _pendingDirtyCells = null;
    try {
      // 2x 超采样：放大到 200% 仍清晰。
      const ss = 2.0;
      // 底板显示时位图覆盖底板区域，图纸左上角对齐底板（无摆放偏移）。
      final boardW = widget.showBoard ? math.max(p.width, widget.boardSize) : p.width;
      final boardH = widget.showBoard ? math.max(p.height, widget.boardSize) : p.height;
      const offX = 0;
      const offY = 0;
      final w = (boardW * _baseCell * ss).round();
      final h = (boardH * _baseCell * ss).round();
      if (w <= 0 || h <= 0) return;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      canvas.scale(ss);
      // 底板：白色实体（图纸区域外露出），带外边框。
      if (widget.showBoard) {
        canvas.drawRect(
          Rect.fromLTWH(0, 0, boardW * _baseCell, boardH * _baseCell),
          Paint()..color = widget.colors.boardSurface,
        );
      }
      // 图纸区域平移到居中位置。
      canvas.translate(offX * _baseCell, offY * _baseCell);
      if (canIncremental) {
        // 增量：旧位图打底，脏格子覆盖。
        // 注意 canvas 已 scale(ss)：所有坐标都是 1x 逻辑坐标，
        // 目标矩形必须用逻辑尺寸（w/ss = p.width * _baseCell），
        // 若直接用 w/h 会被 scale 再放大 ss 倍，旧图只画进左上角
        // 1/ss 区域——表现为"每画一笔图片缩小一圈，最后消失"。
        final src = _rasterImage!;
        final logicalW = w / ss;
        final logicalH = h / ss;
        canvas.drawImageRect(
          src,
          Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
          Rect.fromLTWH(0, 0, logicalW, logicalH),
          Paint()..filterQuality = FilterQuality.none,
        );
        final fill = Paint()..style = PaintingStyle.fill;
        // 色块向外扩 1.2px：所有网格线居中于格线（细线 1px 两侧各 0.5px、
        // 加深线 2px 两侧各 1px、29 格虚线 1.5px 两侧各 0.75px）。
        // bleed 必须盖住最宽线在自己一侧的半宽（1px），否则旧线残留，
        // 新线叠加其上——擦除后表现为"比周围的线更黑"（半透明线叠加两次）。
        // 扩出去的部分随后被补画的线覆盖，视觉无损失。
        const bleed = 1.2;
        for (final (x, y, bead) in dirty) {
          if (bead == null) {
            // 擦成空格：先清掉旧色块（画画布底色），再画棋盘格。
            fill.color = widget.colors.canvasBg;
            canvas.drawRect(
              Rect.fromLTWH(
                x * _baseCell - bleed,
                y * _baseCell - bleed,
                _baseCell + bleed * 2,
                _baseCell + bleed * 2,
              ),
              fill,
            );
            _drawEmptyCell(canvas, x * _baseCell, y * _baseCell, _baseCell,
                widget.colors.emptyCell);
            continue;
          }
          fill.color = Color(bead.argb);
          canvas.drawRect(
            Rect.fromLTWH(
              x * _baseCell - bleed,
              y * _baseCell - bleed,
              _baseCell + bleed * 2,
              _baseCell + bleed * 2,
            ),
            fill,
          );
        }
        // 脏格子覆盖了旧位图的网格线，在其上补画。
        // 关键 1：补画必须以格线为中心画完整线宽，与全量绘制一致。
        // 关键 2：线段范围必须精确等于"色块实际覆盖的区域"
        // （脏格子矩形 ± bleed），绝不能伸入完好区域——半透明线
        // 在旧位图完好的线上再画一遍会叠加变黑（此前 ±1 格的
        // 补画范围导致"画一行影响周围行"）。
        // 端点衔接：相邻脏格子的覆盖段天然连续（共享格线坐标相同），
        // 无需外扩。
        if (widget.showGrid) {
          final cell = _baseCell;
          // 每条格线需要补画的范围（键为格线坐标：竖线 gx 0..width，
          // 横线 gy 0..height；值为该格线上被色块覆盖的区段）。
          final vSegs = <int, (double, double)>{};
          final hSegs = <int, (double, double)>{};
          for (final (x, y, _) in dirty) {
            final l = x * cell, t = y * cell;
            final r = l + cell, b = t + cell;
            void mergeV(int gx, double y0, double y1) {
              final old = vSegs[gx];
              vSegs[gx] = old == null
                  ? (y0, y1)
                  : (old.$1 < y0 ? old.$1 : y0, old.$2 > y1 ? old.$2 : y1);
            }

            void mergeH(int gy, double x0, double x1) {
              final old = hSegs[gy];
              hSegs[gy] = old == null
                  ? (x0, x1)
                  : (old.$1 < x0 ? old.$1 : x0, old.$2 > x1 ? old.$2 : x1);
            }

            // 覆盖段 = 格线与色块（含 bleed）的交集。
            mergeV(x, t - bleed, b + bleed);
            mergeV(x + 1, t - bleed, b + bleed);
            mergeH(y, l - bleed, r + bleed);
            mergeH(y + 1, l - bleed, r + bleed);
          }
          // 细线：所有格线（与全量 gridPath 一致）。
          // 加深线：格线坐标 %10==0（与全量 majorPath 一致）。
          final thin = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = widget.colors.gridThin;
          final thick = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = widget.colors.gridMajor;
          for (final entry in vSegs.entries) {
            final isMajor = entry.key % 10 == 0;
            final x = entry.key * cell;
            canvas.drawLine(Offset(x, entry.value.$1),
                Offset(x, entry.value.$2), isMajor ? thick : thin);
          }
          for (final entry in hSegs.entries) {
            final isMajor = entry.key % 10 == 0;
            final y = entry.key * cell;
            canvas.drawLine(Offset(entry.value.$1, y),
                Offset(entry.value.$2, y), isMajor ? thick : thin);
          }
        }
        // 底板分界虚线：脏格子覆盖段同样需要补画（橙色虚线
        // 1.5px 居中于格线，色块 bleed 盖掉自己侧 0.75px 后必须补回；
        // 覆盖段同样精确限制在色块区域内，不伸入完好区域）。
        if (widget.showRuler) {
          final boardSize = widget.boardSize;
          final dashPaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = widget.colors.boardDash;
          final cell = _baseCell;
          for (final (x, y, _) in dirty) {
            final l = x * cell, t = y * cell;
            final r = l + cell, b = t + cell;
            // 竖向虚线：格线 x 与 x+1 是 29 的倍数（0 与最外边界除外，
            // 与全量绘制一致）。
            if (x % boardSize == 0 && x > 0) {
              final gx = x * cell;
              drawDashedLine(canvas, dashPaint,
                  Offset(gx, t - bleed), Offset(gx, b + bleed));
            }
            if ((x + 1) % boardSize == 0 && x + 1 < p.width) {
              final gx = (x + 1) * cell;
              drawDashedLine(canvas, dashPaint,
                  Offset(gx, t - bleed), Offset(gx, b + bleed));
            }
            // 横向虚线。
            if (y % boardSize == 0 && y > 0) {
              final gy = y * cell;
              drawDashedLine(canvas, dashPaint,
                  Offset(l - bleed, gy), Offset(r + bleed, gy));
            }
            if ((y + 1) % boardSize == 0 && y + 1 < p.height) {
              final gy = (y + 1) * cell;
              drawDashedLine(canvas, dashPaint,
                  Offset(l - bleed, gy), Offset(r + bleed, gy));
            }
          }
        }
      } else {
        _PatternPainter(
          pattern: p,
          showGrid: widget.showGrid,
          showRuler: widget.showRuler,
          boardSize: widget.boardSize,
          cell: _baseCell,
          colors: widget.colors,
          showBoard: widget.showBoard,
          boardW: boardW,
          boardH: boardH,
          partitionSize: widget.partitionSize,
          patternOffsetX: offX,
          patternOffsetY: offY,
        ).paint(canvas, Size(w.toDouble(), h.toDouble()));
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(w, h);
      if (!mounted) {
        image.dispose();
        return;
      }
      final old = _rasterImage;
      setState(() {
        _rasterImage = image;
        _rasterPattern = p;
        _rasterShowGrid = widget.showGrid;
        _rasterShowRuler = widget.showRuler;
        _rasterBoardSize = widget.boardSize;
        _rasterShowBoard = widget.showBoard;
        _rasterPartitionSize = widget.partitionSize;
        _rasterColors = widget.colors;
        _rasterOffX = offX;
        _rasterOffY = offY;
      });
      old?.dispose();
    } finally {
      _rasterizing = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
    final p = widget.pattern;
    if (p != null) {
      _scheduleRasterize();
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitToView(p));
    }
  }

  /// 屏幕坐标 -> 格子坐标。
  /// 除法结果可能因浮点误差略小于整数（如 47.9999999），加 epsilon 修正。
  /// 底板显示时图纸居中于底板，需减去位图偏移。
  (int, int)? _cellAt(Offset localPos) {
    final p = widget.pattern;
    if (p == null) return null;
    const eps = 1e-6;
    final x = (localPos.dx / _baseCell + eps).floor() - _rasterOffX;
    final y = (localPos.dy / _baseCell + eps).floor() - _rasterOffY;
    if (x < 0 || x >= p.width || y < 0 || y >= p.height) return null;
    return (x, y);
  }

  // ===== 右键擦除（raw pointer）：pan 手势只响应左键，右键需自行处理 =====

  /// 右键按下：开始擦除笔画。
  void _handleRightDown(PointerDownEvent e) {
    if (widget.brushCode == null) return;
    final cell = _cellAt(e.localPosition);
    if (cell == null) return;
    widget.onStrokeStart?.call();
    _painting = true;
    _erasing = true;
    _dirtyCells.clear();
    _lastCellX = cell.$1;
    _lastCellY = cell.$2;
    _paintAt(cell.$1, cell.$2);
  }

  /// 右键拖动：连续擦除（Bresenham 补插）。
  void _handleRightMove(PointerMoveEvent e) {
    if (!_painting || !_erasing) return;
    final cell = _cellAt(e.localPosition);
    if (cell == null) return;
    final lx = _lastCellX, ly = _lastCellY;
    if (lx != null && ly != null) {
      _paintLine(lx, ly, cell.$1, cell.$2);
    } else {
      _paintAt(cell.$1, cell.$2);
    }
    _lastCellX = cell.$1;
    _lastCellY = cell.$2;
  }

  /// 右键抬起：结束笔画并增量光栅化。
  void _handleRightUp(PointerEvent e) {
    if (_painting && _erasing) {
      _painting = false;
      _erasing = false;
      _lastCellX = null;
      _lastCellY = null;
      widget.onStrokeEnd?.call();
      _pendingDirtyCells = List.of(_dirtyCells);
      _dirtyCells.clear();
      _overlayVersion.value++;
      _scheduleRasterizeAfterFrame();
    }
  }

  void _handlePanStart(DragStartDetails details) {
    final cell = _cellAt(details.localPosition);
    if (cell == null) return;
    widget.onStrokeStart?.call();
    _painting = true;
    _erasing = _activeButtons == kSecondaryMouseButton;
    _dirtyCells.clear();
    _lastCellX = cell.$1;
    _lastCellY = cell.$2;
    _paintAt(cell.$1, cell.$2);
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (!_painting) return;
    final cell = _cellAt(details.localPosition);
    if (cell == null) return;
    final lx = _lastCellX, ly = _lastCellY;
    if (lx != null && ly != null) {
      _paintLine(lx, ly, cell.$1, cell.$2);
    } else {
      _paintAt(cell.$1, cell.$2);
    }
    _lastCellX = cell.$1;
    _lastCellY = cell.$2;
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_painting) {
      _painting = false;
      _lastCellX = null;
      _lastCellY = null;
      widget.onStrokeEnd?.call();
      // 脏格子转交增量光栅化（只重绘这些格子，不全图重绘）。
      _pendingDirtyCells = List.of(_dirtyCells);
      _dirtyCells.clear();
      _overlayVersion.value++;
      // 笔画结束：pattern 已重建（新实例）。重光栅化推迟到本帧渲染完成后，
      // 避免与 endStroke 的重建/全页刷新同帧叠加造成松手瞬间卡顿。
      _scheduleRasterizeAfterFrame();
    }
  }

  /// 帧渲染完成后再光栅化：把重活挪出当前帧。
  void _scheduleRasterizeAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleRasterize();
    });
  }

  void _paintAt(int x, int y) {
    // 回调返回 (是否有变化, 新内容)。笔画中 pattern.cells 是旧内容
    // （快速路径写可变副本，endStroke 才重建），不能靠读 pattern
    // 判断变化——必须由状态层明确告知。
    final r = _erasing
        ? widget.onEraseCell?.call(x, y)
        : widget.onPaintCell?.call(x, y);
    if (r == null || !r.$1) return;
    _dirtyCells.add((x, y, r.$2));
    _overlayVersion.value++;
  }

  /// Bresenham 直线补插，快速拖动时不跳格。
  void _paintLine(int x0, int y0, int x1, int y1) {
    int dx = (x1 - x0).abs(), dy = -(y1 - y0).abs();
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;
    while (true) {
      _paintAt(x0, y0);
      if (x0 == x1 && y0 == y1) break;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x0 += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y0 += sy;
      }
    }
  }

  /// 基准单元尺寸（逻辑像素/豆），缩放基于它计算。
  static const double _baseCell = 24;

  @override
  Widget build(BuildContext context) {
    final pattern = widget.pattern;
    if (pattern == null) {
      final colors = widget.colors;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_off, size: 64, color: colors.rulerText),
            const SizedBox(height: 12),
            Text('请先导入图片并生成图纸',
                style: TextStyle(color: colors.rulerText, fontSize: 16)),
          ],
        ),
      );
    }

    final brushActive = widget.brushCode != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        InteractiveViewer(
          transformationController: _transform,
          boundaryMargin: const EdgeInsets.all(double.infinity),
          minScale: 0.2,
          maxScale: 8.0,
          constrained: false,
          // 画笔模式下左键用于涂色（pan 由本组件接管）；非画笔时
          // 左键拖动平移视图。滚轮/双指缩放不受影响。
          panEnabled: !brushActive,
          scaleEnabled: true,
          child: Listener(
            onPointerDown: (e) => _activeButtons = e.buttons,
            onPointerUp: (e) => _activeButtons = 0,
            onPointerCancel: (e) => _activeButtons = 0,
            child: GestureDetector(
            onTapUp: brushActive
                ? null
                : (widget.onCellTap == null
                    ? null
                    : (details) {
                        final cell = _cellAt(details.localPosition);
                        if (cell != null) widget.onCellTap!(cell.$1, cell.$2);
                      }),
            // pan 仅画笔模式注册（涂色/擦除）；非画笔时左键拖动
            // 交还 InteractiveViewer 平移视图（panEnabled 同步恢复）。
            onPanStart: brushActive ? _handlePanStart : null,
            onPanUpdate: brushActive ? _handlePanUpdate : null,
            onPanEnd: brushActive ? _handlePanEnd : null,
            // 右键擦除与左键涂色同路径：按下拖动 = 连续擦除（pan 手势
            // 不区分按键，_handlePanStart 按 _activeButtons 判定擦除模式），
            // 单击一格 = 一次零距离 pan，同样走 begin/erase/end。
              child: SizedBox(
                width: (widget.showBoard
                        ? math.max(pattern.width, widget.boardSize)
                        : pattern.width) *
                    _baseCell,
                height: (widget.showBoard
                        ? math.max(pattern.height, widget.boardSize)
                        : pattern.height) *
                    _baseCell,
                // 内层 Listener：右键擦除走 raw pointer（pan 手势只响应
                // 左键）。放在 SizedBox 内层保证 localPosition 与 _cellAt
                // 同一坐标系。
                child: Listener(
                  onPointerDown: (e) {
                    if (e.buttons == kSecondaryMouseButton) {
                      _handleRightDown(e);
                    }
                  },
                  onPointerMove: (e) {
                    if (e.buttons == kSecondaryMouseButton) {
                      _handleRightMove(e);
                    }
                  },
                  onPointerUp: _handleRightUp,
                  onPointerCancel: _handleRightUp,
                  // RepaintBoundary：图纸内容缓存为独立图层，
                  // 缩放/平移时仅做合成变换，不触发重绘。
                  child: RepaintBoundary(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _overlayVersion,
                    builder: (context, version, _) => CustomPaint(
                      painter: _RasterPatternPainter(
                        image: _rasterImage,
                        fallback: _rasterImage == null
                            ? _PatternPainter(
                                pattern: pattern,
                                showGrid: widget.showGrid,
                                showRuler: widget.showRuler,
                                boardSize: widget.boardSize,
                                cell: _baseCell,
                                colors: widget.colors,
                                showBoard: widget.showBoard,
                                boardW: widget.showBoard
                                    ? math.max(pattern.width, widget.boardSize)
                                    : pattern.width,
                                boardH: widget.showBoard
                                    ? math.max(pattern.height, widget.boardSize)
                                    : pattern.height,
                                partitionSize: widget.partitionSize,
                                patternOffsetX: 0,
                                patternOffsetY: 0,
                              )
                            : null,
                        cell: _baseCell,
                      ),
                      // 前景叠加层：笔画中涂过的格子用矢量即时绘制，
                      // 位图保持旧内容不重光栅化（松手后统一更新）。
                      foregroundPainter: _painting && _dirtyCells.isNotEmpty
                          ? _StrokeOverlayPainter(
                              dirtyCells: _dirtyCells,
                              cell: _baseCell,
                              version: version,
                            )
                          : null,
                    ),
                  ),
                ),
                ),
              ),
            ),
          ),
        ),
        // 右下角缩放工具条。
        Positioned(
          right: 12,
          bottom: 12,
          child: Card(
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '缩小',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.zoom_out),
                    onPressed: () => _zoomBy(1 / 1.25),
                  ),
                  ValueListenableBuilder<double>(
                    valueListenable: _scale,
                    builder: (context, scale, _) => Text(
                      '${(scale * 100).round()}%',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '放大',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.zoom_in),
                    onPressed: () => _zoomBy(1.25),
                  ),
                  IconButton(
                    tooltip: '适应窗口',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.fit_screen),
                    onPressed: () => _fitToView(pattern),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 笔画叠加层：绘制"位图内容与当前 pattern 不同的格子"。
/// 笔画中 pattern.cells 已更新（可变副本），但位图仍是旧内容——
/// State 侧维护脏格子集合，这里只重绘脏格子（通常 1~10 个），开销极小。
class _StrokeOverlayPainter extends CustomPainter {
  _StrokeOverlayPainter({
    required this.dirtyCells,
    required this.cell,
    required this.version,
  });

  /// 本笔画中变化的格子与最新颜色。null = 擦成空格。
  final List<(int, int, BeadColor?)> dirtyCells;
  final double cell;

  /// 版本号：每次涂色递增，驱动重绘。
  final int version;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..style = PaintingStyle.fill;
    for (final (x, y, bead) in dirtyCells) {
      if (bead == null) {
        // 擦成空格：画棋盘格（与全量绘制的空格样式一致）。
        _drawEmptyCell(canvas, x * cell, y * cell, cell);
        continue;
      }
      fill.color = Color(bead.argb);
      canvas.drawRect(
        Rect.fromLTWH(x * cell, y * cell, cell, cell),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StrokeOverlayPainter oldDelegate) {
    return oldDelegate.version != version ||
        oldDelegate.dirtyCells.length != dirtyCells.length;
  }
}

/// 位图绘制器：图纸已光栅化为 ui.Image 后，paint 只做一次 drawImageRect，
/// 缩放/平移时 GPU 仅变换单张纹理，大图也流畅。
/// 位图未就绪（首帧/重新光栅化中）时回退到矢量绘制。
class _RasterPatternPainter extends CustomPainter {
  _RasterPatternPainter({
    required this.image,
    required this.fallback,
    required this.cell,
  });

  final ui.Image? image;
  final _PatternPainter? fallback;
  final double cell;

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img != null) {
      // 位图按 2x 超采样光栅化，绘制目标为 1x 逻辑尺寸。
      final w = img.width / 2.0;
      final h = img.height / 2.0;
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(0, 0, w, h),
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    fallback?.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _RasterPatternPainter oldDelegate) {
    if (oldDelegate.image != image) return true;
    final f = fallback;
    final of = oldDelegate.fallback;
    if ((f == null) != (of == null)) return true;
    if (f == null || of == null) return false;
    return f.pattern != of.pattern ||
        f.showGrid != of.showGrid ||
        f.showRuler != of.showRuler ||
        f.cell != of.cell;
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({
    required this.pattern,
    required this.showGrid,
    required this.showRuler,
    required this.boardSize,
    required this.cell,
    required this.colors,
    this.showBoard = false,
    this.boardW,
    this.boardH,
    this.partitionSize = 10,
    this.patternOffsetX = 0,
    this.patternOffsetY = 0,
  });

  final BeadPattern pattern;
  final bool showGrid;
  final bool showRuler;
  final int boardSize;
  final double cell;
  final PindouCanvasColors colors;

  /// 底板显示：白色实体底板铺在图纸下方（图纸居中，四周露出）。
  final bool showBoard;

  /// 底板区域尺寸（格子数）：showBoard 时由调用方传入（max(图纸, 底板)）。
  final int? boardW;
  final int? boardH;

  /// 底板分区尺寸（豆数）：每 N 颗豆一条分界线。
  final int partitionSize;

  /// 图纸在底板上的偏移（格子数）：showBoard 时由调用方传入。
  final int patternOffsetX;
  final int patternOffsetY;

  /// 标尺文字跨帧缓存：(文本, 格子尺寸) -> 已排版 TextPainter。
  /// 主题切换时清空（文字颜色变了，缓存的排版结果作废）。
  static final Map<(String, double), TextPainter> _rulerTextCache = {};

  @override
  void paint(Canvas canvas, Size size) {
    final fillPaint = Paint()..style = PaintingStyle.fill;

    // 底板显示：先铺白色实体底板（含边缘描边），图纸按偏移摆放。
    final bw = boardW ?? pattern.width;
    final bh = boardH ?? pattern.height;
    final offX = showBoard ? patternOffsetX : 0;
    final offY = showBoard ? patternOffsetY : 0;
    if (showBoard) {
      // 白色实体底板。
      canvas.drawRect(
        Rect.fromLTWH(0, 0, bw * cell, bh * cell),
        Paint()..color = colors.boardSurface,
      );
      // 底板格线（淡）：每格一条，与分区线区分。
      final faintPath = Path();
      for (int x = 1; x < bw; x++) {
        faintPath.moveTo(x * cell, 0);
        faintPath.lineTo(x * cell, bh * cell);
      }
      for (int y = 1; y < bh; y += 1) {
        faintPath.moveTo(0, y * cell);
        faintPath.lineTo(bw * cell, y * cell);
      }
      canvas.drawPath(
        faintPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = colors.boardGrid,
      );
      // 底板分区线（深）：每 partitionSize 豆一条，模拟实体底板分区。
      final ps = partitionSize.clamp(1, math.max(bw, bh)).toInt();
      final partPath = Path();
      for (int x = ps; x < bw; x += ps) {
        partPath.moveTo(x * cell, 0);
        partPath.lineTo(x * cell, bh * cell);
      }
      for (int y = ps; y < bh; y += ps) {
        partPath.moveTo(0, y * cell);
        partPath.lineTo(bw * cell, y * cell);
      }
      canvas.drawPath(
        partPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.boardEdge,
      );
      canvas.drawRect(
        Rect.fromLTWH(0, 0, bw * cell, bh * cell),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.boardEdge,
      );
      // 分区坐标：沿底板顶部与左侧标注分区序号（1 起）。
      if (showRuler && cell >= 10) {
        final labelStyle = TextStyle(
          color: colors.rulerText,
          fontSize: cell * 0.42,
          fontWeight: FontWeight.w600,
        );
        final rulerCache = _rulerTextCache;
        void drawLabel(String text, Offset center) {
          final key = (text, cell);
          var tp = rulerCache[key];
          if (tp == null) {
            tp = TextPainter(textDirection: TextDirection.ltr)
              ..text = TextSpan(text: text, style: labelStyle)
              ..layout();
            rulerCache[key] = tp;
          }
          tp.paint(
            canvas,
            Offset(
              center.dx - tp.width / 2,
              center.dy - tp.height / 2,
            ),
          );
        }

        final cols = (bw + ps - 1) ~/ ps;
        final rows = (bh + ps - 1) ~/ ps;
        for (int i = 0; i < cols; i++) {
          // 分区中心 x 坐标（末列可能不满 ps）。
          final cx = (i * ps + (math.min(ps, bw - i * ps)) / 2) * cell;
          drawLabel('${i + 1}', Offset(cx, -cell * 0.7));
        }
        for (int i = 0; i < rows; i++) {
          final cy = (i * ps + (math.min(ps, bh - i * ps)) / 2) * cell;
          drawLabel('${i + 1}', Offset(-cell * 0.7, cy));
        }
      }
      // 图纸区域平移到居中位置（后续所有绘制都在图纸坐标系内）。
      canvas.translate(offX * cell, offY * cell);
    }

    // 绘制全部格子。RepaintBoundary 将结果缓存为图层：
    // 内容不变时（缩放/平移）不再重绘，交互由合成器完成，因此这里
    // 的一次性全量绘制不会影响缩放平移流畅度。
    // 注意：不能按视口裁剪——缓存层必须包含完整图纸，否则缩放后缺块。
    const x0 = 0;
    final x1 = pattern.width;
    const y0 = 0;
    final y1 = pattern.height;

    for (int y = y0; y < y1; y++) {
      // 同色连续格子合并为一个矩形，减少 drawRect 调用。
      // 空格（null）单独处理：画棋盘格纹理表示"不放豆"。
      int runStart = x0;
      BeadColor? runBead;
      bool runEmpty = false;
      void flushRun(int endX) {
        if (runEmpty) {
          for (int x = runStart; x < endX; x++) {
            _drawEmptyCell(canvas, x * cell, y * cell, cell, colors.emptyCell);
          }
          return;
        }
        if (runBead == null) return;
        fillPaint.color = Color(runBead.argb);
        canvas.drawRect(
          Rect.fromLTWH(runStart * cell, y * cell, (endX - runStart) * cell, cell),
          fillPaint,
        );
      }

      for (int x = x0; x < x1; x++) {
        final bead = pattern.cellAt(x, y);
        final isEmpty = bead == null;
        if (isEmpty != runEmpty || (!isEmpty && bead != runBead)) {
          flushRun(x);
          runStart = x;
          runBead = isEmpty ? null : bead;
          runEmpty = isEmpty;
        }
      }
      flushRun(x1);
    }

    // 网格线：合并为两条 Path，一次 drawPath 完成。
    if (showGrid) {
      final gridPath = Path()
        ..addRect(Rect.fromLTWH(0, 0, pattern.width * cell, pattern.height * cell));
      for (int x = x0; x <= x1; x++) {
        gridPath.moveTo(x * cell, y0 * cell);
        gridPath.lineTo(x * cell, y1 * cell);
      }
      for (int y = y0; y <= y1; y++) {
        gridPath.moveTo(x0 * cell, y * cell);
        gridPath.lineTo(x1 * cell, y * cell);
      }
      canvas.drawPath(
        gridPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = colors.gridThin,
      );
      // 每 10 格加深线，方便对照。
      final majorPath = Path();
      for (int x = (x0 ~/ 10) * 10; x <= x1; x += 10) {
        majorPath.moveTo(x * cell, y0 * cell);
        majorPath.lineTo(x * cell, y1 * cell);
      }
      for (int y = (y0 ~/ 10) * 10; y <= y1; y += 10) {
        majorPath.moveTo(x0 * cell, y * cell);
        majorPath.lineTo(x1 * cell, y * cell);
      }
      canvas.drawPath(
        majorPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = colors.gridMajor,
      );
    }

    // 外边框。
    canvas.drawRect(
      Rect.fromLTWH(0, 0, pattern.width * cell, pattern.height * cell),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = colors.patternBorder,
    );

    // 行号/列号标尺（每 5 格标注）与底板分界线。
    if (showRuler && cell >= 10) {
      const rulerStep = 5;
      final boardSize = this.boardSize;
      final labelStyle = TextStyle(
        color: colors.rulerText,
        fontSize: cell * 0.42,
        fontWeight: FontWeight.w600,
      );

      // 标尺文字缓存：同字号同文本只排版一次（跨帧复用）。
      final rulerCache = _rulerTextCache;
      void drawLabel(String text, Offset center) {
        final key = (text, cell);
        var tp = rulerCache[key];
        if (tp == null) {
          tp = TextPainter(textDirection: TextDirection.ltr)
            ..text = TextSpan(text: text, style: labelStyle)
            ..layout();
          rulerCache[key] = tp;
        }
        tp.paint(
          canvas,
          Offset(
            center.dx - tp.width / 2,
            center.dy - tp.height / 2,
          ),
        );
      }

      // 列号（顶部）。
      for (int x = rulerStep; x <= pattern.width; x += rulerStep) {
        drawLabel('$x', Offset(x * cell, -cell * 0.7));
      }
      // 行号（左侧）。
      for (int y = rulerStep; y <= pattern.height; y += rulerStep) {
        drawLabel('$y', Offset(-cell * 0.7, y * cell));
      }

      // 29 格底板分界虚线（跳过 0 与最外边界）。
      final dashPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = colors.boardDash;
      for (int x = boardSize; x < pattern.width; x += boardSize) {
        drawDashedLine(
          canvas, dashPaint,
          Offset(x * cell, 0), Offset(x * cell, pattern.height * cell),
        );
      }
      for (int y = boardSize; y < pattern.height; y += boardSize) {
        drawDashedLine(
          canvas, dashPaint,
          Offset(0, y * cell), Offset(pattern.width * cell, y * cell),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PatternPainter oldDelegate) {
    return oldDelegate.pattern != pattern ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.showRuler != showRuler ||
        oldDelegate.boardSize != boardSize ||
        oldDelegate.cell != cell ||
        oldDelegate.colors != colors ||
        oldDelegate.showBoard != showBoard ||
        oldDelegate.boardW != boardW ||
        oldDelegate.boardH != boardH ||
        oldDelegate.partitionSize != partitionSize ||
        oldDelegate.patternOffsetX != patternOffsetX ||
        oldDelegate.patternOffsetY != patternOffsetY;
  }
}

/// 绘制竖直/水平虚线（文件级函数：全量绘制与增量补画共用）。
void drawDashedLine(Canvas canvas, Paint paint, Offset start, Offset end) {
  const dashLen = 6.0;
  const gapLen = 4.0;
  final dx = end.dx - start.dx;
  final dy = end.dy - start.dy;
  final len = (dx * dx + dy * dy);
  if (len == 0) return;
  final unit = Offset(dx, dy) / len;
  var dist = 0.0;
  final total = len;
  while (dist < total) {
    final segEnd = (dist + dashLen).clamp(0.0, total);
    canvas.drawLine(
      start + unit * dist,
      start + unit * segEnd,
      paint,
    );
    dist = segEnd + gapLen;
  }
}

/// 绘制单个空格的棋盘格纹理（全量绘制、笔画叠加层共用）。
/// [color] 缺省时用默认浅灰（叠加层无主题色上下文）。
void _drawEmptyCell(
  Canvas canvas,
  double px,
  double py,
  double cell, [
  Color color = const Color(0x14000000),
]) {
  const sq = 8.0;
  final checker = Paint()..color = color;
  final cols = (cell / sq).ceil();
  final rows = (cell / sq).ceil();
  for (int yy = 0; yy < rows; yy++) {
    for (int xx = 0; xx < cols; xx++) {
      if ((xx + yy) % 2 == 0) continue;
      // 末行/末列裁剪到格子边界。
      final w = math.min(sq, cell - xx * sq).clamp(0.0, sq);
      final h = math.min(sq, cell - yy * sq).clamp(0.0, sq);
      if (w <= 0 || h <= 0) continue;
      canvas.drawRect(
        Rect.fromLTWH(px + xx * sq, py + yy * sq, w, h),
        checker,
      );
    }
  }
}
