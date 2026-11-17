import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 让 `HttpServer` 在处理请求期间也能察觉对方关闭连接（architecture §6.4.3）。
///
/// dart:io 的 `HttpServer` 在处理一个请求时暂停读取该连接，直到响应发完；这期间对方关闭连接
/// 它看不到，`HttpResponse.done` 也不会完成——只有开始写入之后才会失败。媒体代理在发送响应体之前
/// 可能要等很久（限速排队、上游响应慢），因此用 [HttpServer.listenOn] 接上本类：每个连接都由本类
/// 一直读取（数据转交 dart:io，按它的节奏交付），读到 EOF 或出错即视为对方已关闭。
///
/// 对方只关闭写方向（半关闭）也会被视为断开（一般 HTTP 客户端发完请求后不会这样做）。
class WatchedServerSocket extends Stream<Socket> implements ServerSocket {
  WatchedServerSocket._(this._inner);

  static Future<WatchedServerSocket> bind(Object address, int port) async =>
      WatchedServerSocket._(await ServerSocket.bind(address, port));

  final ServerSocket _inner;
  final _byRemote = <(String, int), _WatchedSocket>{};

  /// 对方地址为 [remoteAddress]、端口为 [remotePort] 的连接被对方关闭时调用 [onClosed]（最多一次）；
  /// 没有该连接（或已关闭）时立即调用。返回的函数注销监听（同一连接上可先后处理很多请求，处理完一个就应注销）。
  ///
  /// 同一时刻每个连接的（对方地址, 对方端口）各不相同（本机一侧的地址与端口固定）。
  void Function() watch(
    InternetAddress remoteAddress,
    int remotePort,
    void Function() onClosed,
  ) {
    final socket = _byRemote[(remoteAddress.address, remotePort)];
    if (socket == null || socket._peerClosed.isCompleted) {
      onClosed();
      return () {};
    }
    socket._watchers.add(onClosed);
    return () => socket._watchers.remove(onClosed);
  }

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inner
      .expand<Socket>((s) {
        final (String, int) key;
        try {
          key = (s.remoteAddress.address, s.remotePort);
        } on Object {
          // 接受之后立即被对方重置：已经无法使用。
          s.destroy();
          return const [];
        }
        final w = _WatchedSocket(s);
        _byRemote[key] = w;
        w._peerClosed.future.whenComplete(() {
          if (identical(_byRemote[key], w)) _byRemote.remove(key);
        });
        return [w];
      })
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  InternetAddress get address => _inner.address;

  @override
  int get port => _inner.port;

  @override
  Future<ServerSocket> close() async {
    await _inner.close();
    return this;
  }
}

/// 一直读取 [_inner] 的 [Socket]：数据经 [_out] 按订阅方（dart:io）的节奏交付。
class _WatchedSocket extends Stream<Uint8List> implements Socket {
  _WatchedSocket(this._inner) {
    _sub = _inner.listen(
      (data) {
        // 已读取、尚未交付给订阅方的数据过多（只接受 GET / HEAD，正常情况下只有很少的流水线请求）时
        // 暂停底层读取（TCP 背压），此时暂时察觉不到断开；交付之后恢复。
        _buffered += data.length;
        _out.add(data);
        if (_buffered > _maxBuffered && !_sub.isPaused) _sub.pause();
      },
      onError: (Object e, StackTrace st) {
        _markClosed();
        _out.addError(e, st);
      },
      onDone: () {
        _markClosed();
        _out.close();
      },
    );
  }

  static const _maxBuffered = 64 * 1024;

  final Socket _inner;
  late final StreamSubscription<Uint8List> _sub;
  late final _out = StreamController<Uint8List>(
    onCancel: () {
      _markClosed();
      return _sub.cancel();
    },
  );
  int _buffered = 0;
  final _peerClosed = Completer<void>();
  final _watchers = <void Function()>{};

  void _markClosed() {
    if (_peerClosed.isCompleted) return;
    _peerClosed.complete();
    final watchers = _watchers.toList();
    _watchers.clear();
    for (final w in watchers) {
      w();
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _out.stream
      .map((data) {
        // 在交付给订阅方时扣减（订阅方暂停时 map 也暂停，数据留在 [_out] 中）。
        _buffered -= data.length;
        if (_buffered <= _maxBuffered && _sub.isPaused) _sub.resume();
        return data;
      })
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  void destroy() {
    _markClosed();
    _inner.destroy();
  }

  @override
  Future<void> close() async {
    _markClosed();
    await _inner.close();
  }

  @override
  Future<void> get done => _inner.done;

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  InternetAddress get address => _inner.address;

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;

  @override
  int get port => _inner.port;

  @override
  int get remotePort => _inner.remotePort;

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
}
