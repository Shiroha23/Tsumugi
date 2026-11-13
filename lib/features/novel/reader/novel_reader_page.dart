import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/image/source_image.dart';
import '../../../shared/widgets/source_error_view.dart';
import '../../../sources/model/common.dart';
import '../../../sources/model/content.dart';
import '../../common/reading_order.dart';
import '../../../shared/novel/novel_document.dart';
import 'novel_layout.dart';
import 'novel_reader_preferences.dart';
import 'novel_reader_providers.dart';

/// 小说阅读器。
///
/// - 正文来自 `Source.content(unitId)`，按 `nextPageId` 拼接章节内分页（[novelReaderChapterProvider]）。
/// - 两种模式：上下滚动、左右翻页（按屏幕分页排版）。
/// - [initialPosition] 为章节内字符偏移（docs/source-spec.md §2.2.1）；进度通过 [onProgress]
///   报告，为 null 时使用 [novelReaderProgressSinkProvider]。
class NovelReaderPage extends ConsumerStatefulWidget {
  const NovelReaderPage({
    super.key,
    required this.sourceId,
    required this.itemId,
    required this.unitId,
    this.initialPosition = 0,
    this.onProgress,
  });

  final String sourceId;
  final String itemId;
  final String unitId;
  final int initialPosition;
  final NovelProgressCallback? onProgress;

  @override
  ConsumerState<NovelReaderPage> createState() => _NovelReaderPageState();
}

enum _Step { previous, next }

const _pageAnimation = Duration(milliseconds: 220);

/// 翻页模式下页眉 / 页脚的高度。
const _headerExtent = 28.0;
const _footerExtent = 28.0;

/// 当前阅读位置（供进度条与页脚使用，滚动时不必重建整章）。
typedef _Progress = ({int position, bool atEnd});

class _NovelReaderPageState extends ConsumerState<NovelReaderPage> {
  late String _unitId = widget.unitId;

  /// 章节排版完成后要跳到的位置；-1 表示章节末尾。
  int? _pendingPosition;

  /// 当前位置（章节内字符偏移）。重新排版（改字号、改窗口大小）时据此保持位置。
  int _position = 0;
  final _progress = ValueNotifier<_Progress>((position: 0, atEnd: false));

  bool _showToolbar = false;
  NovelReaderMode? _mode;
  NovelReaderPreferences? _layoutPrefs;
  NovelReadingProgress? _lastReported;

  final _focusNode = FocusNode(debugLabel: 'NovelReader');

  // 翻页模式
  PageController? _pageController;
  List<NovelPage>? _pages;
  Object? _pagesKey;

  /// 滚动模式上次排版时的宽度与文字缩放；变化后（改窗口大小、旋转）按字符偏移恢复位置。
  (double, TextScaler)? _scrollLayout;
  Size _pageArea = Size.zero;
  int _pageIndex = 0;
  bool _onTrailer = false;

  // 滚动模式
  ScrollController? _scrollController;
  final _contentKey = GlobalKey(debugLabel: 'novel-content');
  List<GlobalKey> _blockKeys = const [];

  @override
  void initState() {
    super.initState();
    _pendingPosition = math.max(0, widget.initialPosition);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _pageController?.dispose();
    _scrollController?.dispose();
    _progress.dispose();
    super.dispose();
  }

  void _disposeLater(ChangeNotifier? notifier) {
    if (notifier == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => notifier.dispose());
  }

  // ---------------------------------------------------------------------------
  // 数据

  String get _sourceId => widget.sourceId;

  AsyncValue<Detail> get _detail =>
      ref.read(novelReaderDetailProvider(_sourceId, widget.itemId));

  List<Unit> get _chapters => switch (_detail) {
    AsyncData(:final value) => readingOrder(value, _unitId),
    _ => const [],
  };

  Unit? _neighbor(int delta) {
    final chapters = _chapters;
    final i = chapters.indexWhere((u) => u.id == _unitId);
    if (i < 0) return null;
    final j = i + delta;
    return j >= 0 && j < chapters.length ? chapters[j] : null;
  }

  NovelChapter? get _chapter => ref
      .read(novelReaderChapterProvider(_sourceId, widget.itemId, _unitId))
      .value;

  NovelReaderPreferences get _prefs =>
      ref.read(novelReaderSettingsProvider).value ??
      const NovelReaderPreferences();

  NovelReaderMode get _currentMode => _mode ?? _prefs.mode;

  // ---------------------------------------------------------------------------
  // 章节与位置

  void _openChapter(Unit unit, {int position = 0}) {
    setState(() {
      _unitId = unit.id;
      _pendingPosition = position;
      _position = 0;
      _onTrailer = false;
      _resetControllers();
    });
    _progress.value = (position: 0, atEnd: false);
  }

  void _resetControllers() {
    _disposeLater(_pageController);
    _pageController = null;
    _disposeLater(_scrollController);
    _scrollController = null;
    _pages = null;
    _pagesKey = null;
    _scrollLayout = null;
    _pageIndex = 0;
  }

  void _setPosition(int position, {required bool atEnd}) {
    _position = position;
    _progress.value = (position: position, atEnd: atEnd);
    _report();
  }

  void _report() {
    final chapter = _chapter;
    if (chapter == null || _pendingPosition != null || _mode == null) return;
    final title = _chapters.where((u) => u.id == _unitId).firstOrNull?.title;
    final p = _progress.value;
    final progress = NovelReadingProgress(
      sourceId: _sourceId,
      itemId: widget.itemId,
      unitId: _unitId,
      unitTitle: title,
      position: p.position.clamp(0, chapter.length),
      length: chapter.length,
      atEnd: p.atEnd,
    );
    if (progress == _lastReported) return;
    _lastReported = progress;
    final NovelProgressCallback sink =
        widget.onProgress ?? ref.read(novelReaderProgressSinkProvider);
    sink(progress);
  }

  void _retryChapters() =>
      ref.invalidate(novelReaderDetailProvider(_sourceId, widget.itemId));

  bool _chaptersUnavailable() {
    switch (_detail) {
      case AsyncError():
        _retryChapters();
        _toast('章节列表加载失败，正在重试');
        return true;
      case AsyncData():
        return false;
      default:
        _toast('正在获取章节列表');
        return true;
    }
  }

  void _nextChapter() {
    if (_chaptersUnavailable()) return;
    final next = _neighbor(1);
    if (next == null) {
      _toast('已经是最后一章');
      return;
    }
    _openChapter(next);
  }

  void _previousChapter({bool toEnd = true}) {
    if (_chaptersUnavailable()) return;
    final prev = _neighbor(-1);
    if (prev == null) {
      _toast('已经是第一章');
      return;
    }
    _openChapter(prev, position: toEnd ? -1 : 0);
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
    if (_chapter == null) return;
    if (_currentMode == NovelReaderMode.paged) {
      final c = _pageController;
      final pages = _pages;
      if (c == null || !c.hasClients || pages == null) return;
      final current = _onTrailer ? pages.length : _pageIndex;
      if (step == _Step.next) {
        if (current >= pages.length) {
          _nextChapter();
        } else {
          c.animateToPage(
            current + 1,
            duration: _pageAnimation,
            curve: Curves.easeOut,
          );
        }
      } else if (current == 0) {
        _previousChapter();
      } else {
        c.animateToPage(
          current - 1,
          duration: _pageAnimation,
          curve: Curves.easeOut,
        );
      }
      return;
    }
    final c = _scrollController;
    if (c == null || !c.hasClients) return;
    final pos = c.position;
    final delta = pos.viewportDimension * 0.85;
    if (step == _Step.next) {
      if (pos.pixels >= pos.maxScrollExtent - 1) {
        _nextChapter();
      } else {
        c.animateTo(
          math.min(pos.pixels + delta, pos.maxScrollExtent),
          duration: _pageAnimation,
          curve: Curves.easeOut,
        );
      }
    } else if (pos.pixels <= pos.minScrollExtent + 1) {
      _previousChapter();
    } else {
      c.animateTo(
        math.max(pos.pixels - delta, pos.minScrollExtent),
        duration: _pageAnimation,
        curve: Curves.easeOut,
      );
    }
  }

  /// 跳到章节开头 / 末尾。
  void _jumpToEdge({required bool end}) {
    if (_currentMode == NovelReaderMode.paged) {
      final pages = _pages;
      if (pages == null || pages.isEmpty) return;
      _pageController?.jumpToPage(end ? pages.length - 1 : 0);
    } else {
      final c = _scrollController;
      if (c == null || !c.hasClients) return;
      c.jumpTo(end ? c.position.maxScrollExtent : 0);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    _Step? step;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      step = _Step.previous;
    } else if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown) {
      step = _Step.next;
    } else if (key == LogicalKeyboardKey.space) {
      step = shift ? _Step.previous : _Step.next;
    } else if (key == LogicalKeyboardKey.home) {
      _jumpToEdge(end: false);
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.end) {
      _jumpToEdge(end: true);
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
    final paged = _currentMode == NovelReaderMode.paged;
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
    _step(fraction <= 1 / 3 ? _Step.previous : _Step.next);
  }

  /// 进度条：翻页模式为页码，滚动模式为滚动比例。
  void _seek(double value) {
    if (_currentMode == NovelReaderMode.paged) {
      _pageController?.jumpToPage(value.round());
    } else {
      final c = _scrollController;
      if (c == null || !c.hasClients) return;
      c.jumpTo(value * c.position.maxScrollExtent);
    }
  }

  // ---------------------------------------------------------------------------
  // 滚动模式的位置

  /// 视口顶部所在的字符偏移，以及是否已看到章节末尾。
  _Progress? _scrollProgress(NovelChapter chapter) {
    final c = _scrollController;
    final content = _contentKey.currentContext?.findRenderObject();
    if (c == null || !c.hasClients || content is! RenderBox) return null;
    final top = c.offset;
    final bottom = top + c.position.viewportDimension;
    int? position;
    var lastBottom = 0.0;
    for (var i = 0; i < chapter.blocks.length && i < _blockKeys.length; i++) {
      final box = _blockKeys[i].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero, ancestor: content).dy;
      lastBottom = y + box.size.height;
      if (position == null && lastBottom > top + 1) {
        var offset = 0;
        final block = chapter.blocks[i];
        if (block is NovelParagraph && box is RenderParagraph && top > y) {
          final indent = NovelTextStyles.indented(block, 0)
              ? novelIndent.length
              : 0;
          final p = box.getPositionForOffset(Offset(0, top - y));
          offset = (p.offset - indent).clamp(0, block.length);
        }
        position = top <= 1 ? 0 : chapter.startOf(i) + offset;
      }
    }
    return (
      position: position ?? chapter.length,
      atEnd: lastBottom <= bottom + 1,
    );
  }

  void _jumpScrollTo(NovelChapter chapter, int position) {
    final c = _scrollController;
    final content = _contentKey.currentContext?.findRenderObject();
    if (c == null || !c.hasClients || content is! RenderBox) return;
    final max = c.position.maxScrollExtent;
    if (position < 0) {
      c.jumpTo(max);
      return;
    }
    if (position == 0 || chapter.blocks.isEmpty) {
      c.jumpTo(0);
      return;
    }
    final (i, offset) = chapter.locate(position);
    final box = _blockKeys[i].currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    var y = box.localToGlobal(Offset.zero, ancestor: content).dy;
    final block = chapter.blocks[i];
    if (block is NovelParagraph && box is RenderParagraph) {
      final indent = NovelTextStyles.indented(block, 0)
          ? novelIndent.length
          : 0;
      y += box
          .getOffsetForCaret(
            TextPosition(offset: offset == 0 ? 0 : offset + indent),
            Rect.zero,
          )
          .dy;
    }
    c.jumpTo(y.clamp(0, max));
  }

  bool _onScroll(ScrollNotification n, NovelChapter chapter) {
    if (n.depth != 0 || _pendingPosition != null) return false;
    if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      if (_scrollProgress(chapter) case final p?) {
        _setPosition(p.position, atEnd: p.atEnd);
      }
    }
    return false;
  }

  /// 滚动模式：排版完成后应用待跳转的位置。
  void _applyScrollPending(NovelChapter chapter) {
    final pending = _pendingPosition;
    if (pending == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingPosition != pending) return;
      if (_chapter != chapter) return;
      _jumpScrollTo(chapter, pending);
      _pendingPosition = null;
      if (_scrollProgress(chapter) case final p?) {
        // 恢复到的位置以记录值为准（视口顶部取到的偏移可能落在行首）。
        _setPosition(
          pending >= 0 && !p.atEnd ? pending : p.position,
          atEnd: p.atEnd,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 翻页模式

  List<NovelPage> _paginate(
    NovelChapter chapter,
    NovelTextStyles styles,
    Size area,
  ) {
    final key = (
      chapter,
      styles.prefs.fontSize,
      styles.prefs.lineHeight,
      styles.prefs.paragraphSpacing,
      styles.prefs.margin,
      styles.prefs.font,
      styles.textScaler,
      area,
    );
    _pageArea = area;
    final cached = _pages;
    if (cached != null && key == _pagesKey) return cached;
    final pages = paginateNovel(chapter, styles, area);
    _pages = pages;
    _pagesKey = key;
    final pending = _pendingPosition;
    final target = pending == null
        ? novelPageOf(pages, _position)
        : (pending < 0 ? pages.length - 1 : novelPageOf(pages, pending));
    _pageIndex = math.max(0, target);
    _onTrailer = false;
    final c = _pageController;
    if (c == null) {
      _pageController = PageController(initialPage: _pageIndex);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && c.hasClients) c.jumpToPage(_pageIndex);
      });
    }
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pendingPosition != pending || _pages != pages) return;
        _pendingPosition = null;
        final start = pages.isEmpty ? 0 : pages[_pageIndex].start;
        _setPosition(
          pending > 0
              ? math.max(start, math.min(pending, chapter.length))
              : start,
          atEnd: _pageIndex >= pages.length - 1,
        );
      });
    }
    return pages;
  }

  void _onPageChanged(int i, List<NovelPage> pages, NovelChapter chapter) {
    if (_pendingPosition != null) return;
    if (i >= pages.length) {
      _onTrailer = true;
      _setPosition(chapter.length, atEnd: true);
      if (_detail is AsyncData && _neighbor(1) != null) _nextChapter();
      return;
    }
    _onTrailer = false;
    _pageIndex = i;
    _setPosition(pages[i].start, atEnd: i >= pages.length - 1);
  }

  // ---------------------------------------------------------------------------
  // 构建

  void _ensureMode(NovelReaderPreferences prefs) {
    if (_mode != prefs.mode) {
      if (_mode != null) _pendingPosition ??= _position;
      _mode = prefs.mode;
      _resetControllers();
    }
    final layout = _layoutPrefs;
    if (layout != null &&
        !layout.sameLayout(prefs) &&
        prefs.mode == NovelReaderMode.scroll) {
      _pendingPosition ??= _position;
    }
    _layoutPrefs = prefs;
    if (prefs.mode == NovelReaderMode.scroll) {
      _scrollController ??= ScrollController();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(novelReaderSettingsProvider);
    final detail = ref.watch(
      novelReaderDetailProvider(_sourceId, widget.itemId),
    );
    final chapterAsync = ref.watch(
      novelReaderChapterProvider(_sourceId, widget.itemId, _unitId),
    );
    // 章节列表晚于正文到达时，补报带标题的进度。
    ref.listen(novelReaderDetailProvider(_sourceId, widget.itemId), (_, next) {
      if (next is AsyncData) _report();
    });

    final prefs = settings.value ?? const NovelReaderPreferences();
    final theme = prefs.theme;
    final chapters = switch (detail) {
      AsyncData(:final value) => readingOrder(value, _unitId),
      _ => const <Unit>[],
    };
    final unit = chapters.where((u) => u.id == _unitId).firstOrNull;
    final styles = NovelTextStyles(
      prefs,
      textScaler: MediaQuery.textScalerOf(context),
    );

    final Widget body;
    if (settings is AsyncData) {
      body = switch (chapterAsync) {
        AsyncData(:final value) => _buildReader(styles, value, unit),
        AsyncError(:final error) => SourceErrorView(
          error: error,
          sourceId: _sourceId,
          onRetry: () => ref.invalidate(
            novelReaderChapterProvider(_sourceId, widget.itemId, _unitId),
          ),
        ),
        _ => const Center(child: CircularProgressIndicator()),
      };
    } else {
      body = const Center(child: CircularProgressIndicator());
    }

    final chapter = chapterAsync.value;
    // 正文无法显示（加载中 / 失败 / 空章节）时没有点击区域可以呼出工具栏，
    // 始终显示工具栏，保证能返回、换章或打开目录。
    final readable =
        settings is AsyncData &&
        chapter != null &&
        chapter.blocks.isNotEmpty &&
        chapterAsync is AsyncData;
    final showToolbar = _showToolbar || !readable;
    return Theme(
      data: ThemeData(
        brightness: theme.brightness,
        colorSchemeSeed: Theme.of(context).colorScheme.primary,
      ),
      child: Scaffold(
        backgroundColor: theme.background,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            children: [
              Positioned.fill(child: SafeArea(child: body)),
              if (showToolbar) ...[
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: _TopBar(
                    title: unit?.title ?? '',
                    subtitle: detail.value?.title,
                    onBack: () => Navigator.of(context).maybePop(),
                    onContents: () => _showContents(chapters),
                    onSettings: _showSettings,
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _BottomBar(
                    progress: _progress,
                    chapterLength: chapter?.length ?? 0,
                    pageCount: prefs.mode == NovelReaderMode.paged
                        ? _pages?.length
                        : null,
                    pageIndex: () => _pageIndex,
                    scrollFraction: () {
                      final c = _scrollController;
                      if (c == null ||
                          !c.hasClients ||
                          !c.position.hasContentDimensions) {
                        return 0;
                      }
                      final max = c.position.maxScrollExtent;
                      return max <= 0 ? 0 : (c.offset / max).clamp(0, 1);
                    },
                    hasPrevious: _neighbor(-1) != null || detail is AsyncError,
                    hasNext: _neighbor(1) != null || detail is AsyncError,
                    onSeek: _seek,
                    onPrevious: () => _previousChapter(toEnd: false),
                    onNext: _nextChapter,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReader(
    NovelTextStyles styles,
    NovelChapter chapter,
    Unit? unit,
  ) {
    _ensureMode(styles.prefs);
    if (chapter.blocks.isEmpty) {
      _pendingPosition = null;
      return _endOfChapter(styles, '本章没有内容');
    }
    final reader = styles.prefs.mode == NovelReaderMode.paged
        ? _buildPaged(styles, chapter, unit)
        : _buildScroll(styles, chapter, unit);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      child: reader,
    );
  }

  Widget _endOfChapter(NovelTextStyles styles, String message) => _EndOfChapter(
    message: message,
    color: styles.prefs.theme.muted,
    chapters: _detail,
    next: _neighbor(1),
    onNext: _nextChapter,
    onRetryChapters: _retryChapters,
  );

  Widget _block(
    NovelTextStyles styles,
    NovelChapter chapter,
    int i, {
    Key? key,
  }) {
    return switch (chapter.blocks[i]) {
      final NovelParagraph p => RichText(
        key: key,
        text: styles.paragraph(p),
        textScaler: styles.textScaler,
      ),
      final NovelImage img => KeyedSubtree(
        key: key,
        child: _NovelImageView(
          sourceId: _sourceId,
          image: ImageRef(url: img.url, headers: chapter.imageHeaders),
          alt: img.alt,
        ),
      ),
      NovelDivider() => SizedBox(
        key: key,
        height: styles.dividerExtent,
        child: Center(child: Divider(color: styles.prefs.theme.muted)),
      ),
    };
  }

  Widget _buildScroll(
    NovelTextStyles styles,
    NovelChapter chapter,
    Unit? unit,
  ) {
    if (_blockKeys.length != chapter.blocks.length) {
      _blockKeys = [
        for (var i = 0; i < chapter.blocks.length; i++)
          GlobalKey(debugLabel: 'novel-block-$i'),
      ];
    }
    final gap = styles.paragraphGap;
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = (constraints.maxWidth, styles.textScaler);
        if (_scrollLayout != null && _scrollLayout != layout) {
          _pendingPosition ??= _position;
        }
        _scrollLayout = layout;
        _applyScrollPending(chapter);
        return _scrollView(styles, chapter, unit, gap);
      },
    );
  }

  Widget _scrollView(
    NovelTextStyles styles,
    NovelChapter chapter,
    Unit? unit,
    double gap,
  ) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(n, chapter),
      child: SingleChildScrollView(
        key: ValueKey('scroll-$_unitId'),
        controller: _scrollController,
        child: Padding(
          key: _contentKey,
          padding: styles.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 章节列表晚到时标题行也已占位，正文不会因此下移。
              RichText(
                text: TextSpan(
                  text: unit?.title ?? '',
                  style: styles.chapterTitle,
                ),
                textScaler: styles.textScaler,
              ),
              SizedBox(height: gap + styles.prefs.fontSize),
              for (var i = 0; i < chapter.blocks.length; i++) ...[
                if (i > 0) SizedBox(height: gap),
                _block(styles, chapter, i, key: _blockKeys[i]),
              ],
              const SizedBox(height: 32),
              SizedBox(height: 160, child: _endOfChapter(styles, '本章完')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaged(NovelTextStyles styles, NovelChapter chapter, Unit? unit) {
    final pad = styles.padding;
    final muted = TextStyle(color: styles.prefs.theme.muted, fontSize: 12);
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = Size(
          constraints.maxWidth - pad.horizontal,
          constraints.maxHeight - pad.vertical - _headerExtent - _footerExtent,
        );
        final pages = _paginate(chapter, styles, area);
        return Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent || event.scrollDelta.dy == 0) {
              return;
            }
            GestureBinding.instance.pointerSignalResolver.register(
              event,
              (e) => _step(
                (e as PointerScrollEvent).scrollDelta.dy > 0
                    ? _Step.next
                    : _Step.previous,
              ),
            );
          },
          child: PageView.builder(
            key: ValueKey('paged-$_unitId'),
            controller: _pageController,
            itemCount: pages.length + 1,
            onPageChanged: (i) => _onPageChanged(i, pages, chapter),
            itemBuilder: (context, i) {
              if (i >= pages.length) return _endOfChapter(styles, '本章完');
              return Padding(
                padding: pad,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: _headerExtent,
                      child: Text(
                        unit?.title ?? '',
                        style: muted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.topLeft,
                          maxHeight: double.infinity,
                          child: _pageContent(styles, chapter, pages[i]),
                        ),
                      ),
                    ),
                    SizedBox(
                      height: _footerExtent,
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Text('${i + 1} / ${pages.length}', style: muted),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _pageContent(
    NovelTextStyles styles,
    NovelChapter chapter,
    NovelPage page,
  ) {
    final children = <Widget>[];
    for (final (k, f) in page.fragments.indexed) {
      if (k > 0) children.add(SizedBox(height: styles.paragraphGap));
      final block = chapter.blocks[f.block];
      children.add(switch (block) {
        final NovelParagraph p => RichText(
          text: styles.paragraph(p, f.start, f.end),
          textScaler: styles.textScaler,
        ),
        NovelImage() => SizedBox(
          height: _pageArea.height,
          child: _block(styles, chapter, f.block),
        ),
        NovelDivider() => _block(styles, chapter, f.block),
      });
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  // ---------------------------------------------------------------------------
  // 目录与设置

  Future<void> _showContents(List<Unit> chapters) async {
    if (chapters.isEmpty) {
      _chaptersUnavailable();
      return;
    }
    final current = chapters.indexWhere((u) => u.id == _unitId);
    final picked = await showModalBottomSheet<Unit>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _Contents(chapters: chapters, current: current),
    );
    if (picked != null && mounted) {
      setState(() => _showToolbar = false);
      if (picked.id != _unitId) _openChapter(picked);
    }
  }

  Future<void> _showSettings() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const _SettingsSheet(),
  );
}

class _NovelImageView extends StatelessWidget {
  const _NovelImageView({
    required this.sourceId,
    required this.image,
    required this.alt,
  });

  final String sourceId;
  final ImageRef image;
  final String? alt;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 120),
    child: Center(
      child: SourceImage(
        sourceId: sourceId,
        image: image,
        fit: BoxFit.contain,
        semanticLabel: alt,
      ),
    ),
  );
}

class _EndOfChapter extends StatelessWidget {
  const _EndOfChapter({
    required this.message,
    required this.color,
    required this.chapters,
    required this.next,
    required this.onNext,
    required this.onRetryChapters,
  });

  final String message;
  final Color color;
  final AsyncValue<Detail> chapters;
  final Unit? next;
  final VoidCallback onNext;
  final VoidCallback onRetryChapters;

  @override
  Widget build(BuildContext context) {
    final next = this.next;
    final muted = TextStyle(color: color);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: muted),
          const SizedBox(height: 12),
          if (chapters is AsyncError)
            FilledButton.tonal(
              onPressed: onRetryChapters,
              child: const Text('重试获取章节'),
            )
          else if (chapters is! AsyncData)
            Text('正在获取章节列表…', style: muted)
          else if (next != null)
            FilledButton.tonal(
              onPressed: onNext,
              child: Text('下一章：${next.title}'),
            )
          else
            Text('已经是最后一章', style: muted),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.subtitle,
    required this.onBack,
    required this.onContents,
    required this.onSettings,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onBack;
  final VoidCallback onContents;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    elevation: 2,
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
          IconButton(
            tooltip: '目录',
            icon: const Icon(Icons.list),
            onPressed: onContents,
          ),
          IconButton(
            tooltip: '阅读设置',
            icon: const Icon(Icons.text_format),
            onPressed: onSettings,
          ),
        ],
      ),
    ),
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.progress,
    required this.chapterLength,
    required this.pageCount,
    required this.pageIndex,
    required this.scrollFraction,
    required this.hasPrevious,
    required this.hasNext,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
  });

  final ValueListenable<_Progress> progress;
  final int chapterLength;

  /// 翻页模式的页数；滚动模式为 null。
  final int? pageCount;
  final int Function() pageIndex;
  final double Function() scrollFraction;
  final bool hasPrevious;
  final bool hasNext;
  final ValueChanged<double> onSeek;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    elevation: 2,
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
            child: ValueListenableBuilder(
              valueListenable: progress,
              builder: (context, p, _) {
                final pages = pageCount;
                final percent = p.atEnd || chapterLength == 0
                    ? 100
                    : (p.position * 100 / chapterLength).floor().clamp(0, 100);
                return Row(
                  children: [
                    Expanded(
                      child: pages != null
                          ? (pages > 1
                                ? _SeekSlider(
                                    value: pageIndex().toDouble(),
                                    max: (pages - 1).toDouble(),
                                    divisions: pages - 1,
                                    label: (v) => '${v.round() + 1} / $pages',
                                    onSeek: onSeek,
                                  )
                                : const SizedBox.shrink())
                          : _SeekSlider(
                              value: scrollFraction(),
                              max: 1,
                              label: (v) => '${(v * 100).round()}%',
                              onSeek: onSeek,
                            ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text('$percent%', textAlign: TextAlign.center),
                    ),
                  ],
                );
              },
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

/// 拖动时只更新标签，松手后才跳转。
class _SeekSlider extends StatefulWidget {
  const _SeekSlider({
    required this.value,
    required this.max,
    required this.label,
    required this.onSeek,
    this.divisions,
  });

  final double value;
  final double max;
  final int? divisions;
  final String Function(double) label;
  final ValueChanged<double> onSeek;

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final value = (_dragging ?? widget.value).clamp(0.0, widget.max);
    return Slider(
      value: value,
      max: widget.max,
      divisions: widget.divisions,
      label: widget.label(value),
      onChanged: (v) => setState(() => _dragging = v),
      onChangeEnd: (v) {
        setState(() => _dragging = null);
        widget.onSeek(v);
      },
    );
  }
}

class _Contents extends StatefulWidget {
  const _Contents({required this.chapters, required this.current});

  final List<Unit> chapters;
  final int current;

  @override
  State<_Contents> createState() => _ContentsState();
}

class _ContentsState extends State<_Contents> {
  static const _itemExtent = 48.0;
  late final _controller = ScrollController(
    initialScrollOffset: math.max(0, widget.current - 3) * _itemExtent,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '目录（${widget.chapters.length}）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _controller,
              itemExtent: _itemExtent,
              itemCount: widget.chapters.length,
              itemBuilder: (context, i) {
                final unit = widget.chapters[i];
                final current = i == widget.current;
                return ListTile(
                  dense: true,
                  selected: current,
                  selectedColor: scheme.primary,
                  title: Text(
                    unit.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: current
                      ? const Icon(Icons.bookmark, semanticLabel: '当前章节')
                      : null,
                  onTap: () => Navigator.of(context).pop(unit),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSheet extends ConsumerWidget {
  const _SettingsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs =
        ref.watch(novelReaderSettingsProvider).value ??
        const NovelReaderPreferences();
    final notifier = ref.read(novelReaderSettingsProvider.notifier);
    Widget slider({
      required String label,
      required double value,
      required double min,
      required double max,
      required int divisions,
      required String Function(double) format,
      required NovelReaderPreferences Function(double) apply,
    }) => Row(
      children: [
        SizedBox(width: 64, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: format(value),
            onChanged: (v) => notifier.change((_) => apply(v)),
          ),
        ),
        SizedBox(width: 48, child: Text(format(value))),
      ],
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<NovelReaderMode>(
              segments: [
                for (final m in NovelReaderMode.values)
                  ButtonSegment(value: m, label: Text(m.label)),
              ],
              selected: {prefs.mode},
              onSelectionChanged: (s) =>
                  notifier.change((p) => p.copyWith(mode: s.first)),
            ),
            const SizedBox(height: 12),
            SegmentedButton<NovelReaderTheme>(
              segments: [
                for (final t in NovelReaderTheme.values)
                  ButtonSegment(value: t, label: Text(t.label)),
              ],
              selected: {prefs.theme},
              onSelectionChanged: (s) =>
                  notifier.change((p) => p.copyWith(theme: s.first)),
            ),
            const SizedBox(height: 12),
            slider(
              label: '字号',
              value: prefs.fontSize,
              min: NovelReaderPreferences.minFontSize,
              max: NovelReaderPreferences.maxFontSize,
              divisions: 28,
              format: (v) => '${v.round()}',
              apply: (v) => prefs.copyWith(fontSize: v.roundToDouble()),
            ),
            slider(
              label: '行距',
              value: prefs.lineHeight,
              min: 1.2,
              max: 2.6,
              divisions: 14,
              format: (v) => v.toStringAsFixed(1),
              apply: (v) => prefs.copyWith(lineHeight: _round1(v)),
            ),
            slider(
              label: '段距',
              value: prefs.paragraphSpacing,
              min: 0,
              max: 2,
              divisions: 20,
              format: (v) => v.toStringAsFixed(1),
              apply: (v) => prefs.copyWith(paragraphSpacing: _round1(v)),
            ),
            slider(
              label: '页边距',
              value: prefs.margin,
              min: 4,
              max: 64,
              divisions: 30,
              format: (v) => '${v.round()}',
              apply: (v) => prefs.copyWith(margin: v.roundToDouble()),
            ),
            Row(
              children: [
                const SizedBox(width: 64, child: Text('字体')),
                DropdownButton<NovelFont>(
                  value: prefs.font,
                  items: [
                    for (final f in NovelFont.values)
                      DropdownMenuItem(value: f, child: Text(f.label)),
                  ],
                  onChanged: (f) {
                    if (f != null) notifier.change((p) => p.copyWith(font: f));
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static double _round1(double v) => (v * 10).roundToDouble() / 10;
}
