# 拼豆工作室 (pindou_studio)

将图片转换为拼豆图纸的桌面应用（Windows，UI 响应式设计，为移动端移植预留）。

## 架构

单页直入：**打开即编辑器**，无首页流程。

- **编辑器 EditorPage**：参数调节 + 图纸画布 + 统计导出，响应式布局：
  - 宽屏（≥1100px）：三栏（参数 | 画布 | 统计）
  - 中屏（≥700px）：两栏（画布 + 参数/统计切换侧面板）
  - 窄屏（手机）：画布全屏 + 底部工具条弹出面板
- **项目操作**：AppBar 右上角文件夹菜单（新建 / 打开项目…），
  保存按钮 + Ctrl+S；打开项目弹列表选择（名称/尺寸/色数/日期）
- **项目持久化**：每个项目一个 JSON（色号 RLE 压缩）+ 缩略图 PNG，
  存于系统文档目录 `PindouStudio/`；未保存修改时新建/打开先确认

## 功能

- **图片导入**：支持 jpg / png / webp / bmp / gif
- **转换引擎**：面积平均降采样 + 最近色量化 + 可选 Floyd-Steinberg 抖动
- **参数调节**：图纸尺寸（豆数）、亮度、对比度、颜色数量上限
- **图纸预览**：网格画布，色块 + 滚轮缩放、拖拽平移，每 10 格加深线，
  行号/列号标尺与 29 格底板分界虚线，右下角缩放工具条（放大/缩小/适应窗口）。
  大图纸流畅：图纸预光栅化为位图（2x 超采样），缩放平移时 GPU 只变换单张纹理
- **转换加载**：转换期间全屏加载遮罩，图纸在遮罩下完成重绘后一次性呈现
- **手动编辑**：画笔模式（从颜色列表选色后拖动涂色，Bresenham 补插不跳格，
  右键擦除恢复自动转换色），点击单格弹窗换色
- **撤销/重做**：按笔画分组（一次拖动 = 一步），Ctrl+Z / Ctrl+Y 快捷键
- **项目管理**：保存/加载/重命名/删除，脏标记（未保存圆点提示）
- **用量统计**：每种颜色豆数、总豆数、颜色数、所需 29x29 底板数
- **导出**：图纸 PNG（含行列号、底板分界线与颜色图例）、豆数清单 CSV
  （UTF-8 BOM，Excel 直接打开）、按 29x29 底板分板导出多张 PNG

## 内置色卡

约 90 色通用拼豆色卡，按色系分组（白/黑/灰/红/橙/黄/绿/青/蓝/紫/粉/棕/荧光），
每色含编号与中文名称。

## 目录结构

```
lib/
  core/            转换引擎 + 色卡（纯 Dart，无 UI 依赖）
  data/            项目模型（SavedProject，RLE 序列化）+ 文件仓库（ProjectRepository）
  state/           EditorState（编辑器状态：转换/编辑/撤销/保存加载）
  ui/
    editor/        编辑器页（响应式三栏/两栏/窄屏 + 项目菜单/打开对话框）
    pattern_canvas.dart  图纸画布（预光栅化位图渲染）
    export_service.dart  PNG/CSV 导出
  main.dart        入口（应用根直接挂编辑器）
```

## 开发

```bash
flutter pub get
flutter test          # 单元测试（转换引擎 + 项目模型/仓库 + 界面 + 编辑/分板/图片加载 共 47 项）
dart analyze          # 静态分析
flutter run -d windows
flutter build windows --release
```

## 性能优化经验（大图纸流畅度）

本项目在 87x87（7569 格）图纸上调优过程中沉淀的经验，按演进顺序：

### 1. 交互路径与绘制路径分离
- 缩放/平移走 `InteractiveViewer` + `TransformationController`，**绝不 setState**；
  缩放百分比等局部信息用 `ValueNotifier` + `ValueListenableBuilder` 局部刷新。
- 参数输入（宽高/滑块）**确认后才转换**（回车/失焦/onChangeEnd），
  输入过程零重建，避免干扰光标与输入法。

### 2. RepaintBoundary 图层缓存的局限
`RepaintBoundary` 把 CustomPaint 内容缓存为独立图层，缩放平移时合成器只做
变换、不重绘——**但图层本身仍是"数千条绘制指令的录制"**。87x87 图纸的
图层达 2088x2088 逻辑像素（DPR 放大后更大），GPU 每帧采样超大纹理 +
回放大量指令，Windows 上明显卡顿。

### 3. 最终方案：预光栅化位图（关键经验）
把图纸内容**一次性光栅化为 `ui.Image`**（2x 超采样，`picture.toImage` 异步
执行不卡 UI），画布 `paint` 只做一次 `drawImageRect`：

```dart
// 光栅化（图纸变化时执行一次）
final recorder = ui.PictureRecorder();
final canvas = Canvas(recorder, rect);
canvas.scale(2.0); // 2x 超采样，放大到 200% 仍清晰
painter.paint(canvas, size);
final image = await recorder.endRecording().toImage(w, h);

// 绘制（每帧只此一句，GPU 只变换单张纹理）
canvas.drawImageRect(image, srcRect, dstRect, Paint()..filterQuality = FilterQuality.medium);
```

效果：缩放平移的 GPU 负担与图纸尺寸无关，大图也流畅。
代价：放大超过 2x 后位图开始模糊（可按需加"放大时切回矢量精绘"）。

### 4. 转换完成的呈现时序
转换在 `compute` isolate 中执行不卡 UI，但**完成后的大重绘会卡一帧**。
经验：加载遮罩**保持到重绘帧渲染结束**（`addPostFrameCallback`）才移除——
用户看到"加载动画 → 图纸直接出现"，重绘耗时被遮罩完全盖住。
统计面板/颜色列表也在遮罩移除帧才更新，避免同帧大重建。

### 5. 其他有效手段
- 同色连续格子合并为一个 `drawRect`（run-length）
- 网格线合并为两条 `Path`，各一次 `drawPath`
- 标尺文字 `TextPainter` 跨帧静态缓存（同字号同文本只排版一次）
- 颜色列表 `ListView.builder` + `itemExtent` 固定行高（布局零测量）
- 撤销/重做按笔画分组，一次拖动 = 一步，避免逐格通知

### 踩过的坑
- **RepaintBoundary + 视口裁剪冲突**：缓存层必须包含完整内容，
  按视口裁剪会让缩放后缺块
- **image 包多通道解码**：JPEG 输出 3 通道、GIF 输出 1 通道调色板索引，
  必须统一 `getBytes(order: ChannelOrder.rgba, alpha: 255)` 再进转换引擎
- **`endOfFrame` 在测试环境挂起**：无帧调度时永久等待，
  用 `Future.delayed(Duration.zero)` 替代
- **画布色号文字**：以基准字号画进缓存层再被缩放矩阵压缩，
  适应窗口后仅 1.6~3.3px 不可见；本项目最终移除该功能（导出 PNG 保留色号）

## 已知环境问题

项目路径包含非 ASCII 字符（如中文）时，Windows release 构建会因
gen_snapshot 无法读取中文路径而失败。临时解决（拷贝到 ASCII 路径构建）：

```bash
# 1. 准备 ASCII 中转目录并映射盘符
mkdir D:\LvProject\pinDouAscii
subst P: D:\LvProject\pinDouAscii

# 2. 把项目拷到 P 盘（首次或代码更新后同步）
xcopy /E /I /H D:\LvProject\拼豆\pindou_studio P:\pindou_studio

# 3. 删除拷贝来的 build 缓存（CMakeCache 记录原路径，跨盘会报错）
rmdir /s /q P:\pindou_studio\build

# 4. 构建
cd /d P:\pindou_studio
flutter build windows --release

# 5. 产物拷回项目目录后卸载盘符
subst P: /D
```

注意：直接对中文路径项目 `subst` 映射后构建仍会失败（CMake 缓存与
flutter 插件符号链接记录的是原中文路径），必须**物理拷贝**到 ASCII 路径。

构建产物位于 build/windows/x64/runner/Release/pindou_studio.exe。
