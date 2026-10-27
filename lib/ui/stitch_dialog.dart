import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../core/stitcher.dart';

/// 多图拼合对话框：多选图片 → 设置拼合参数 → 生成拼合图纸。
///
/// 返回 [StitchResult]（null = 取消）。转换在对话框内完成后随结果返回，
/// 由调用方装入编辑器。
Future<StitchResult?> showStitchDialog(BuildContext context) {
  return showDialog<StitchResult>(
    context: context,
    builder: (context) => const _StitchDialog(),
  );
}

/// 已选图片条目（解码后的像素 + 展示信息）。
class _StitchImage {
  _StitchImage({
    required this.pixels,
    required this.width,
    required this.height,
    required this.fileName,
    required this.preview,
  });

  final Uint8List pixels;
  final int width;
  final int height;
  final String fileName;
  final ImageProvider preview;
}

class _StitchDialog extends StatefulWidget {
  const _StitchDialog();

  @override
  State<_StitchDialog> createState() => _StitchDialogState();
}

class _StitchDialogState extends State<_StitchDialog> {
  final _images = <_StitchImage>[];

  /// 单张最长边（豆数）。
  double _maxSize = 29;

  /// 每行张数。
  double _columns = 2;

  bool _dither = true;
  bool _working = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 预览总尺寸（与引擎 fitSize 同规则）。
    final (totalW, totalH) = _previewTotalSize();
    return AlertDialog(
      title: const Text('多图拼合'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _working ? null : _pickImages,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(_images.isEmpty
                        ? '选择图片（可多选）'
                        : '已选 ${_images.length} 张 · 点此追加'),
                  ),
                ),
                if (_images.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '清空',
                    onPressed: _working ? null : _clear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // 已选图片缩略图条。
            if (_images.isNotEmpty)
              SizedBox(
                height: 84,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final im = _images[i];
                    return Stack(
                      children: [
                        Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(7),
                            child: Image(
                              image: im.preview,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          right: 0,
                          child: InkWell(
                            onTap: _working ? null : () => _removeAt(i),
                            child: Container(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close, size: 16),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            Text('单张最长边：${_maxSize.round()} 豆',
                style: theme.textTheme.titleSmall),
            Slider(
              value: _maxSize,
              min: 10,
              max: 87,
              divisions: 77,
              label: '${_maxSize.round()}',
              onChanged: _working ? null : (v) => setState(() => _maxSize = v),
            ),
            Text('每行张数：${_columns.round()}',
                style: theme.textTheme.titleSmall),
            Slider(
              value: _columns,
              min: 1,
              max: 5,
              divisions: 4,
              label: '${_columns.round()}',
              onChanged: _working ? null : (v) => setState(() => _columns = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('抖动（Floyd-Steinberg）'),
              value: _dither,
              onChanged: _working ? null : (v) => setState(() => _dither = v),
            ),
            const SizedBox(height: 4),
            Text(
              _images.isEmpty
                  ? '拼合后总尺寸：—'
                  : '拼合后总尺寸：$totalW x $totalH 豆'
                    '（${((totalW + 28) ~/ 29) * ((totalH + 28) ~/ 29)} 块底板）',
              style: theme.textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: (_working || _images.isEmpty) ? null : _stitch,
          icon: _working
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.grid_view),
          label: const Text('生成拼合图纸'),
        ),
      ],
    );
  }

  /// 预览总尺寸（与引擎同规则计算，不执行转换）。
  (int, int) _previewTotalSize() {
    if (_images.isEmpty) return (0, 0);
    final cols = _columns.round().clamp(1, _images.length);
    var cellW = 1;
    var cellH = 1;
    for (final im in _images) {
      final (w, h) = BeadStitcher.fitSize(
          im.width, im.height, _maxSize.round());
      if (w > cellW) cellW = w;
      if (h > cellH) cellH = h;
    }
    final rows = (_images.length + cols - 1) ~/ cols;
    return (cellW * cols, cellH * rows);
  }

  Future<void> _pickImages() async {
    const typeGroup = XTypeGroup(
      label: '图片',
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'],
    );
    final files = await openFiles(acceptedTypeGroups: [typeGroup]);
    if (files.isEmpty) return;
    setState(() {
      _error = null;
      _working = true;
    });
    try {
      for (final file in files) {
        final bytes = await file.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded == null) {
          _error = '无法解码：${file.name}';
          continue;
        }
        _images.add(_StitchImage(
          fileName: file.name,
          width: decoded.width,
          height: decoded.height,
          preview: MemoryImage(bytes),
          pixels: Uint8List.fromList(
              decoded.getBytes(order: img.ChannelOrder.rgba, alpha: 255)),
        ));
      }
    } catch (e) {
      _error = '读取失败：$e';
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _removeAt(int i) => setState(() {
        _images.removeAt(i);
        _error = null;
      });

  void _clear() => setState(() {
        _images.clear();
        _error = null;
      });

  Future<void> _stitch() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      // 转换放 isolate，避免多张大图卡 UI。
      final result = await compute(
        _stitchSync,
        _StitchArgs(
          images: [
            for (final im in _images) (im.pixels, im.width, im.height),
          ],
          options: StitchOptions(
            perImageMaxSize: _maxSize.round(),
            columns: _columns.round(),
            dither: _dither,
          ),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = '拼合失败：$e';
      });
    }
  }
}

/// isolate 参数（compute 需顶层/静态可序列化）。
class _StitchArgs {
  const _StitchArgs({required this.images, required this.options});
  final List<(Uint8List, int, int)> images;
  final StitchOptions options;
}

StitchResult _stitchSync(_StitchArgs args) {
  return BeadStitcher.stitch(images: args.images, options: args.options);
}
