import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:args/args.dart';
import 'dart:async';
 
void main(List<String> arguments) {
  runZonedGuarded(() async {
    // 1. Khởi tạo bộ đọc tham số
    final parser = ArgParser()
      ..addFlag('headless', negatable: false, help: 'Chạy chế độ ngầm không giao diện')
      ..addOption('proxies', help: 'Danh sách proxy, cách nhau bằng dấu \\n')
      ..addFlag('overwrite', negatable: false, help: 'Ghi đè User/Pass')
      ..addOption('user', help: 'Username dùng để ghi đè')
      ..addOption('pass', help: 'Password dùng để ghi đè')
      ..addOption('startport', defaultsTo: '10000', help: 'Port nội bộ bắt đầu');

    try {
      final argResults = parser.parse(arguments);

      // 2. Nếu có cờ --headless, chạy code Console và bỏ qua UI
      if (argResults['headless'] as bool) {
        print('=================================');
        print('🚀 PROXY FORWARD - HEADLESS MODE');
        print('=================================');
        await _runHeadlessMode(argResults);
        return; // Kết thúc ở đây, không chạy xuống runApp()
      }
    } catch (e) {
      print('Lỗi cú pháp tham số: $e');
      print(parser.usage);
      exit(1);
    }

    // 3. Nếu không có cờ --headless, chạy giao diện UI bình thường
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const ProxyForwardApp());

  }, (error, stack) {
    // Nếu có lỗi ngầm, nó sẽ chui vào đây thay vì làm sập App
    print('⚠️ [BỎ QUA LỖI NGẦM]: $error');
  });
}

// ==========================================
// LOGIC CHẠY NGẦM KHÔNG GIAO DIỆN (HEADLESS)
// ==========================================
Future<void> _runHeadlessMode(ArgResults args) async {
  String proxiesStr = args['proxies'] ?? '';
  // Xử lý dấu xuống dòng truyền từ string terminal
  proxiesStr = proxiesStr.replaceAll('\\n', '\n'); 
  
  bool override = args['overwrite'] as bool;
  String? overrideUser = args['user'];
  String? overridePass = args['pass'];
  int currentPort = int.tryParse(args['startport'] ?? '10000') ?? 10000;

  List<String> lines = proxiesStr.split('\n');
  List<ProxyConfig> headlessProxies = [];

  for (String line in lines) {
    line = line.trim();
    if (line.isEmpty) continue;

    String type = 'http';
    if (line.toLowerCase().startsWith(RegExp(r'socks5h?://'))) {
      type = 'socks5';
      line = line.replaceFirst(RegExp(r'socks5h?://', caseSensitive: false), '');
    } else if (line.toLowerCase().startsWith('http://')) {
      type = 'http';
      line = line.substring(7);
    }

    String ip = "";
    int port = 0;
    String? user;
    String? pass;

    if (line.contains('@')) {
      List<String> parts = line.split('@');
      List<String> auth = parts[0].split(':');
      List<String> host = parts[1].split(RegExp(r'[:|]'));
      user = auth.isNotEmpty ? auth[0] : null;
      pass = auth.length > 1 ? auth[1] : null;
      if (host.isNotEmpty) ip = host[0];
      if (host.length > 1) port = int.tryParse(host[1]) ?? 0;
    } else {
      List<String> parts = line.split(RegExp(r'[:|]'));
      if (parts.length >= 2) {
        ip = parts[0];
        port = int.tryParse(parts[1]) ?? 0;
        if (parts.length >= 4) {
          user = parts[2];
          pass = parts[3];
        }
      }
    }

    if (port == 0 || ip.isEmpty) continue;

    if (override && overrideUser != null && overridePass != null) {
      user = overrideUser;
      pass = overridePass;
    }

    headlessProxies.add(ProxyConfig(
      type: type, remoteIp: ip, remotePort: port, username: user, password: pass, localPort: currentPort++
    ));
  }

  if (headlessProxies.isEmpty) {
    print('❌ Lỗi: Không tìm thấy proxy hợp lệ để khởi tạo.');
    exit(1);
  }

  // Khởi tạo các Local Server
  for (var config in headlessProxies) {
    try {
      config.serverSocket = await ServerSocket.bind('127.0.0.1', config.localPort);
      print('✅ [OK] Mở port ${config.localPort} -> ${config.type.toUpperCase()} ${config.originalProxy}');

      config.serverSocket!.listen((Socket localClient) async {
        // Log khi có kết nối
        print('⚡ [${DateTime.now().toString().split('.')[0]}] Có kết nối vào port ${config.localPort}');

        handleCoreForwarding(localClient, config); 
      });
    } catch (e) {
      print('❌ [LỖI] Không thể mở port ${config.localPort} (Có thể bị trùng)');
    }
  }

  print('\n🎯 Đang lắng nghe... Nhấn Ctrl+C để thoát.');
  
  // Giữ cho chương trình chạy vô thời hạn
  ProcessSignal.sigint.watch().listen((signal) {
    print("\nĐang tắt các proxy...");
    for (var config in headlessProxies) {
      config.serverSocket?.close();
    }
    exit(0);
  });
}

void handleCoreForwarding(Socket localClient, ProxyConfig config) async {
  Socket? remoteProxy;
  try {
    // 1. Timeout lúc mới bắt đầu kết nối
    remoteProxy = await Socket.connect(config.remoteIp, config.remotePort, timeout: const Duration(seconds: 15));
    
    // 2. Tối ưu tốc độ truyền tải
    localClient.setOption(SocketOption.tcpNoDelay, true);
    remoteProxy.setOption(SocketOption.tcpNoDelay, true);
    
  } catch (e) {
    // Báo ra console nếu đang chạy headless
    print('❌ [${config.localPort}] Proxy gốc không phản hồi: ${config.remoteIp}:${config.remotePort}');
    localClient.close();
    return;
  }
  
  if (config.type == 'socks5') {
    coreSocks5Protocol(localClient, remoteProxy, config);
  } else {
    coreHttpProtocol(localClient, remoteProxy, config);
  }
}

void coreSocks5Protocol(Socket localClient, Socket remoteProxy, ProxyConfig config) {
  int localStep = 0; bool remoteAuthed = false; List<int>? pendingConnectRequest;
  if (config.username != null && config.password != null) { remoteProxy.add([0x05, 0x01, 0x02]); } else { remoteAuthed = true; }
  remoteProxy.listen((data) {
    if (!remoteAuthed) {
      if (data.length >= 2 && data[0] == 0x05) {
        if (data[1] == 0x02) {
          List<int> authPacket = [0x01];
          List<int> userBytes = utf8.encode(config.username!);
          List<int> passBytes = utf8.encode(config.password!);
          authPacket.add(userBytes.length); authPacket.addAll(userBytes);
          authPacket.add(passBytes.length); authPacket.addAll(passBytes);
          remoteProxy.add(authPacket);
        } else if (data[1] == 0x00) {
          remoteAuthed = true;
          if (pendingConnectRequest != null) remoteProxy.add(pendingConnectRequest!);
        } else { localClient.close(); remoteProxy.close(); }
      } else if (data.length >= 2 && data[0] == 0x01 && data[1] == 0x00) {
        remoteAuthed = true;
        if (pendingConnectRequest != null) { remoteProxy.add(pendingConnectRequest!); pendingConnectRequest = null; }
      } else { localClient.close(); remoteProxy.close(); }
    } else { localClient.add(data); }
  }, onDone: () => localClient.close(), onError: (e) => localClient.close());

  localClient.listen((data) {
    if (localStep == 0) {
      if (data.isNotEmpty && data[0] == 0x05) { localClient.add([0x05, 0x00]); localStep = 1; }
    } else if (localStep == 1) {
      localStep = 2;
      if (remoteAuthed) { remoteProxy.add(data); } else { pendingConnectRequest = data; }
    } else { remoteProxy.add(data); }
  }, onDone: () => remoteProxy.close(), onError: (e) => remoteProxy.close());
}

void coreHttpProtocol(Socket localClient, Socket remoteProxy, ProxyConfig config) {
  bool isFirstPacket = true;
  localClient.listen((data) {
    if (isFirstPacket) {
      isFirstPacket = false;
      if (config.username != null && config.password != null) {
        String requestString = String.fromCharCodes(data);
        String authString = base64Encode(utf8.encode('${config.username}:${config.password}'));
        String injectHeader = 'Proxy-Authorization: Basic $authString\r\n';
        int insertPos = requestString.indexOf('\r\n');
        if (insertPos != -1) {
          String modifiedRequest = requestString.substring(0, insertPos + 2) + injectHeader + requestString.substring(insertPos + 2);
          remoteProxy.add(utf8.encode(modifiedRequest));
        } else { remoteProxy.add(data); }
      } else { remoteProxy.add(data); }
    } else { remoteProxy.add(data); }
  }, onDone: () => remoteProxy.close(), onError: (e) => remoteProxy.close());
  remoteProxy.listen((data) => localClient.add(data), onDone: () => localClient.close(), onError: (e) => localClient.close());
}

class ProxyForwardApp extends StatelessWidget {
  const ProxyForwardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Proxy Forward',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1E1E2C),
        primaryColor: const Color(0xFF2D2D44),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6B8AFF),
          surface: Color(0xFF252538),
        ),
        fontFamily: 'Segoe UI',
      ),
      home: const MainScreen(),
    );
  }
}

class ProxyConfig {
  String type;
  String remoteIp;
  int remotePort;
  String? username;
  String? password;
  int localPort;
  String status;
  ServerSocket? serverSocket;

  ProxyConfig({
    this.type = 'http',
    required this.remoteIp,
    required this.remotePort,
    this.username,
    this.password,
    required this.localPort,
    this.status = 'Chờ xử lý',
  });

  String get originalProxy => '${type == 'socks5' ? 'socks5://' : ''}$remoteIp:$remotePort' 
      + (username != null ? ':$username:$password' : '');
  String get localProxy => '127.0.0.1:$localPort';
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _proxyInputController = TextEditingController();
  final TextEditingController _overrideUserController = TextEditingController();
  final TextEditingController _overridePassController = TextEditingController();
  final TextEditingController _startPortController = TextEditingController(text: '10000');
  final ScrollController _logScrollController = ScrollController();
  
  bool _overrideUserPass = false;
  bool _isVi = true; // Biến trạng thái ngôn ngữ: true = Tiếng Việt, false = English
  List<ProxyConfig> _proxyList = [];
  bool _isRunning = false;
  final List<String> _logs = [];

  // Hàm Helper để dịch văn bản nhanh
  String _txt(String vi, String en) => _isVi ? vi : en;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadSavedData();

    _proxyInputController.addListener(_saveData);
    _overrideUserController.addListener(_saveData);
    _overridePassController.addListener(_saveData);
  }

  @override
  void dispose() {
    _stopAllProxies();
    _proxyInputController.removeListener(_saveData);
    _overrideUserController.removeListener(_saveData);
    _overridePassController.removeListener(_saveData);
    
    _tabController.dispose();
    _proxyInputController.dispose();
    _overrideUserController.dispose();
    _overridePassController.dispose();
    _startPortController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _addLog(String message) {
    final time = DateTime.now().toString().split('.')[0];
    setState(() => _logs.add('[$time] $message'));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _proxyInputController.text = prefs.getString('proxy_list') ?? '';
      _overrideUserPass = prefs.getBool('override_checkbox') ?? false;
      _overrideUserController.text = prefs.getString('override_user') ?? '';
      _overridePassController.text = prefs.getString('override_pass') ?? '';
      _isVi = prefs.getBool('is_vi') ?? true; // Load ngôn ngữ
    });
    _addLog(_txt('Ứng dụng đã khởi động.', 'Application started.'));
  }

  Future<void> _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('proxy_list', _proxyInputController.text);
    await prefs.setBool('override_checkbox', _overrideUserPass);
    await prefs.setString('override_user', _overrideUserController.text);
    await prefs.setString('override_pass', _overridePassController.text);
    await prefs.setBool('is_vi', _isVi); // Lưu ngôn ngữ
  }

  void _startAllProxies() async {
    if (_isRunning) return;
    _stopAllProxies();
    _addLog(_txt('Đang phân tích và khởi tạo proxy...', 'Parsing and initializing proxies...'));
    
    List<String> lines = _proxyInputController.text.split('\n');
    int currentPort = int.tryParse(_startPortController.text) ?? 10000;
    List<ProxyConfig> newList = [];

    for (String line in lines) {
      line = line.trim();
      if (line.isEmpty) continue;

      String type = 'http';
      // Dùng Regex để bắt cả socks5:// và socks5h://
      if (line.toLowerCase().startsWith(RegExp(r'socks5h?://'))) {
        type = 'socks5';
        // Xóa phần tiền tố để lấy IP/Port bên dưới
        line = line.replaceFirst(RegExp(r'socks5h?://', caseSensitive: false), '');
      } else if (line.toLowerCase().startsWith('http://')) {
        type = 'http';
        line = line.substring(7);
      }

      String ip = "";
      int port = 0;
      String? user;
      String? pass;

      if (line.contains('@')) {
        List<String> parts = line.split('@');
        List<String> auth = parts[0].split(':');
        List<String> host = parts[1].split(RegExp(r'[:|]'));
        
        user = auth.isNotEmpty ? auth[0] : null;
        pass = auth.length > 1 ? auth[1] : null;
        
        if (host.isNotEmpty) ip = host[0];
        if (host.length > 1) port = int.tryParse(host[1]) ?? 0;
      } else {
        List<String> parts = line.split(RegExp(r'[:|]'));
        if (parts.length >= 2) {
          ip = parts[0];
          port = int.tryParse(parts[1]) ?? 0;
          if (parts.length >= 4) {
            user = parts[2];
            pass = parts[3];
          }
        }
      }

      if (port == 0 || ip.isEmpty) continue;

      if (_overrideUserPass && _overrideUserController.text.isNotEmpty) {
        user = _overrideUserController.text;
        pass = _overridePassController.text;
      }

      newList.add(ProxyConfig(type: type, remoteIp: ip, remotePort: port, username: user, password: pass, localPort: currentPort++, status: _txt('Chờ xử lý', 'Pending')));
    }

    if (newList.isEmpty) {
      _addLog(_txt('Không tìm thấy proxy hợp lệ.', 'No valid proxies found.'));
      return;
    }

    setState(() {
      _proxyList = newList;
      _isRunning = true;
    });

    for (var config in _proxyList) {
      _bindLocalServer(config);
    }
    _addLog(_txt('Đã hoàn tất lệnh Start.', 'Start command completed.'));
  }

  void _stopAllProxies() {
    if (_proxyList.isEmpty) return;
    for (var config in _proxyList) {
      config.serverSocket?.close();
      config.status = _txt('Đã dừng', 'Stopped');
    }
    setState(() => _isRunning = false);
    _addLog(_txt('Đã dừng toàn bộ proxy.', 'All proxies stopped.'));
  }

  Future<void> _bindLocalServer(ProxyConfig config) async {
    try {
      config.serverSocket = await ServerSocket.bind('127.0.0.1', config.localPort);
      setState(() => config.status = _txt('Đang chạy (${config.type.toUpperCase()})', 'Running (${config.type.toUpperCase()})'));
      _addLog(_txt('Mở port thành công:', 'Port opened successfully:') + ' ${config.localProxy} -> ${config.originalProxy}');

      config.serverSocket!.listen((Socket localClient) {
        _handleClientConnection(localClient, config);
      });
    } catch (e) {
      setState(() => config.status = _txt('Lỗi Port', 'Port Error'));
      _addLog(_txt('LỖI: Port ${config.localPort} đang bị chiếm dụng.', 'ERROR: Port ${config.localPort} is already in use.'));
    }
  }

  void _handleClientConnection(Socket localClient, ProxyConfig config) async {
    _addLog(_txt('Có kết nối vào port ${config.localPort}...', 'Connection received on port ${config.localPort}...'));
    Socket? remoteProxy;
    try {
      remoteProxy = await Socket.connect(config.remoteIp, config.remotePort, timeout: const Duration(seconds: 10));
    } catch (e) {
      _addLog(_txt('Lỗi kết nối tới proxy gốc', 'Failed to connect to original proxy') + ' ${config.remoteIp}:${config.remotePort}');
      localClient.close();
      return;
    }

    // Dùng chung 2 hàm xử lý core bên ngoài (Top-level)
    if (config.type == 'socks5') {
      coreSocks5Protocol(localClient, remoteProxy, config);
    } else {
      coreHttpProtocol(localClient, remoteProxy, config);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // HEADER KÈM NÚT ĐỔI NGÔN NGỮ
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'PROXY FORWARD',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 2.0, color: Color(0xFF8BA4FF)),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.language, size: 16),
                  label: Text(_isVi ? 'VI' : 'EN'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF8BA4FF),
                    side: const BorderSide(color: Color(0xFF8BA4FF)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  onPressed: () {
                    setState(() => _isVi = !_isVi);
                    _saveData();
                  },
                )
              ],
            ),
          ),
          Container(
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white24, width: 1))),
            child: Row(
              children: [
                SizedBox(
                  width: 400,
                  child: TabBar(
                    controller: _tabController,
                    indicatorColor: const Color(0xFF8BA4FF),
                    labelColor: const Color(0xFF8BA4FF),
                    unselectedLabelColor: Colors.grey,
                    tabs: [
                      Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.play_arrow, size: 16), const SizedBox(width: 8), Text(_txt('Main', 'Main'))])),
                      Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.list, size: 16), const SizedBox(width: 8), Text(_txt('Nhật Ký', 'Logs'))])),
                      Tab(child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.info_outline, size: 16), const SizedBox(width: 8), Text(_txt('Info', 'Info'))])),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildMainTab(),
                _buildLogTab(),
                Center(child: Text(_txt('Ứng dụng Proxy Forward\nVersion 1.0', 'Proxy Forward App\nVersion 1.0'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_txt('Nhập Proxy (hỗ trợ HTTP và SOCKS5)', 'Input Proxy (HTTP & SOCKS5 Supported)'), style: const TextStyle(color: Color(0xFF8BA4FF), fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            height: 120,
            decoration: BoxDecoration(color: const Color(0xFF161622), borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.white12)),
            child: TextField(
              controller: _proxyInputController,
              maxLines: null,
              decoration: InputDecoration(
                hintText: _txt('socks5://user:pass@1.2.3.4:8080\nsocks5://5.6.7.8|3128|user2|pass2\n9.10.11.12:1080 (Mặc định là HTTP)', 'socks5://user:pass@1.2.3.4:8080\nsocks5://5.6.7.8|3128|user2|pass2\n9.10.11.12:1080 (Default is HTTP)'),
                hintStyle: const TextStyle(color: Colors.white30),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(12),
              ),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Checkbox(
                value: _overrideUserPass, 
                onChanged: (value) {
                  setState(() => _overrideUserPass = value ?? false);
                  _saveData();
                }
              ),
              Text(_txt('Ghi đè User/Pass:', 'Override User/Pass:')),
              const SizedBox(width: 16),
              _buildSmallTextField('Username', _overrideUserController),
              const SizedBox(width: 16),
              _buildSmallTextField('Password', _overridePassController),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildButton(_txt('Start All', 'Start All'), Icons.play_arrow, const Color(0xFF2E7D32), onPressed: _isRunning ? null : _startAllProxies),
              const SizedBox(width: 12),
              _buildButton(_txt('Stop All', 'Stop All'), Icons.stop, const Color(0xFFC62828), onPressed: !_isRunning ? null : _stopAllProxies),
              const SizedBox(width: 12),
              _buildButton(_txt('Xóa', 'Clear'), Icons.clear, const Color(0xFF3F3F5A), onPressed: () => _proxyInputController.clear()),
              const Spacer(),
              Text(_txt('Port bắt đầu:', 'Start Port:')),
              const SizedBox(width: 12),
              SizedBox(
                width: 80, height: 32,
                child: TextField(
                  controller: _startPortController,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(contentPadding: EdgeInsets.zero, border: OutlineInputBorder(), filled: true, fillColor: Color(0xFF161622)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(_txt('Danh sách Proxy Local', 'Local Proxy List'), style: const TextStyle(color: Color(0xFF8BA4FF), fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFF161622), borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.white12)),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white12))),
                    child: Row(
                      children: [
                        const SizedBox(width: 40, child: Text('#', style: TextStyle(fontWeight: FontWeight.bold))),
                        Expanded(flex: 2, child: Text(_txt('Proxy gốc', 'Original Proxy'), style: const TextStyle(fontWeight: FontWeight.bold))),
                        Expanded(flex: 2, child: Text(_txt('Local Proxy', 'Local Proxy'), style: const TextStyle(fontWeight: FontWeight.bold))),
                        Expanded(flex: 1, child: Text(_txt('Trạng thái', 'Status'), style: const TextStyle(fontWeight: FontWeight.bold))),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _proxyList.length,
                      itemBuilder: (context, index) {
                        final proxy = _proxyList[index];
                        return Container(
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white12))),
                          child: Row(
                            children: [
                              SizedBox(width: 40, child: Text('${index + 1}')),
                              Expanded(flex: 2, child: Text(proxy.originalProxy, style: const TextStyle(color: Colors.grey))),
                              Expanded(flex: 2, child: Text(proxy.localProxy, style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold))),
                              Expanded(flex: 1, child: Text(proxy.status, style: TextStyle(color: proxy.status.contains(_txt('Lỗi', 'Error')) ? Colors.red : Colors.yellow))),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _buildButton(
                _txt('Copy toàn bộ Local Proxy', 'Copy All Local Proxies'), 
                Icons.copy, 
                const Color(0xFF2B5C7F), 
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                onPressed: () {
                  if (_proxyList.isEmpty) return;
                  String copiedText = _proxyList.map((p) => p.localProxy).join('\n');
                  Clipboard.setData(ClipboardData(text: copiedText));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(_txt('Đã copy danh sách Local Proxy vào bộ nhớ tạm!', 'Copied local proxies to clipboard!')),
                      backgroundColor: const Color(0xFF2B5C7F),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  _addLog(_txt('Đã copy danh sách Local Proxy.', 'Copied local proxy list.'));
                }
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildLogTab() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0D0D14), 
          borderRadius: BorderRadius.circular(4), 
          border: Border.all(color: Colors.white12)
        ),
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _logScrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: Text(
                      _logs[index], 
                      style: const TextStyle(fontFamily: 'Consolas', fontSize: 13, color: Colors.greenAccent)
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: Colors.white12))),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.grey),
                    label: Text(_txt('Xóa nhật ký', 'Clear Logs'), style: const TextStyle(color: Colors.grey)),
                    onPressed: () => setState(() => _logs.clear()),
                  )
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildSmallTextField(String hint, TextEditingController controller) {
    return SizedBox(
      width: 150, height: 32,
      child: TextField(
        controller: controller,
        enabled: _overrideUserPass,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 13, color: Colors.white30),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: _overrideUserPass ? const Color(0xFF161622) : Colors.black26,
        ),
      ),
    );
  }

  Widget _buildButton(String text, IconData? icon, Color color, {EdgeInsetsGeometry? padding, VoidCallback? onPressed}) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        disabledBackgroundColor: color.withOpacity(0.3),
        foregroundColor: Colors.white,
        padding: padding ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 6)],
          Text(text),
        ],
      ),
    );
  }
}
