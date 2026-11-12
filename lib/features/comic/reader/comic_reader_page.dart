import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/image/image_providers.dart';
import '../../../shared/image/source_image_loader.dart';
import '../../../shared/image/source_image_provider.dart';
import '../../../sources/model/common.dart';
import '../../../sources/model/content.dart';
import '../../../sources/source.dart';
import 'reader_page_image.dart';
import 'reader_preferences.dart';
import 'reader_providers.dart';

/// 漫画阅读器。
///
/// - 章节图片来自 `Source.content(unitId)`，章节列表来自 `Source.detail(itemId)`（打开期间缓存）。
/// - [initialPage] 从 0 开始；超出范围时取最后一页。
/// - 进度通过 [onProgress] 报告；为 null 时使用 [comicReaderProgressSinkProvider]。
class ComicReaderPage extends ConsumerStatefulWidget {
  const ComicReaderPage({
    super.key,
    required this.sourceId,
    required this.itemId,
    required this.unitId,
    this.initialPage = 0,
    this.onProgress,
  });

  final String sourceId;
  final String itemId;
  final String unitId;
  final int initialPage;
  final ComicProgressCallback? onProgress;

  @override
  ConsumerState<ComicReaderPage> createState() => _ComicReaderPageState();
}

/// 翻页意图。
enum _Step { previous, next }

/// 纵向模式下尚未取得图片尺寸时的默认宽高比。
const _defaultAspect = 0.7;
const _trailerExtent = 220.0;
const _pageAnimation = Duration(milliseconds: 220);

class _ComicReaderPageState extends ConsumerState<ComicReaderPage> {
  late String _unitId = widget.unitId;

  /// 章节加载完成后要跳到的页；-1 表示最后一页。
  int? _pendingPage;
  int _page = 0;
  bool _atTrailer = false;
  bool _showToolbar = false;
  ReaderMode? _mode;
  ComicReadingProgress? _lastReported;

  final _focusNode = FocusNode(debugLabel: 'ComicReader');

  // 横向翻页
  PageController? _pageController;
  final _pageZoom = <int, TransformationController>{};
  bool _zoomed = false;

  // 纵向滚动
  ScrollController? _scrollController;
  final _verticalZoom = TransformationController();
  final _aspects = <int, double>{};
  double _viewportWidth = 0;
  ScrollDirection _userDirection = ScrollDirection.idle;

  Offset? _doubleTapPosition;

  @override
  void initState() {
    super.initState();
    _pendingPage = math.max(0, widget.initialPage);
    _verticalZoom.addListener(_onZoomChanged);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _pageController?.dispose();
    _scrollController?.dispose();
    _verticalZoom.dispose();
    _disposePageZoom();
    super.dispose();
  }

  void _disposePageZoom() {
    for (final c in _pageZoom.values) {
      _disposeLater(c);
    }
    _pageZoom.clear();
  }

  /// 控制器可能仍挂在本帧要被替换的组件上，等这一帧结束后再释放。
  void _disposeLater(ChangeNotifier? notifier) {
    if (notifier == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => notifier.dispose());
  }

  // ---------------------------------------------------------------------------
  // 数据

  String get _sourceId => widget.sourceId;

  List<Unit> get _chapters =>
      switch (ref.read(comicReaderDetailProvider(_sourceId, widget.itemId))) {
        AsyncData(:final value) => readingOrder(value),
        _ => const [],
      };

  int get _chapterIndex => _chapters.indexWhere((u) => u.id == _unitId);

  Unit? _neighbor(int delta) {
    final chapters = _chapters;
    final i = _chapterIndex;
    if (i < 0) return null;
    final j = i + delta;
    return j >= 0 && j < chapters.length ? chapters[j] : null;
  }

  List<ImageRef>? get _images =>
      switch (ref.read(comicReaderChapterProvider(_sourceId, _unitId))) {
        AsyncData(:final value) => value.images,
        _ => null,
      };

  SourceImageLoader get _loader => ref.read(sourceImageLoaderProvider);

  SourceImageProvider _provider(ImageRef image) =>
      SourceImageProvider(sourceId: _sourceId, ref: image, loader: _loader);

  ReaderPreferences get _prefs =>
      ref.read(readerSettingsProvider).value ?? const ReaderPreferences();

  // ---------------------------------------------------------------------------
  // 章节与页码

  void _openChapter(Unit unit, {int page = 0}) {
    setState(() {
      _unitId = unit.id;
      _pendingPage = page;
      _page = 0;
      _atTrailer = false;
      _resetControllers();
    });
  }

  void _resetControllers() {
    _disposeLater(_pageController);
    _pageController = null;
    _disposeLater(_scrollController);
    _scrollController = null;
    _disposePageZoom();
    _zoomed = false;
    _aspects.clear();
    _verticalZoom.value = Matrix4.identity();
  }

  /// 章节数据就绪后调用：确定起始页并创建控制器。
  void _ensureControllers(ReaderMode mode, int count) {
    if (_mode != mode) {
      _mode = mode;
      _disposeLater(_pageController);
      _pageController = null;
      _disposeLater(_scrollController);
      _scrollController = null;
      _disposePageZoom();
      _zoomed = false;
      _verticalZoom.value = Matrix4.identity();
      _pendingPage ??= _page;
    }
    if (_pendingPage case final pending?) {
      _pendingPage = null;
      _page = count == 0
          ? 0
          : (pending < 0 || pending >= count ? count - 1 : pending);
      _atTrailer = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _afterPageChanged();
        if (mode == ReaderMode.vertical) _jumpVertical(_page);
      });
    }
    if (mode.isPaged) {
      _pageController ??= PageController(initialPage: _page);
    } else {
      _scrollController ??= ScrollController();
    }
  }

  void _setPage(int page, {bool trailer = false}) {
    if (page == _page && trailer == _atTrailer) return;
    setState(() {
      _page = page;
      _atTrailer = trailer;
    });
    _afterPageChanged();
  }

  void _afterPageChanged() {
    final images = _images;
    if (images == null) return;
    _reportProgress(images.length);
    final n = _prefs.preloadPages;
    for (var i = _page + 1; i <= _page + n && i < images.length; i++) {
      _loader.prefetch(_sourceId, images[i]);
    }
  }

  void _reportProgress(int count) {
    // 起始页尚未应用（章节刚到达、还没构建）时不报告，避免先报一个错误的第 0 页。
    if (count == 0 || _pendingPage != null || _mode == null) return;
    final title = _chapters.where((u) => u.id == _unitId).firstOrNull?.title;
    final progress = ComicReadingProgress(
      sourceId: _sourceId,
      itemId: widget.itemId,
      unitId: _unitId,
      unitTitle: title,
      pageIndex: _page.clamp(0, count - 1),
      pageCount: count,
    );
    if (progress == _lastReported) return;
    _lastReported = progress;
    final ComicProgressCallback sink =
        widget.onProgress ?? ref.read(comicReaderProgressSinkProvider);
    sink(progress);
  }

  /// 读到末尾后的“下一章”意图。
  void _nextChapterIntent({bool explicit = false}) {
    final next = _neighbor(1);
    if (next == null) {
      _toast('已经是最后一章');
      return;
    }
    if (explicit || _prefs.autoNextChapter) _openChapter(next);
  }

  void _previousChapter({bool toLastPage = true}) {
    final prev = _neighbor(-1);
    if (prev == null) {
      _toast('已经是第一章');
      return;
    }
    _openChapter(prev, page: toLastPage ? -1 : 0);
  }

  void _toast(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      );
  }

  // ---------------------------------------------------------------------------
  // 导航（键盘 / 点击区域 / 滚轮 / 工具栏共用）

  void _step(_Step step) {
    final images = _images;
    if (images == null) return;
    final mode = _mode ?? ReaderMode.vertical;
    if (mode.isPaged) {
      final controller = _pageController;
      if (controller == null || !controller.hasClients) return;
      final current = _atTrailer ? images.length : _page;
      if (step == _Step.next) {
        if (current >= images.length) {
          _nextChapterIntent(explicit: true);
        } else {
          controller.animateToPage(
            current + 1,
            duration: _pageAnimation,
            curve: Curves.easeOut,
          );
        }
      } else {
        if (current == 0) {
          _previousChapter();
        } else {
          controller.animateToPage(
            current - 1,
            duration: _pageAnimation,
            curve: Curves.easeOut,
          );
        }
      }
    } else {
      final controller = _scrollController;
      if (controller == null || !controller.hasClients) return;
      final pos = controller.position;
      final delta = pos.viewportDimension * 0.85;
      if (step == _Step.next) {
        if (pos.pixels >= pos.maxScrollExtent - 1) {
          _nextChapterIntent(explicit: true);
        } else {
          controller.animateTo(
            math.min(pos.pixels + delta, pos.maxScrollExtent),
            duration: _pageAnimation,
            curve: Curves.easeOut,
          );
        }
      } else {
        if (pos.pixels <= pos.minScrollExtent + 1) {
          _previousChapter();
        } else {
          controller.animateTo(
            math.max(pos.pixels - delta, pos.minScrollExtent),
            duration: _pageAnimation,
            curve: Curves.easeOut,
          );
        }
      }
    }
  }

  /// 视觉方向“左 / 右”对应的翻页意图（右→左模式下左侧是下一页）。
  _Step _horizontal({required bool left}) {
    final rtl = _mode == ReaderMode.rightToLeft;
    return left != rtl ? _Step.previous : _Step.next;
  }

  void _jumpTo(int page) {
    final images = _images;
    if (images == null || images.isEmpty) return;
    page = page.clamp(0, images.length - 1);
    if ((_mode ?? ReaderMode.vertical).isPaged) {
      _pageController?.jumpToPage(page);
    } else {
      _jumpVertical(page);
      _setPage(page);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final paged = (_mode ?? ReaderMode.vertical).isPaged;
    _Step? step;
    if (key == LogicalKeyboardKey.arrowLeft) {
      step = paged ? _horizontal(left: true) : null;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      step = paged ? _horizontal(left: false) : null;
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      step = _Step.previous;
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown) {
      step = _Step.next;
    } else if (key == LogicalKeyboardKey.space) {
      step = shift ? _Step.previous : _Step.next;
    } else if (key == LogicalKeyboardKey.home) {
      _jumpTo(0);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.end) {
      _jumpTo(1 << 30);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape && _showToolbar) {
      setState(() => _showToolbar = false);
      return KeyEventResult.handled;
    }
    if (step == null) return KeyEventResult.ignored;
    _step(step);
    return KeyEventResult.handled;
  }

  void _onTapUp(TapUpDetails details) {
    final size = context.size;
    if (size == null) return;
    final paged = (_mode ?? ReaderMode.vertical).isPaged;
    final pos = details.localPosition;
    final fraction = paged ? pos.dx / size.width : pos.dy / size.height;
    if (fraction > 1 / 3 && fraction < 2 / 3) {
      setState(() => _showToolbar = !_showToolbar);
      return;
    }
    if (_showToolbar) {
      setState(() => _showToolbar = false);
      return;
    }
    final first = fraction <= 1 / 3;
    _step(
      paged ? _horizontal(left: first) : (first ? _Step.previous : _Step.next),
    );
  }

  void _onDoubleTap() {
    final controller = (_mode ?? ReaderMode.vertical).isPaged
        ? _pageZoom[_page]
        : _verticalZoom;
    final at = _doubleTapPosition;
    if (controller == null || at == null) return;
    if (controller.value.getMaxScaleOnAxis() > 1.01) {
      controller.value = Matrix4.identity();
    } else {
      const s = 2.5;
      controller.value = Matrix4.identity()
        ..translateByDouble(-at.dx * (s - 1), -at.dy * (s - 1), 0, 1)
        ..scaleByDouble(s, s, 1, 1);
    }
  }

  void _onZoomChanged() {
    final controller = (_mode ?? ReaderMode.vertical).isPaged
        ? _pageZoom[_page]
        : _verticalZoom;
    final zoomed = (controller?.value.getMaxScaleOnAxis() ?? 1) > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  TransformationController _zoomFor(int page) => _pageZoom.putIfAbsent(
    page,
    () => TransformationController()..addListener(_onZoomChanged),
  );

  // ---------------------------------------------------------------------------
  // 纵向模式的几何

  double _extentOf(int index, int count) {
    if (index >= count) return _trailerExtent;
    final w = _viewportWidth;
    if (w <= 0) return 400;
    return w / (_aspects[index] ?? _defaultAspect);
  }

  double _offsetOf(int page, int count) {
    var y = 0.0;
    for (var i = 0; i < page && i < count; i++) {
      y += _extentOf(i, count);
    }
    return y;
  }

  void _jumpVertical(int page) {
    final c = _scrollController;
    final images = _images;
    if (c == null || !c.hasClients || images == null) return;
    c.jumpTo(
      _offsetOf(page, images.length).clamp(0, c.position.maxScrollExtent),
    );
  }

  void _onAspect(String unitId, int index, double aspect, int count) {
    if (unitId != _unitId) return;
    // 缓存命中时图片可能在列表布局过程中同步就绪，此时不能 setState，推迟到帧末。
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.idle &&
        phase != SchedulerPhase.postFrameCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onAspect(unitId, index, aspect, count);
      });
      return;
    }
    final old = _aspects[index];
    if (old != null && (old - aspect).abs() < 1e-3) return;
    final c = _scrollController;
    // 位于视口上方的页高度变化时，保持当前看到的内容不跳动。
    var shift = 0.0;
    if (c != null && c.hasClients && _viewportWidth > 0) {
      final end = _offsetOf(index + 1, count);
      if (end <= c.offset) {
        shift =
            _viewportWidth / aspect - _viewportWidth / (old ?? _defaultAspect);
      }
    }
    setState(() => _aspects[index] = aspect);
    if (shift != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (c!.hasClients) c.jumpTo(c.offset + shift);
      });
    }
  }

  bool _onVerticalScroll(ScrollNotification n, int count) {
    if (n.depth != 0) return false;
    if (n is UserScrollNotification) {
      _userDirection = n.direction;
    } else if (n is ScrollUpdateNotification) {
      // 当前页 = 视口顶部往下 1/4 处所在的页。
      final probe = n.metrics.pixels + n.metrics.viewportDimension * 0.25;
      var y = 0.0;
      var page = count;
      for (var i = 0; i < count; i++) {
        y += _extentOf(i, count);
        if (probe < y) {
          page = i;
          break;
        }
      }
      final trailer = page >= count;
      _setPage(trailer ? count - 1 : page, trailer: trailer);
    } else if (n is OverscrollNotification &&
        n.overscroll > 0 &&
        _userDirection == ScrollDirection.reverse) {
      _nextChapterIntent();
    }
    return false;
  }

  void _onVerticalWheel(PointerSignalEvent e) {
    final c = _scrollController;
    if (e is! PointerScrollEvent || c == null || !c.hasClients) return;
    if (e.scrollDelta.dy > 0 && c.position.extentAfter < 1) {
      _nextChapterIntent();
    }
  }

  // ---------------------------------------------------------------------------
  // 构建

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(readerSettingsProvider);
    final chapter = ref.watch(comicReaderChapterProvider(_sourceId, _unitId));
    final detail = ref.watch(
      comicReaderDetailProvider(_sourceId, widget.itemId),
    );
    // 章节列表晚于内容到达时，补报带标题的进度。
    ref.listen(comicReaderDetailProvider(_sourceId, widget.itemId), (_, next) {
      if (next is AsyncData && _images != null) {
        _reportProgress(_images!.length);
      }
    });

    final chapters = switch (detail) {
      AsyncData(:final value) => readingOrder(value),
      _ => const <Unit>[],
    };
    final unit = chapters.where((u) => u.id == _unitId).firstOrNull;

    final Widget body;
    if (settings case AsyncData(value: final prefs)) {
      body = switch (chapter) {
        AsyncData(:final value) => _buildReader(prefs, value.images),
        AsyncError(:final error) => _ErrorView(
          error: error,
          onRetry: () =>
              ref.invalidate(comicReaderChapterProvider(_sourceId, _unitId)),
        ),
        _ => const _Loading(),
      };
    } else {
      body = const _Loading();
    }

    final images = chapter.value?.images;
    return Theme(
      data: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Theme.of(context).colorScheme.primary,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            children: [
              Positioned.fill(child: body),
              if (images != null && images.isNotEmpty && !_showToolbar)
                Positioned(
                  right: 12,
                  bottom: 8,
                  child: SafeArea(
                    child: _PageBadge(
                      text: _atTrailer
                          ? '本章完'
                          : '${_page + 1} / ${images.length}',
                    ),
                  ),
                ),
              if (_showToolbar) ...[
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: _TopBar(
                    title: unit?.title ?? '',
                    subtitle: detail.value?.title,
                    prefs: settings.value ?? const ReaderPreferences(),
                    onBack: () => Navigator.of(context).maybePop(),
                    onMode: (m) =>
                        ref.read(readerSettingsProvider.notifier).setMode(m),
                    onAutoNext: (v) => ref
                        .read(readerSettingsProvider.notifier)
                        .change((p) => p.copyWith(autoNextChapter: v)),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _BottomBar(
                    page: _page,
                    count: images?.length ?? 0,
                    rtl: _mode == ReaderMode.rightToLeft,
                    hasPrevious: _neighbor(-1) != null,
                    hasNext: _neighbor(1) != null,
                    onJump: _jumpTo,
                    onPrevious: () => _previousChapter(toLastPage: false),
                    onNext: () => _nextChapterIntent(explicit: true),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReader(ReaderPreferences prefs, List<ImageRef> images) {
    _ensureControllers(prefs.mode, images.length);
    if (images.isEmpty) {
      return _EndOfChapter(
        message: '本章没有图片',
        next: _neighbor(1),
        onNext: () => _nextChapterIntent(explicit: true),
      );
    }
    final reader = prefs.mode.isPaged
        ? _buildPaged(prefs.mode, images)
        : _buildVertical(images);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      onDoubleTapDown: (d) => _doubleTapPosition = d.localPosition,
      onDoubleTap: _onDoubleTap,
      child: reader,
    );
  }

  Widget _buildPaged(ReaderMode mode, List<ImageRef> images) {
    final count = images.length;
    return PageView.builder(
      key: ValueKey('paged-$_unitId-${mode.name}'),
      controller: _pageController,
      reverse: mode == ReaderMode.rightToLeft,
      physics: _zoomed
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      itemCount: count + 1,
      onPageChanged: (i) {
        _pageZoom[_page]?.value = Matrix4.identity();
        _setPage(math.min(i, count - 1), trailer: i >= count);
        if (i >= count && _prefs.autoNextChapter && _neighbor(1) != null) {
          _nextChapterIntent();
        }
      },
      itemBuilder: (context, i) {
        if (i >= count) {
          return _EndOfChapter(
            message: '本章完',
            next: _neighbor(1),
            onNext: () => _nextChapterIntent(explicit: true),
          );
        }
        return _WheelCatcher(
          onWheel: (dy) => _step(dy > 0 ? _Step.next : _Step.previous),
          child: InteractiveViewer(
            transformationController: _zoomFor(i),
            maxScale: 4,
            child: ReaderPageImage(
              key: ValueKey('page-$_unitId-$i'),
              image: _provider(images[i]),
              pageNumber: i + 1,
            ),
          ),
        );
      },
    );
  }

  Widget _buildVertical(List<ImageRef> images) {
    final count = images.length;
    final unitId = _unitId;
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        return Listener(
          onPointerSignal: _onVerticalWheel,
          child: InteractiveViewer(
            transformationController: _verticalZoom,
            maxScale: 4,
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) => _onVerticalScroll(n, count),
              child: ListView.builder(
                key: ValueKey('vertical-$_unitId'),
                controller: _scrollController,
                physics: const ClampingScrollPhysics(),
                scrollCacheExtent: const ScrollCacheExtent.viewport(1),
                itemCount: count + 1,
                itemExtentBuilder: (i, _) => _extentOf(i, count),
                itemBuilder: (context, i) {
                  if (i >= count) {
                    return _EndOfChapter(
                      message: '本章完',
                      next: _neighbor(1),
                      onNext: () => _nextChapterIntent(explicit: true),
                    );
                  }
                  return ReaderPageImage(
                    key: ValueKey('page-$_unitId-$i'),
                    image: _provider(images[i]),
                    pageNumber: i + 1,
                    fit: BoxFit.fitWidth,
                    onAspectRatio: (a) => _onAspect(unitId, i, a, count),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 抢先认领鼠标滚轮事件（比外层 [InteractiveViewer] 先注册到 pointerSignalResolver），
/// 使横向模式下滚轮用于翻页而不是缩放。
class _WheelCatcher extends StatelessWidget {
  const _WheelCatcher({required this.onWheel, required this.child});

  final ValueChanged<double> onWheel;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerSignal: (event) {
      if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) return;
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (e) => onWheel((e as PointerScrollEvent).scrollDelta.dy),
      );
    },
    child: child,
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator(color: Colors.white54));
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final message = switch (error) {
      SourceException(code: SourceErrorCode.challenge) =>
        '站点要求人机验证，请稍后在源的网页中手动完成后重试',
      SourceException(code: SourceErrorCode.loginRequired) => '需要登录',
      SourceException(code: SourceErrorCode.hostNotAllowed) => '源请求了白名单外的地址',
      SourceException(:final message?) => message,
      _ => '$error',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white54, size: 40),
            const SizedBox(height: 12),
            Text(
              '章节加载失败\n$message',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _EndOfChapter extends StatelessWidget {
  const _EndOfChapter({
    required this.message,
    required this.next,
    required this.onNext,
  });

  final String message;
  final Unit? next;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final next = this.next;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 12),
          if (next != null)
            FilledButton.tonal(
              onPressed: onNext,
              child: Text('下一章：${next.title}'),
            )
          else
            const Text('已经是最后一章', style: TextStyle(color: Colors.white38)),
        ],
      ),
    );
  }
}

class _PageBadge extends StatelessWidget {
  const _PageBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    ),
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.prefs,
    required this.onBack,
    required this.onMode,
    required this.onAutoNext,
  });

  final String title;
  final String? subtitle;
  final ReaderPreferences prefs;
  final VoidCallback onBack;
  final ValueChanged<ReaderMode> onMode;
  final ValueChanged<bool> onAutoNext;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black87,
    child: SafeArea(
      bottom: false,
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back),
            onPressed: onBack,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle case final s?)
                  Text(
                    s,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          PopupMenuButton<Object>(
            tooltip: '阅读设置',
            icon: const Icon(Icons.tune),
            onSelected: (v) => switch (v) {
              final ReaderMode m => onMode(m),
              _ => onAutoNext(!prefs.autoNextChapter),
            },
            itemBuilder: (_) => [
              for (final m in ReaderMode.values)
                CheckedPopupMenuItem(
                  value: m,
                  checked: prefs.mode == m,
                  child: Text(m.label),
                ),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(
                value: #autoNext,
                checked: prefs.autoNextChapter,
                child: const Text('自动进入下一章'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.page,
    required this.count,
    required this.rtl,
    required this.hasPrevious,
    required this.hasNext,
    required this.onJump,
    required this.onPrevious,
    required this.onNext,
  });

  final int page;
  final int count;
  final bool rtl;
  final bool hasPrevious;
  final bool hasNext;
  final ValueChanged<int> onJump;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black87,
    child: SafeArea(
      top: false,
      child: Row(
        children: [
          IconButton(
            tooltip: '上一章',
            icon: const Icon(Icons.skip_previous),
            onPressed: hasPrevious ? onPrevious : null,
          ),
          Expanded(
            child: count > 1
                ? Directionality(
                    textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
                    child: _PageSlider(
                      page: page,
                      count: count,
                      onJump: onJump,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          SizedBox(
            width: 64,
            child: Text(
              count == 0 ? '' : '${page + 1} / $count',
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            tooltip: '下一章',
            icon: const Icon(Icons.skip_next),
            onPressed: hasNext ? onNext : null,
          ),
        ],
      ),
    ),
  );
}

/// 拖动时只更新标签，松手后才跳页。
class _PageSlider extends StatefulWidget {
  const _PageSlider({
    required this.page,
    required this.count,
    required this.onJump,
  });

  final int page;
  final int count;
  final ValueChanged<int> onJump;

  @override
  State<_PageSlider> createState() => _PageSliderState();
}

class _PageSliderState extends State<_PageSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final max = (widget.count - 1).toDouble();
    final value = (_dragging ?? widget.page.toDouble()).clamp(0.0, max);
    return Slider(
      value: value,
      max: max,
      divisions: widget.count - 1,
      label: '${value.round() + 1}',
      onChanged: (v) => setState(() => _dragging = v),
      onChangeEnd: (v) {
        setState(() => _dragging = null);
        widget.onJump(v.round());
      },
    );
  }
}
