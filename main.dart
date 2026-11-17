import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'api_service.dart';
import 'models.dart';

void main() {
  runApp(const AIHubEnterpriseApp());
}

class AIHubEnterpriseApp extends StatelessWidget {
  const AIHubEnterpriseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Studio Enterprise v4',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00E5FF),
          brightness: Brightness.dark,
        ),
      ),
      home: const BiometricGateScreen(),
    );
  }
}

class BiometricGateScreen extends StatefulWidget {
  const BiometricGateScreen({super.key});

  @override
  State<BiometricGateScreen> createState() => _BiometricGateScreenState();
}

class _BiometricGateScreenState extends State<BiometricGateScreen> {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _unlocked = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkLock();
  }

  Future<void> _checkLock() async {
    final prefs = await SharedPreferences.getInstance();
    final lockEnabled = prefs.getBool('biometric_lock_enabled') ?? false;
    if (!lockEnabled) {
      setState(() {
        _unlocked = true;
        _checking = false;
      });
      return;
    }
    setState(() => _checking = false);
    await _authenticate();
  }

  Future<void> _authenticate() async {
    try {
      final didAuth = await _auth.authenticate(
        localizedReason: 'برای دسترسی به AI Studio احراز هویت کنید',
        options: const AuthenticationOptions(biometricOnly: false),
      );
      if (didAuth && mounted) {
        setState(() => _unlocked = true);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_unlocked) {
      return const MainWorkspaceScreen();
    }
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.fingerprint, size: 72, color: Colors.cyanAccent),
            const SizedBox(height: 16),
            const Text('برنامه قفل است', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _authenticate,
              icon: const Icon(Icons.lock_open),
              label: const Text('باز کردن قفل'),
            ),
          ],
        ),
      ),
    );
  }
}

class MainWorkspaceScreen extends StatefulWidget {
  const MainWorkspaceScreen({super.key});

  @override
  State<MainWorkspaceScreen> createState() => _MainWorkspaceScreenState();
}

class _MainWorkspaceScreenState extends State<MainWorkspaceScreen> {
  static const _nativeChannel = MethodChannel('com.aihub.client/native');

  List<AIProfile> _profiles = [];
  AIProfile? _selectedProfile;
  AIProfile? _arenaSecondProfile;

  List<ChatSession> _sessions = [];
  ChatSession? _currentSession;

  List<PromptTemplate> _promptTemplates = [];
  bool _biometricLockEnabled = false;
  bool _floatingBubbleEnabled = false;

  GenerationMode _mode = GenerationMode.chat;
  final List<MediaAttachment> _pendingAttachments = [];

  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ImagePicker _picker = ImagePicker();

  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _isListening = false;
  String? _speakingMessageId;

  bool _isLoading = false;
  String _loadingStatus = '';

  @override
  void initState() {
    super.initState();
    _initTTS();
    _initData().then((_) => _checkNativeLaunchPayload());
  }

  Future<void> _initTTS() async {
    await _tts.setSpeechRate(0.5);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _speakingMessageId = null);
    });
  }

  Future<void> _checkNativeLaunchPayload() async {
    try {
      final data = await _nativeChannel.invokeMethod<Map>('getLaunchPayload');
      if (data != null && mounted) {
        final type = data['type'];
        final value = data['value'];
        if (type == 'quick_action') {
          if (value == 'voice') {
            _toggleVoiceInput();
          } else if (value == 'ocr') {
            _pickImage(ImageSource.camera);
          }
        } else if (type == 'text' && value != null) {
          _msgController.text = value.toString();
          _showSnack('متن اشتراک‌گذاری شده آماده است');
        } else if (type == 'image' && value != null) {
          setState(() {
            _pendingAttachments.add(MediaAttachment(
              type: AttachmentType.image,
              path: value.toString(),
              name: 'shared_image.jpg',
              mimeType: 'image/jpeg',
            ));
          });
          _showSnack('تصویر اشتراک‌گذاری شده پیوست شد');
        }
      }
    } catch (_) {}
  }

  Future<void> _initData() async {
    final prefs = await SharedPreferences.getInstance();

    final rawProfiles = prefs.getStringList('ai_profiles_v4') ?? [];
    final loadedProfiles =
        rawProfiles.map((e) => AIProfile.fromJson(jsonDecode(e))).toList();

    final rawSessions = prefs.getStringList('ai_sessions_v4') ?? [];
    final loadedSessions =
        rawSessions.map((e) => ChatSession.fromRawJson(e)).toList();

    final proxyRaw = prefs.getString('proxy_settings_v4');
    if (proxyRaw != null) {
      AIService.proxySettings = ProxySettings.fromJson(jsonDecode(proxyRaw));
    }

    AIService.globalMemory = prefs.getString('global_memory_v4') ?? '';
    AIService.ragEnabled = prefs.getBool('rag_enabled_v4') ?? true;

    final rawKb = prefs.getStringList('knowledge_base_v4') ?? [];
    AIService.knowledgeBase =
        rawKb.map((e) => KnowledgeDoc.fromJson(jsonDecode(e))).toList();

    final rawTools = prefs.getStringList('webhook_tools_v4') ?? [];
    AIService.webhookTools =
        rawTools.map((e) => CustomWebhookTool.fromJson(jsonDecode(e))).toList();

    final rawPrompts = prefs.getStringList('prompt_templates_v4');
    List<PromptTemplate> loadedPrompts;
    if (rawPrompts == null) {
      loadedPrompts = [
        PromptTemplate(
          id: '1',
          title: 'ترجمه روان فارسی / انگلیسی',
          prompt: 'متن زیر را به صورت روان و دقیق ترجمه کن:

',
        ),
        PromptTemplate(
          id: '2',
          title: 'دیباگ و بهینه‌سازی کد',
          prompt: 'کد زیر را بررسی کن، باگ‌ها را رفع کن و نسخه بهینه را بنویس:

',
        ),
        PromptTemplate(
          id: '3',
          title: 'رسم نمودار Mermaid',
          prompt: 'برای موضوع زیر یک فلوچارت یا نمودار دقیق با سینتکس ```mermaid رسم کن:

',
        ),
        PromptTemplate(
          id: '4',
          title: 'ساخت صفحه وب تک‌فایلی (HTML/JS)',
          prompt: 'یک کد کامل و مدرن HTML شامل CSS و JavaScript در یک فایل واحد بنویس برای:

',
        ),
      ];
    } else {
      loadedPrompts = rawPrompts
          .map((e) => PromptTemplate.fromJson(jsonDecode(e)))
          .toList();
    }

    setState(() {
      _biometricLockEnabled = prefs.getBool('biometric_lock_enabled') ?? false;
      _profiles = loadedProfiles;
      if (_profiles.isNotEmpty) {
        _selectedProfile = _profiles.first;
        _arenaSecondProfile =
            _profiles.length > 1 ? _profiles[1] : _profiles.first;
      }

      _promptTemplates = loadedPrompts;
      _sessions = loadedSessions;
      if (_sessions.isEmpty) {
        _sessions.add(ChatSession(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: 'گفتگوی جدید',
          messages: [],
        ));
      }
      _currentSession = _sessions.first;
    });
  }

  Future<void> _saveProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'ai_profiles_v4',
      _profiles.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  Future<void> _saveSessions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'ai_sessions_v4',
      _sessions.map((e) => e.toRawJson()).toList(),
    );
  }

  Future<void> _savePrompts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'prompt_templates_v4',
      _promptTemplates.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  Future<void> _saveKnowledgeAndTools() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('global_memory_v4', AIService.globalMemory);
    await prefs.setBool('rag_enabled_v4', AIService.ragEnabled);
    await prefs.setStringList(
      'knowledge_base_v4',
      AIService.knowledgeBase.map((e) => jsonEncode(e.toJson())).toList(),
    );
    await prefs.setStringList(
      'webhook_tools_v4',
      AIService.webhookTools.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  void _createNewSession() {
    final session = ChatSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: 'گفتگوی جدید',
      messages: [],
    );
    setState(() {
      _sessions.insert(0, session);
      _currentSession = session;
      _pendingAttachments.clear();
    });
    _saveSessions();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _toggleVoiceInput() async {
    if (_isListening) {
      await _stt.stop();
      setState(() => _isListening = false);
      return;
    }

    final available = await _stt.initialize();
    if (!available) {
      _showSnack('دسترسی به میکروفون در دسترس نیست');
      return;
    }

    setState(() => _isListening = true);
    final baseText = _msgController.text;
    await _stt.listen(
      localeId: 'fa_IR',
      onResult: (res) {
        setState(() {
          _msgController.text = baseText.isEmpty
              ? res.recognizedWords
              : '$baseText ${res.recognizedWords}';
          if (res.finalResult) {
            _isListening = false;
          }
        });
      },
    );
  }

  Future<void> _toggleSpeak(ChatMessage msg) async {
    final id = msg.timestamp.toIso8601String();
    if (_speakingMessageId == id) {
      await _tts.stop();
      setState(() => _speakingMessageId = null);
    } else {
      await _tts.stop();
      setState(() => _speakingMessageId = id);
      await _tts.speak(msg.content);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final XFile? file = await _picker.pickImage(
      source: source,
      imageQuality: 85,
    );
    if (file == null) return;
    final ext = file.name.split('.').last.toLowerCase();
    final mime = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
            ? 'image/webp'
            : 'image/jpeg';

    setState(() {
      _pendingAttachments.add(MediaAttachment(
        type: AttachmentType.image,
        path: file.path,
        name: file.name,
        mimeType: mime,
      ));
    });
  }

  Future<void> _pickVideo() async {
    final XFile? file = await _picker.pickVideo(source: ImageSource.gallery);
    if (file == null) return;
    setState(() {
      _pendingAttachments.add(MediaAttachment(
        type: AttachmentType.video,
        path: file.path,
        name: file.name,
        mimeType: 'video/mp4',
      ));
    });
  }

  Future<void> _pickAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'ogg', 'wav', 'm4a', 'aac'],
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final ext = result.files.single.extension?.toLowerCase() ?? 'mp3';
    final mime = ext == 'ogg'
        ? 'audio/ogg'
        : ext == 'wav'
            ? 'audio/wav'
            : ext == 'm4a'
                ? 'audio/mp4'
                : 'audio/mp3';

    setState(() {
      _pendingAttachments.add(MediaAttachment(
        type: AttachmentType.audio,
        path: path,
        name: result.files.single.name,
        mimeType: mime,
      ));
    });
  }

  Future<void> _pickDocumentOrPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [
        'pdf',
        'txt',
        'md',
        'json',
        'dart',
        'py',
        'js',
        'html',
        'yaml',
        'csv',
        'log'
      ],
    );
    if (result == null || result.files.single.path == null) return;
    final f = File(result.files.single.path!);
    final ext = result.files.single.extension?.toLowerCase() ?? '';

    String extractedText = '';
    if (ext == 'pdf') {
      try {
        final bytes = await f.readAsBytes();
        final PdfDocument document = PdfDocument(inputBytes: bytes);
        extractedText = PdfTextExtractor(document).extractText();
        document.dispose();
        if (extractedText.trim().isEmpty) {
          extractedText = '[این فایل PDF فاقد متن قابل استخراج است]';
        }
      } catch (e) {
        _showSnack('خطا در خواندن فایل PDF: $e');
        return;
      }
    } else {
      extractedText = await f.readAsString();
    }

    setState(() {
      _pendingAttachments.add(MediaAttachment(
        type: AttachmentType.document,
        path: f.path,
        name: result.files.single.name,
        mimeType: ext == 'pdf' ? 'application/pdf' : 'text/plain',
        textContent: extractedText,
      ));
    });
  }

  Future<void> _executeGenerationForSession(ChatSession session,
      {File? refImageForEdit}) async {
    setState(() {
      _isLoading = true;
      _loadingStatus = _mode == GenerationMode.imageGen
          ? (refImageForEdit != null
              ? 'در حال ویرایش تصویر (Image-to-Image)...'
              : 'در حال تصویرسازی...')
          : _mode == GenerationMode.videoGen
              ? 'در حال تولید ویدیو (۱ تا ۲ دقیقه)...'
              : _mode == GenerationMode.voiceGen
                  ? 'در حال تولید فایل صوتی استودیویی (MP3)...'
                  : _mode == GenerationMode.arena
                      ? 'در حال استریم هم‌زمان از دو مدل...'
                      : 'در حال دریافت پاسخ زنده...';
    });
    _scrollToBottom();

    final lastUserPrompt = session.messages
        .lastWhere((m) => m.role == 'user',
            orElse: () => ChatMessage(role: 'user', content: ''))
        .content;

    try {
      if (_mode == GenerationMode.imageGen) {
        final imgPath = await AIService.generateOrEditImage(
          profile: _selectedProfile!,
          prompt: lastUserPrompt,
          referenceImage: refImageForEdit,
        );
        setState(() {
          session.messages.add(ChatMessage(
            role: 'assistant',
            content: refImageForEdit != null
                ? 'تصویر ویرایش شد:'
                : 'تصویر ساخته شد:',
            modelLabel: _selectedProfile!.name,
            generatedImagePath: imgPath,
          ));
        });
      } else if (_mode == GenerationMode.videoGen) {
        final vidPath = await AIService.generateVideo(
          profile: _selectedProfile!,
          prompt: lastUserPrompt,
        );
        setState(() {
          session.messages.add(ChatMessage(
            role: 'assistant',
            content: 'ویدیو ساخته شد:',
            modelLabel: _selectedProfile!.name,
            generatedVideoPath: vidPath,
          ));
        });
      } else if (_mode == GenerationMode.voiceGen) {
        final audioPath = await AIService.generateStudioSpeech(
          profile: _selectedProfile!,
          text: lastUserPrompt,
        );
        setState(() {
          session.messages.add(ChatMessage(
            role: 'assistant',
            content: 'فایل صوتی استودیویی ساخته شد:',
            modelLabel: _selectedProfile!.name,
            generatedAudioPath: audioPath,
          ));
        });
      } else if (_mode == GenerationMode.arena) {
        final p1 = _selectedProfile!;
        final p2 = _arenaSecondProfile ?? _selectedProfile!;
        final historySnapshot = List<ChatMessage>.from(session.messages);

        final msg1 = ChatMessage(
          role: 'assistant',
          content: '',
          modelLabel: 'مدل اول: ${p1.name}',
        );
        final msg2 = ChatMessage(
          role: 'assistant',
          content: '',
          modelLabel: 'مدل دوم: ${p2.name}',
        );

        setState(() {
          session.messages.add(msg1);
          session.messages.add(msg2);
        });

        await Future.wait([
          () async {
            try {
              await for (final chunk in AIService.streamChat(
                  profile: p1, history: historySnapshot)) {
                setState(() => msg1.content += chunk);
                _scrollToBottom();
              }
            } catch (e) {
              setState(() => msg1.content += '
⚠️ خطا: $e');
            }
          }(),
          () async {
            try {
              await for (final chunk in AIService.streamChat(
                  profile: p2, history: historySnapshot)) {
                setState(() => msg2.content += chunk);
                _scrollToBottom();
              }
            } catch (e) {
              setState(() => msg2.content += '
⚠️ خطا: $e');
            }
          }(),
        ]);
      } else {
        final historySnapshot = List<ChatMessage>.from(session.messages);
        final assistantMsg = ChatMessage(
          role: 'assistant',
          content: '',
          modelLabel: _selectedProfile!.name,
        );
        setState(() => session.messages.add(assistantMsg));

        await for (final chunk in AIService.streamChat(
          profile: _selectedProfile!,
          history: historySnapshot,
        )) {
          setState(() => assistantMsg.content += chunk);
          _scrollToBottom();
        }
      }
    } catch (e) {
      setState(() {
        session.messages.add(ChatMessage(
          role: 'assistant',
          content: '⚠️ خطا:
$e',
        ));
      });
    } finally {
      setState(() {
        _isLoading = false;
        _loadingStatus = '';
      });
      await _saveSessions();
      _scrollToBottom();
    }
  }

  Future<void> _handleSend() async {
    final text = _msgController.text.trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) || _isLoading) return;

    if (_selectedProfile == null) {
      _showSnack('ابتدا از آیکون کلید بالا یک API Token اضافه کنید.');
      return;
    }

    final session = _currentSession!;
    final attachmentsCopy = List<MediaAttachment>.from(_pendingAttachments);

    File? refImageForEdit;
    if (_mode == GenerationMode.imageGen && attachmentsCopy.isNotEmpty) {
      final imgAtt = attachmentsCopy.firstWhere(
        (a) => a.type == AttachmentType.image,
        orElse: () => attachmentsCopy.first,
      );
      if (imgAtt.type == AttachmentType.image) {
        refImageForEdit = File(imgAtt.path);
      }
    }

    if (session.messages.isEmpty && text.isNotEmpty) {
      session.title = text.length > 28 ? '${text.substring(0, 28)}...' : text;
    }

    setState(() {
      session.messages.add(ChatMessage(
        role: 'user',
        content: text,
        attachments: attachmentsCopy,
      ));
      session.updatedAt = DateTime.now();
      _pendingAttachments.clear();
    });
    _msgController.clear();
    await _saveSessions();

    await _executeGenerationForSession(session,
        refImageForEdit: refImageForEdit);
  }

  /// Edit an existing user message and re-run from that point
  void _editUserMessage(int index) {
    final session = _currentSession!;
    final target = session.messages[index];
    final editCtrl = TextEditingController(text: target.content);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ویرایش پیام و ارسال مجدد'),
        content: TextField(
          controller: editCtrl,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('لغو')),
          FilledButton(
            onPressed: () async {
              final updated = editCtrl.text.trim();
              if (updated.isEmpty) return;
              Navigator.pop(ctx);
              setState(() {
                target.content = updated;
                session.messages.removeRange(index + 1, session.messages.length);
              });
              await _saveSessions();
              await _executeGenerationForSession(session);
            },
            child: const Text('ذخیره و ارسال'),
          ),
        ],
      ),
    );
  }

  /// Regenerate an assistant response
  Future<void> _regenerateFromAssistant(int index) async {
    if (_isLoading || _selectedProfile == null) return;
    final session = _currentSession!;
    setState(() {
      session.messages.removeRange(index, session.messages.length);
    });
    await _saveSessions();
    await _executeGenerationForSession(session);
  }

  /// Export current chat session to a clean PDF file and share/save it
  Future<void> _exportSessionToPdf() async {
    final session = _currentSession;
    if (session == null || session.messages.isEmpty) {
      _showSnack('گفتگویی برای خروجی گرفتن وجود ندارد.');
      return;
    }

    try {
      final PdfDocument document = PdfDocument();
      PdfPage page = document.pages.add();
      final PdfFont font = PdfStandardFont(PdfFontFamily.helvetica, 11);
      final PdfFont boldFont =
          PdfStandardFont(PdfFontFamily.helvetica, 12, style: PdfFontStyle.bold);

      double yOffset = 10;
      final pageWidth = page.getClientSize().width;
      final pageHeight = page.getClientSize().height;

      for (final m in session.messages) {
        final header = m.role == 'user'
            ? 'USER:'
            : 'ASSISTANT (${m.modelLabel ?? "AI"}):';
        if (yOffset + 40 > pageHeight) {
          page = document.pages.add();
          yOffset = 10;
        }
        page.graphics.drawString(
          header,
          boldFont,
          bounds: Rect.fromLTWH(0, yOffset, pageWidth, 20),
        );
        yOffset += 20;

        final layoutResult = PdfTextElement(text: m.content, font: font).draw(
          page: page,
          bounds: Rect.fromLTWH(0, yOffset, pageWidth, pageHeight - yOffset),
        );
        if (layoutResult != null) {
          page = layoutResult.page;
          yOffset = layoutResult.bounds.bottom + 14;
        } else {
          yOffset += 30;
        }
      }

      final bytes = await document.save();
      document.dispose();

      final dir = await getTemporaryDirectory();
      final pdfFile = File(
          '${dir.path}/chat_export_${DateTime.now().millisecondsSinceEpoch}.pdf');
      await pdfFile.writeAsBytes(bytes);

      await Share.shareXFiles([XFile(pdfFile.path)],
          text: 'خروجی PDF گفتگو: ${session.title}');
    } catch (e) {
      _showSnack('خطا در ساخت PDF: $e');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.cyanAccent),
              title: const Text('آپلود تصویر (Vision / Image-to-Image)'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.tealAccent),
              title: const Text('گرفتن عکس با دوربین'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
            if (_mode != GenerationMode.imageGen) ...[
              ListTile(
                leading:
                    const Icon(Icons.audiotrack, color: Colors.greenAccent),
                title: const Text('آپلود فایل صوتی (.mp3, .ogg, .wav, .m4a)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAudio();
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.video_library, color: Colors.amberAccent),
                title: const Text('آپلود ویدیو (تحلیل ویدیو در Gemini)'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickVideo();
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
                title: const Text('آپلود PDF چندصفحه‌ای یا فایل کد'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickDocumentOrPdf();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Opens Knowledge Base (Local RAG), Global Memory & Custom Webhook Tools Manager
  void _openAgenticAndRagStudio() {
    final memCtrl = TextEditingController(text: AIService.globalMemory);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DefaultTabController(
        length: 3,
        child: StatefulBuilder(
          builder: (context, setModalState) => SizedBox(
            height: MediaQuery.of(context).size.height * 0.85,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(icon: Icon(Icons.psychology), text: 'حافظه سراسری'),
                    Tab(icon: Icon(Icons.folder_special), text: 'پایگاه دانش (RAG)'),
                    Tab(icon: Icon(Icons.webhook), text: 'ابزار Webhook'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      // Tab 1: Global Long-Term Memory
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'حافظه بلندمدت سراسری (Global Memory)',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'نکات ثابت درباره خودتان، زبان برنامه‌نویسی مورد علاقه یا سبک پاسخ‌دهی را بنویسید تا به تمام گفتگوها اضافه شود:',
                              style: TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: TextField(
                                controller: memCtrl,
                                maxLines: null,
                                expands: true,
                                textAlignVertical: TextAlignVertical.top,
                                decoration: const InputDecoration(
                                  hintText:
                                      'مثلاً: من توسعه‌دهنده لینوکس و فلاتر هستم. همیشه پاسخ‌ها را فنی، خلاصه و همراه با کد بنویس.',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: () async {
                                AIService.globalMemory = memCtrl.text.trim();
                                await _saveKnowledgeAndTools();
                                _showSnack('حافظه بلندمدت ذخیره شد');
                              },
                              icon: const Icon(Icons.save),
                              label: const Text('ذخیره حافظه سراسری'),
                            ),
                          ],
                        ),
                      ),

                      // Tab 2: Local RAG Knowledge Base
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('جستجوی خودکار در پایگاه دانش (RAG)'),
                              value: AIService.ragEnabled,
                              onChanged: (v) async {
                                setModalState(() => AIService.ragEnabled = v);
                                await _saveKnowledgeAndTools();
                              },
                            ),
                            FilledButton.icon(
                              onPressed: () async {
                                final res = await FilePicker.platform.pickFiles(
                                  type: FileType.custom,
                                  allowedExtensions: [
                                    'pdf',
                                    'txt',
                                    'md',
                                    'dart',
                                    'py',
                                    'json',
                                    'csv'
                                  ],
                                );
                                if (res == null ||
                                    res.files.single.path == null) return;
                                final f = File(res.files.single.path!);
                                final ext =
                                    res.files.single.extension?.toLowerCase() ??
                                        '';
                                String text = '';
                                if (ext == 'pdf') {
                                  final doc = PdfDocument(
                                      inputBytes: await f.readAsBytes());
                                  text = PdfTextExtractor(doc).extractText();
                                  doc.dispose();
                                } else {
                                  text = await f.readAsString();
                                }
                                setModalState(() {
                                  AIService.knowledgeBase.add(KnowledgeDoc(
                                    id: DateTime.now()
                                        .millisecondsSinceEpoch
                                        .toString(),
                                    title: res.files.single.name,
                                    content: text,
                                  ));
                                });
                                await _saveKnowledgeAndTools();
                                _showSnack('سند به پایگاه دانش اضافه شد');
                              },
                              icon: const Icon(Icons.upload_file),
                              label: const Text('افزودن فایل PDF / جزوه / کد به منابع'),
                            ),
                            const Divider(),
                            Expanded(
                              child: AIService.knowledgeBase.isEmpty
                                  ? const Center(
                                      child: Text('هنوز سندی اضافه نشده است.'))
                                  : ListView.builder(
                                      itemCount:
                                          AIService.knowledgeBase.length,
                                      itemBuilder: (_, i) {
                                        final doc = AIService.knowledgeBase[i];
                                        return ListTile(
                                          leading:
                                              const Icon(Icons.article_outlined),
                                          title: Text(doc.title),
                                          subtitle: Text(
                                              '${doc.content.length} کاراکتر'),
                                          trailing: IconButton(
                                            icon: const Icon(Icons.delete,
                                                color: Colors.redAccent),
                                            onPressed: () async {
                                              setModalState(() => AIService
                                                  .knowledgeBase
                                                  .removeAt(i));
                                              await _saveKnowledgeAndTools();
                                            },
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),

                      // Tab 3: Custom Webhook Function Calling Tools
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            FilledButton.icon(
                              onPressed: () {
                                final nameCtrl = TextEditingController();
                                final descCtrl = TextEditingController();
                                final urlCtrl = TextEditingController();
                                final bodyCtrl = TextEditingController(
                                    text: '{"text": "{{query}}"}');
                                String method = 'POST';

                                showDialog(
                                  context: context,
                                  builder: (dCtx) => StatefulBuilder(
                                    builder: (c, setDState) => AlertDialog(
                                      title: const Text('تعریف ابزار Webhook'),
                                      content: SingleChildScrollView(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            TextField(
                                              controller: nameCtrl,
                                              decoration: const InputDecoration(
                                                  labelText:
                                                      'نام تابع انگلیسی (مثلاً telegram_notify)'),
                                            ),
                                            TextField(
                                              controller: descCtrl,
                                              decoration: const InputDecoration(
                                                  labelText:
                                                      'توضیح برای هوش مصنوعی (چه زمانی صدا بزند؟)'),
                                            ),
                                            DropdownButtonFormField<String>(
                                              value: method,
                                              items: const [
                                                DropdownMenuItem(
                                                    value: 'POST',
                                                    child: Text('POST')),
                                                DropdownMenuItem(
                                                    value: 'GET',
                                                    child: Text('GET')),
                                              ],
                                              onChanged: (v) {
                                                if (v != null) {
                                                  setDState(() => method = v);
                                                }
                                              },
                                            ),
                                            TextField(
                                              controller: urlCtrl,
                                              decoration: const InputDecoration(
                                                  labelText:
                                                      'Webhook URL (از {{query}} استفاده کنید)'),
                                            ),
                                            if (method == 'POST')
                                              TextField(
                                                controller: bodyCtrl,
                                                maxLines: 2,
                                                decoration:
                                                    const InputDecoration(
                                                        labelText:
                                                            'JSON Body Template'),
                                              ),
                                          ],
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dCtx),
                                            child: const Text('لغو')),
                                        FilledButton(
                                          onPressed: () async {
                                            if (nameCtrl.text.trim().isEmpty ||
                                                urlCtrl.text.trim().isEmpty) {
                                              return;
                                            }
                                            setModalState(() {
                                              AIService.webhookTools
                                                  .add(CustomWebhookTool(
                                                id: DateTime.now()
                                                    .millisecondsSinceEpoch
                                                    .toString(),
                                                name: nameCtrl.text
                                                    .trim()
                                                    .replaceAll(' ', '_'),
                                                description:
                                                    descCtrl.text.trim(),
                                                method: method,
                                                url: urlCtrl.text.trim(),
                                                bodyTemplate:
                                                    bodyCtrl.text.trim(),
                                              ));
                                            });
                                            await _saveKnowledgeAndTools();
                                            if (dCtx.mounted) {
                                              Navigator.pop(dCtx);
                                            }
                                          },
                                          child: const Text('ذخیره'),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.add_link),
                              label: const Text('افزودن ابزار Webhook جدید'),
                            ),
                            const Divider(),
                            Expanded(
                              child: AIService.webhookTools.isEmpty
                                  ? const Center(
                                      child: Text(
                                          'ابزار سفارشی تعریف نشده است. هوش مصنوعی می‌تواند در صورت نیاز این وب‌هوک‌ها را فراخوانی کند.'))
                                  : ListView.builder(
                                      itemCount: AIService.webhookTools.length,
                                      itemBuilder: (_, i) {
                                        final t = AIService.webhookTools[i];
                                        return SwitchListTile(
                                          title: Text(t.name),
                                          subtitle: Text(t.url,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis),
                                          value: t.enabled,
                                          secondary: IconButton(
                                            icon: const Icon(Icons.delete,
                                                color: Colors.redAccent),
                                            onPressed: () async {
                                              setModalState(() => AIService
                                                  .webhookTools
                                                  .removeAt(i));
                                              await _saveKnowledgeAndTools();
                                            },
                                          ),
                                          onChanged: (v) async {
                                            setModalState(() => t.enabled = v);
                                            await _saveKnowledgeAndTools();
                                          },
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openPromptLibrary() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.65,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('کتابخانه پرامپت‌های آماده',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    FilledButton.icon(
                      onPressed: () {
                        final titleCtrl = TextEditingController();
                        final textCtrl = TextEditingController();
                        showDialog(
                          context: context,
                          builder: (dCtx) => AlertDialog(
                            title: const Text('پرامپت جدید'),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextField(
                                  controller: titleCtrl,
                                  decoration: const InputDecoration(
                                      labelText: 'عنوان کوتاه'),
                                ),
                                TextField(
                                  controller: textCtrl,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                      labelText: 'متن دستور (Prompt)'),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(dCtx),
                                  child: const Text('لغو')),
                              FilledButton(
                                onPressed: () {
                                  if (titleCtrl.text.trim().isEmpty ||
                                      textCtrl.text.trim().isEmpty) return;
                                  setState(() {
                                    _promptTemplates.add(PromptTemplate(
                                      id: DateTime.now()
                                          .millisecondsSinceEpoch
                                          .toString(),
                                      title: titleCtrl.text.trim(),
                                      prompt: textCtrl.text.trim(),
                                    ));
                                  });
                                  setModalState(() {});
                                  _savePrompts();
                                  Navigator.pop(dCtx);
                                },
                                child: const Text('افزودن'),
                              ),
                            ],
                          ),
                        );
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('جدید'),
                    ),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: _promptTemplates.length,
                    itemBuilder: (_, i) {
                      final pt = _promptTemplates[i];
                      return ListTile(
                        leading: const Icon(Icons.auto_fix_high,
                            color: Colors.cyanAccent),
                        title: Text(pt.title),
                        subtitle: Text(pt.prompt,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () {
                            setState(() => _promptTemplates.removeAt(i));
                            setModalState(() {});
                            _savePrompts();
                          },
                        ),
                        onTap: () {
                          _msgController.text = pt.prompt + _msgController.text;
                          Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Opens Network, Proxy, Floating Bubble, Cache Cleanup & Backup Manager
  Future<void> _openNetworkAndSystemSettings() async {
    final hostCtrl = TextEditingController(text: AIService.proxySettings.host);
    final portCtrl =
        TextEditingController(text: AIService.proxySettings.port.toString());
    bool proxyEnabled = AIService.proxySettings.enabled;
    String proxyType = AIService.proxySettings.type;
    bool lockEnabled = _biometricLockEnabled;
    bool bubbleEnabled = _floatingBubbleEnabled;

    // Calculate generated media disk usage
    final docDir = await getApplicationDocumentsDirectory();
    final mediaFiles = docDir.listSync().whereType<File>().where((f) {
      final name = f.uri.pathSegments.last;
      return name.startsWith('img_') ||
          name.startsWith('vid_') ||
          name.startsWith('voice_');
    }).toList();

    int totalBytes = 0;
    for (final f in mediaFiles) {
      totalBytes += await f.length();
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('تنظیمات سیستم، پروکسی و کش'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('پنجره شناور (Floating Bubble)'),
                  subtitle: const Text('آیکون دسترسی سریع روی سایر برنامه‌ها'),
                  value: bubbleEnabled,
                  onChanged: (v) async {
                    if (v) {
                      final ok = await _nativeChannel
                          .invokeMethod<bool>('startFloatingBubble');
                      if (ok == true) {
                        setDialogState(() => bubbleEnabled = true);
                        setState(() => _floatingBubbleEnabled = true);
                      } else {
                        _showSnack(
                            'لطفاً دسترسی Display over other apps را فعال کنید');
                      }
                    } else {
                      await _nativeChannel.invokeMethod('stopFloatingBubble');
                      setDialogState(() => bubbleEnabled = false);
                      setState(() => _floatingBubbleEnabled = false);
                    }
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('قفل بیومتریک (اثر انگشت)'),
                  value: lockEnabled,
                  onChanged: (v) => setDialogState(() => lockEnabled = v),
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('پروکسی داخلی (HTTP / SOCKS5)'),
                  value: proxyEnabled,
                  onChanged: (v) => setDialogState(() => proxyEnabled = v),
                ),
                if (proxyEnabled) ...[
                  DropdownButtonFormField<String>(
                    value: proxyType,
                    decoration: const InputDecoration(labelText: 'نوع پروکسی'),
                    items: const [
                      DropdownMenuItem(value: 'HTTP', child: Text('HTTP Proxy')),
                      DropdownMenuItem(
                          value: 'SOCKS5', child: Text('SOCKS5 Proxy')),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialogState(() => proxyType = v);
                    },
                  ),
                  TextField(
                    controller: hostCtrl,
                    decoration: const InputDecoration(labelText: 'آدرس سرور'),
                  ),
                  TextField(
                    controller: portCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'پورت'),
                  ),
                ],
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cleaning_services,
                      color: Colors.amberAccent),
                  title: Text(
                      'حافظه رسانه‌های ساخته‌شده: ${(totalBytes / (1024 * 1024)).toStringAsFixed(2)} MB (${mediaFiles.length} فایل)'),
                  subtitle: const Text('لمس برای پاک‌سازی تمام عکس/ویدیو/صداهای کش'),
                  onTap: () async {
                    for (final f in mediaFiles) {
                      if (await f.exists()) await f.delete();
                    }
                    setDialogState(() {
                      mediaFiles.clear();
                      totalBytes = 0;
                    });
                    _showSnack('تمام فایل‌های رسانه پاک‌سازی شدند');
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.download),
                  title: const Text('خروجی بکاپ کامل (JSON)'),
                  onTap: () {
                    final fullBackup = jsonEncode({
                      'profiles': _profiles.map((e) => e.toJson()).toList(),
                      'sessions': _sessions
                          .map((e) => jsonDecode(e.toRawJson()))
                          .toList(),
                      'globalMemory': AIService.globalMemory,
                    });
                    Clipboard.setData(ClipboardData(text: fullBackup));
                    _showSnack('بکاپ کامل JSON در کلیپ‌بورد کپی شد');
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.upload),
                  title: const Text('بازیابی بکاپ از کلیپ‌بورد (Import)'),
                  onTap: () async {
                    final clip = await Clipboard.getData('text/plain');
                    if (clip?.text == null) return;
                    try {
                      final decoded = jsonDecode(clip!.text!);
                      if (decoded is Map && decoded['profiles'] != null) {
                        final pList = (decoded['profiles'] as List)
                            .map((e) => AIProfile.fromJson(e))
                            .toList();
                        final sList = (decoded['sessions'] as List? ?? [])
                            .map((e) => ChatSession.fromRawJson(jsonEncode(e)))
                            .toList();
                        if (decoded['globalMemory'] != null) {
                          AIService.globalMemory =
                              decoded['globalMemory'].toString();
                          await _saveKnowledgeAndTools();
                        }
                        setState(() {
                          _profiles = pList;
                          if (_profiles.isNotEmpty) {
                            _selectedProfile = _profiles.first;
                          }
                          if (sList.isNotEmpty) {
                            _sessions = sList;
                            _currentSession = _sessions.first;
                          }
                        });
                        await _saveProfiles();
                        await _saveSessions();
                        _showSnack('بکاپ با موفقیت بازیابی شد!');
                      }
                    } catch (e) {
                      _showSnack('فرمت JSON نامعتبر است: $e');
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('لغو')),
            FilledButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                AIService.proxySettings = ProxySettings(
                  enabled: proxyEnabled,
                  type: proxyType,
                  host: hostCtrl.text.trim(),
                  port: int.tryParse(portCtrl.text.trim()) ?? 10808,
                );
                await prefs.setString('proxy_settings_v4',
                    jsonEncode(AIService.proxySettings.toJson()));
                await prefs.setBool('biometric_lock_enabled', lockEnabled);
                setState(() => _biometricLockEnabled = lockEnabled);
                if (ctx.mounted) Navigator.pop(ctx);
                _showSnack('تنظیمات ذخیره شد');
              },
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
  }

  void _openTokenManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.78,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'مدیریت API Token ها',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showAddEditProfileDialog();
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('افزودن توکن'),
                    ),
                  ],
                ),
                const Divider(),
                Expanded(
                  child: _profiles.isEmpty
                      ? const Center(
                          child: Text('هنوز هیچ API Token اضافه نشده است.'))
                      : ListView.builder(
                          itemCount: _profiles.length,
                          itemBuilder: (_, i) {
                            final p = _profiles[i];
                            return Card(
                              child: ListTile(
                                title: Text(p.name,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                                subtitle: Text(
                                    '${p.provider} • ${p.chatModel} • ${p.apiKeys.length} Key(s)'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit),
                                      onPressed: () {
                                        Navigator.pop(ctx);
                                        _showAddEditProfileDialog(existing: p);
                                      },
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          color: Colors.redAccent),
                                      onPressed: () async {
                                        setState(() {
                                          _profiles.removeAt(i);
                                          if (_selectedProfile?.id == p.id) {
                                            _selectedProfile =
                                                _profiles.isNotEmpty
                                                    ? _profiles.first
                                                    : null;
                                          }
                                        });
                                        setModalState(() {});
                                        await _saveProfiles();
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showAddEditProfileDialog({AIProfile? existing}) {
    String provider = existing?.provider ?? 'gemini';
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final keysCtrl =
        TextEditingController(text: existing?.apiKeys.join('
') ?? '');
    final urlCtrl = TextEditingController(
      text: existing?.baseUrl ?? 'https://generativelanguage.googleapis.com',
    );
    final chatModelCtrl =
        TextEditingController(text: existing?.chatModel ?? 'gemini-2.5-flash');
    final imgModelCtrl = TextEditingController(
        text: existing?.imageModel ?? 'imagen-3.0-generate-002');
    final vidModelCtrl = TextEditingController(
        text: existing?.videoModel ?? 'veo-2.0-generate-001');
    final voiceModelCtrl =
        TextEditingController(text: existing?.voiceModel ?? 'tts-1');
    final voiceIdCtrl =
        TextEditingController(text: existing?.voiceId ?? 'alloy');
    final sysPromptCtrl =
        TextEditingController(text: existing?.systemPrompt ?? '');
    double temp = existing?.temperature ?? 0.7;
    bool webSearch = existing?.enableWebSearch ?? false;
    bool fetchingModels = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'افزودن API Token' : 'ویرایش API'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: provider,
                  decoration: const InputDecoration(labelText: 'سرویس‌دهنده'),
                  items: const [
                    DropdownMenuItem(
                        value: 'gemini', child: Text('Google Gemini')),
                    DropdownMenuItem(
                        value: 'openai_compatible',
                        child: Text('OpenAI / OpenRouter / DeepSeek / Ollama')),
                    DropdownMenuItem(
                        value: 'claude', child: Text('Anthropic Claude')),
                    DropdownMenuItem(
                        value: 'elevenlabs',
                        child: Text('ElevenLabs (تولید صوت)')),
                  ],
                  onChanged: (val) {
                    if (val == null) return;
                    setDialogState(() {
                      provider = val;
                      if (val == 'gemini') {
                        urlCtrl.text =
                            'https://generativelanguage.googleapis.com';
                        chatModelCtrl.text = 'gemini-2.5-flash';
                        imgModelCtrl.text = 'imagen-3.0-generate-002';
                        vidModelCtrl.text = 'veo-2.0-generate-001';
                      } else if (val == 'claude') {
                        urlCtrl.text = 'https://api.anthropic.com';
                        chatModelCtrl.text = 'claude-3-7-sonnet-20250219';
                        imgModelCtrl.text = '';
                        vidModelCtrl.text = '';
                      } else if (val == 'elevenlabs') {
                        urlCtrl.text = 'https://api.elevenlabs.io';
                        voiceModelCtrl.text = 'eleven_multilingual_v2';
                        voiceIdCtrl.text = '21m00Tcm4TlvDq8ikWAM';
                      } else {
                        urlCtrl.text = 'https://api.openai.com/v1';
                        chatModelCtrl.text = 'gpt-4o';
                        imgModelCtrl.text = 'dall-e-3';
                        vidModelCtrl.text = 'sora-2';
                        voiceModelCtrl.text = 'tts-1';
                        voiceIdCtrl.text = 'alloy';
                      }
                    });
                  },
                ),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                      labelText: 'نام پروفایل (مثلاً Gemini Pro)'),
                ),
                TextField(
                  controller: keysCtrl,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    labelText: 'API Key(s) - هر خط یک کلید برای چرخش خودکار',
                    hintText: 'AIzaSy...
AIzaSy... (کلید دوم اختیاری)',
                  ),
                ),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(labelText: 'Base URL'),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: chatModelCtrl,
                        decoration:
                            const InputDecoration(labelText: 'مدل چت (Chat)'),
                      ),
                    ),
                    IconButton(
                      tooltip: 'دریافت خودکار لیست مدل‌ها از سرور',
                      icon: fetchingModels
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_download,
                              color: Colors.cyanAccent),
                      onPressed: () async {
                        final firstKey = keysCtrl.text
                            .split(RegExp(r'[
,]'))
                            .map((e) => e.trim())
                            .firstWhere((e) => e.isNotEmpty, orElse: () => '');
                        if (firstKey.isEmpty) {
                          _showSnack('ابتدا API Key را وارد کنید');
                          return;
                        }
                        setDialogState(() => fetchingModels = true);
                        try {
                          final models = await AIService.fetchAvailableModels(
                            provider: provider,
                            baseUrl: urlCtrl.text,
                            apiKey: firstKey,
                          );
                          if (!context.mounted) return;
                          showDialog(
                            context: context,
                            builder: (mCtx) => SimpleDialog(
                              title:
                                  Text('انتخاب مدل (${models.length} مدل یافت شد)'),
                              children: models
                                  .map((m) => SimpleDialogOption(
                                        onPressed: () {
                                          chatModelCtrl.text = m;
                                          Navigator.pop(mCtx);
                                        },
                                        child: Text(m),
                                      ))
                                  .toList(),
                            ),
                          );
                        } catch (e) {
                          _showSnack('$e');
                        } finally {
                          setDialogState(() => fetchingModels = false);
                        }
                      },
                    ),
                  ],
                ),
                TextField(
                  controller: imgModelCtrl,
                  decoration:
                      const InputDecoration(labelText: 'مدل تصویرسازی (Image)'),
                ),
                TextField(
                  controller: vidModelCtrl,
                  decoration:
                      const InputDecoration(labelText: 'مدل ساخت ویدیو (Video)'),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: voiceModelCtrl,
                        decoration:
                            const InputDecoration(labelText: 'مدل صوت (TTS)'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: voiceIdCtrl,
                        decoration: const InputDecoration(
                            labelText: 'صدا / Voice ID'),
                      ),
                    ),
                  ],
                ),
                if (provider == 'gemini')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('جستجوی زنده گوگل (Web Search)'),
                    value: webSearch,
                    onChanged: (v) => setDialogState(() => webSearch = v),
                  ),
                TextField(
                  controller: sysPromptCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                      labelText: 'System Prompt اختصاصی (اختیاری)'),
                ),
                Row(
                  children: [
                    Text('Temp: ${temp.toStringAsFixed(1)}'),
                    Expanded(
                      child: Slider(
                        value: temp,
                        min: 0.0,
                        max: 2.0,
                        divisions: 20,
                        onChanged: (v) => setDialogState(() => temp = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('لغو')),
            FilledButton(
              onPressed: () async {
                final parsedKeys = keysCtrl.text
                    .split(RegExp(r'[
,]'))
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList();
                if (nameCtrl.text.trim().isEmpty || parsedKeys.isEmpty) {
                  return;
                }
                final profile = AIProfile(
                  id: existing?.id ??
                      DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameCtrl.text.trim(),
                  provider: provider,
                  apiKeys: parsedKeys,
                  baseUrl: urlCtrl.text.trim().replaceAll(RegExp(r'/$'), ''),
                  chatModel: chatModelCtrl.text.trim(),
                  imageModel: imgModelCtrl.text.trim(),
                  videoModel: vidModelCtrl.text.trim(),
                  voiceModel: voiceModelCtrl.text.trim(),
                  voiceId: voiceIdCtrl.text.trim(),
                  systemPrompt: sysPromptCtrl.text.trim(),
                  temperature: temp,
                  enableWebSearch: webSearch,
                );
                setState(() {
                  if (existing != null) {
                    final idx =
                        _profiles.indexWhere((e) => e.id == existing.id);
                    _profiles[idx] = profile;
                  } else {
                    _profiles.add(profile);
                  }
                  _selectedProfile = profile;
                  _arenaSecondProfile ??= profile;
                });
                await _saveProfiles();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
  }

  void _openHtmlOrDiagramRunner(String htmlDocument) {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..loadHtmlString(htmlDocument);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            AppBar(
              title: const Text('پیش‌نمایش گرافیکی / اجرای زنده'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            Expanded(child: WebViewWidget(controller: controller)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = _currentSession?.messages ?? [];
    final totalTokens = _currentSession?.totalEstimatedTokens ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: _profiles.isEmpty
            ? const Text('AI Studio v4')
            : DropdownButton<AIProfile>(
                value: _selectedProfile,
                underline: const SizedBox(),
                items: _profiles
                    .map((p) => DropdownMenuItem(
                          value: p,
                          child: Text(p.name, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (val) => setState(() => _selectedProfile = val),
              ),
        actions: [
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.cyanAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '~$totalTokens',
                style: const TextStyle(fontSize: 10, color: Colors.cyanAccent),
              ),
            ),
          ),
          IconButton(
            tooltip: 'حافظه سراسری، پایگاه دانش (RAG) و ابزار Webhook',
            icon: const Icon(Icons.psychology_alt, color: Colors.tealAccent),
            onPressed: _openAgenticAndRagStudio,
          ),
          IconButton(
            tooltip: 'خروجی PDF از گفتگو',
            icon: const Icon(Icons.picture_as_pdf_outlined),
            onPressed: _exportSessionToPdf,
          ),
          IconButton(
            tooltip: 'تنظیمات سیستم، پروکسی و کش',
            icon: Icon(
              Icons.shield_outlined,
              color:
                  AIService.proxySettings.enabled ? Colors.greenAccent : null,
            ),
            onPressed: _openNetworkAndSystemSettings,
          ),
          IconButton(
            tooltip: 'مدیریت API Token ها',
            icon: const Icon(Icons.vpn_key),
            onPressed: _openTokenManager,
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: [
              ListTile(
                title: const Text('تاریخچه گفتگوها',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                trailing: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    Navigator.pop(context);
                    _createNewSession();
                  },
                ),
              ),
              const Divider(),
              Expanded(
                child: ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (_, i) {
                    final s = _sessions[i];
                    final selected = s.id == _currentSession?.id;
                    return ListTile(
                      selected: selected,
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(s.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('~${s.totalEstimatedTokens} توکن',
                          style: const TextStyle(fontSize: 11)),
                      trailing: _sessions.length > 1
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () {
                                setState(() {
                                  _sessions.removeAt(i);
                                  if (selected) {
                                    _currentSession = _sessions.first;
                                  }
                                });
                                _saveSessions();
                              },
                            )
                          : null,
                      onTap: () {
                        setState(() => _currentSession = s);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          // Mode Selector Bar (Chat / Arena / Image / Video / Studio Voice)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: SegmentedButton<GenerationMode>(
              segments: const [
                ButtonSegment(
                  value: GenerationMode.chat,
                  label: Text('چت'),
                  icon: Icon(Icons.chat, size: 15),
                ),
                ButtonSegment(
                  value: GenerationMode.arena,
                  label: Text('مقایسه'),
                  icon: Icon(Icons.compare_arrows, size: 15),
                ),
                ButtonSegment(
                  value: GenerationMode.imageGen,
                  label: Text('تصویر'),
                  icon: Icon(Icons.image, size: 15),
                ),
                ButtonSegment(
                  value: GenerationMode.videoGen,
                  label: Text('ویدیو'),
                  icon: Icon(Icons.movie, size: 15),
                ),
                ButtonSegment(
                  value: GenerationMode.voiceGen,
                  label: Text('تولید صوت'),
                  icon: Icon(Icons.record_voice_over, size: 15),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (set) => setState(() => _mode = set.first),
            ),
          ),

          if (_mode == GenerationMode.arena && _profiles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
              child: Row(
                children: [
                  const Text('مدل دوم مقایسه: ',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<AIProfile>(
                      isExpanded: true,
                      value: _arenaSecondProfile ?? _profiles.first,
                      items: _profiles
                          .map((p) => DropdownMenuItem(
                                value: p,
                                child: Text(p.name,
                                    overflow: TextOverflow.ellipsis),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _arenaSecondProfile = v),
                    ),
                  ),
                ],
              ),
            ),

          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _profiles.isEmpty
                            ? 'برای شروع از آیکون کلید (🔑) بالا API Token اضافه کنید'
                            : 'گفتگو، مقایسه دو مدل، تصویرسازی/ویرایش عکس، ساخت ویدیو یا تولید صوت استودیویی را شروع کنید!',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade400),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (_, i) {
                      final m = messages[i];
                      final isSpeaking =
                          _speakingMessageId == m.timestamp.toIso8601String();
                      return _MessageBubble(
                        message: m,
                        isSpeaking: isSpeaking,
                        onSpeakToggle: () => _toggleSpeak(m),
                        onEditUser: m.role == 'user'
                            ? () => _editUserMessage(i)
                            : null,
                        onRegenerate: m.role == 'assistant'
                            ? () => _regenerateFromAssistant(i)
                            : null,
                        onRenderWeb: _openHtmlOrDiagramRunner,
                        onCopy: () {
                          Clipboard.setData(ClipboardData(text: m.content));
                          _showSnack('متن کپی شد');
                        },
                      );
                    },
                  ),
          ),

          if (_isLoading)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  const LinearProgressIndicator(),
                  const SizedBox(height: 4),
                  Text(_loadingStatus, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),

          if (_pendingAttachments.isNotEmpty)
            SizedBox(
              height: 68,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemCount: _pendingAttachments.length,
                itemBuilder: (_, i) {
                  final att = _pendingAttachments[i];
                  return Stack(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(right: 8, top: 6),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            if (att.type == AttachmentType.image)
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.file(File(att.path),
                                    width: 46, height: 46, fit: BoxFit.cover),
                              )
                            else
                              Icon(
                                att.type == AttachmentType.video
                                    ? Icons.videocam
                                    : att.type == AttachmentType.audio
                                        ? Icons.audiotrack
                                        : Icons.picture_as_pdf,
                                size: 32,
                              ),
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 90),
                              child: Text(att.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        right: 2,
                        top: 0,
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _pendingAttachments.removeAt(i)),
                          child: const CircleAvatar(
                            radius: 10,
                            backgroundColor: Colors.red,
                            child: Icon(Icons.close,
                                size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(6.0),
            child: Row(
              children: [
                if (_mode == GenerationMode.chat ||
                    _mode == GenerationMode.arena ||
                    _mode == GenerationMode.imageGen)
                  IconButton(
                    tooltip: _mode == GenerationMode.imageGen
                        ? 'پیوست تصویر مرجع برای ویرایش (Image-to-Image)'
                        : 'پیوست عکس، صدا، ویدیو یا PDF',
                    icon: const Icon(Icons.attach_file),
                    onPressed: _openAttachmentMenu,
                  ),
                IconButton(
                  tooltip: 'کتابخانه پرامپت‌ها',
                  icon: const Icon(Icons.bookmarks_outlined),
                  onPressed: _openPromptLibrary,
                ),
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    maxLines: 4,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: _isListening
                          ? 'در حال گوش دادن...'
                          : _mode == GenerationMode.imageGen
                              ? 'توصیف تصویر (یا دستور تغییر عکس پیوست‌شده)...'
                              : _mode == GenerationMode.videoGen
                                  ? 'توصیف ویدیو...'
                                  : _mode == GenerationMode.voiceGen
                                      ? 'متن تبدیل به صوت استودیویی MP3...'
                                      : 'پیام بنویسید...',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24)),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'ورودی صوتی (میکروفون)',
                  icon: Icon(
                    _isListening ? Icons.mic : Icons.mic_none,
                    color: _isListening ? Colors.redAccent : null,
                  ),
                  onPressed: _toggleVoiceInput,
                ),
                IconButton.filled(
                  onPressed: _handleSend,
                  icon: Icon(
                    _mode == GenerationMode.imageGen
                        ? Icons.auto_awesome
                        : _mode == GenerationMode.videoGen
                            ? Icons.movie_creation
                            : _mode == GenerationMode.voiceGen
                                ? Icons.graphic_eq
                                : Icons.send,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isSpeaking;
  final VoidCallback onSpeakToggle;
  final VoidCallback? onEditUser;
  final VoidCallback? onRegenerate;
  final void Function(String htmlDoc) onRenderWeb;
  final VoidCallback onCopy;

  const _MessageBubble({
    required this.message,
    required this.isSpeaking,
    required this.onSpeakToggle,
    this.onEditUser,
    this.onRegenerate,
    required this.onRenderWeb,
    required this.onCopy,
  });

  String? _buildRichPreviewHtml(String text) {
    final htmlRegex = RegExp(r'```html\s*([\s\S]*?)```', caseSensitive: false);
    final htmlMatch = htmlRegex.firstMatch(text);
    if (htmlMatch != null) return htmlMatch.group(1);
    if (text.contains('<!DOCTYPE html>') || text.contains('<html')) {
      return text;
    }

    final mermaidRegex =
        RegExp(r'```mermaid\s*([\s\S]*?)```', caseSensitive: false);
    final mermaidMatch = mermaidRegex.firstMatch(text);
    if (mermaidMatch != null) {
      final diagram = mermaidMatch.group(1) ?? '';
      return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <script src="https://cdn.jsdelivr.net/npm/mermaid/dist/mermaid.min.js"></script>
</head>
<body style="background:#121212;color:#fff;padding:16px;">
  <div class="mermaid">$diagram</div>
  <script>mermaid.initialize({startOnLoad:true, theme:'dark'});</script>
</body>
</html>''';
    }

    if (text.contains(r'$$') || text.contains(r'\[')) {
      final escaped = const HtmlEscape().convert(text);
      return '''
<!DOCTYPE html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
  <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
  <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
    onload="renderMathInElement(document.body);"></script>
</head>
<body style="background:#121212;color:#fff;font-family:sans-serif;padding:16px;line-height:1.6;">
  <pre style="white-space:pre-wrap;font-family:inherit;">$escaped</pre>
</body>
</html>''';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final previewHtml = !isUser ? _buildRichPreviewHtml(message.content) : null;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onCopy,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.87,
          ),
          decoration: BoxDecoration(
            color: isUser
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser && message.modelLabel != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    message.modelLabel!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.cyanAccent,
                    ),
                  ),
                ),

              if (message.attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: message.attachments.map((att) {
                      if (att.type == AttachmentType.image &&
                          File(att.path).existsSync()) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(File(att.path),
                              width: 140, height: 140, fit: BoxFit.cover),
                        );
                      }
                      return Chip(
                        avatar: Icon(att.type == AttachmentType.video
                            ? Icons.videocam
                            : att.type == AttachmentType.audio
                                ? Icons.audiotrack
                                : Icons.picture_as_pdf),
                        label: Text(att.name, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                  ),
                ),

              if (message.content.isNotEmpty)
                MarkdownBody(
                  data: message.content,
                  selectable: true,
                ),

              // User Message Edit Action
              if (isUser && onEditUser != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: InkWell(
                    onTap: onEditUser,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.edit, size: 14, color: Colors.white70),
                        SizedBox(width: 4),
                        Text('ویرایش',
                            style:
                                TextStyle(fontSize: 11, color: Colors.white70)),
                      ],
                    ),
                  ),
                ),

              // Assistant Action Bar (TTS + Regenerate + Copy + Graphic Render)
              if (!isUser && message.content.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      IconButton.outlined(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'خواندن صوتی (TTS)',
                        icon: Icon(
                          isSpeaking ? Icons.stop : Icons.volume_up,
                          size: 16,
                        ),
                        onPressed: onSpeakToggle,
                      ),
                      if (onRegenerate != null)
                        IconButton.outlined(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'تولید مجدد پاسخ (Regenerate)',
                          icon: const Icon(Icons.refresh, size: 16),
                          onPressed: onRegenerate,
                        ),
                      IconButton.outlined(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'کپی متن',
                        icon: const Icon(Icons.copy, size: 16),
                        onPressed: onCopy,
                      ),
                      if (previewHtml != null)
                        FilledButton.tonalIcon(
                          onPressed: () => onRenderWeb(previewHtml),
                          icon: const Icon(Icons.auto_graph, size: 18),
                          label: const Text('نمایش گرافیکی / اجرا'),
                        ),
                    ],
                  ),
                ),

              // Generated Image Output
              if (message.generatedImagePath != null &&
                  File(message.generatedImagePath!).existsSync()) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(File(message.generatedImagePath!)),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: () {
                    Share.shareXFiles([XFile(message.generatedImagePath!)]);
                  },
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('ذخیره / اشتراک‌گذاری تصویر'),
                ),
              ],

              // Generated Video Output
              if (message.generatedVideoPath != null &&
                  File(message.generatedVideoPath!).existsSync()) ...[
                const SizedBox(height: 8),
                _InlineMediaPlayer(
                    mediaPath: message.generatedVideoPath!, isAudioOnly: false),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: () {
                    Share.shareXFiles([XFile(message.generatedVideoPath!)]);
                  },
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('ذخیره / اشتراک‌گذاری ویدیو'),
                ),
              ],

              // Generated Studio Audio Output (MP3)
              if (message.generatedAudioPath != null &&
                  File(message.generatedAudioPath!).existsSync()) ...[
                const SizedBox(height: 8),
                _InlineMediaPlayer(
                    mediaPath: message.generatedAudioPath!, isAudioOnly: true),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: () {
                    Share.shareXFiles([XFile(message.generatedAudioPath!)]);
                  },
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('دانلود / اشتراک‌گذاری فایل MP3'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineMediaPlayer extends StatefulWidget {
  final String mediaPath;
  final bool isAudioOnly;
  const _InlineMediaPlayer(
      {required this.mediaPath, required this.isAudioOnly});

  @override
  State<_InlineMediaPlayer> createState() => _InlineMediaPlayerState();
}

class _InlineMediaPlayerState extends State<_InlineMediaPlayer> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.mediaPath))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _initialized = true);
        }
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const SizedBox(
        height: 64,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (widget.isAudioOnly) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            IconButton(
              icon: Icon(
                _controller.value.isPlaying
                    ? Icons.pause_circle
                    : Icons.play_circle,
                size: 36,
                color: Colors.cyanAccent,
              ),
              onPressed: () {
                setState(() {
                  _controller.value.isPlaying
                      ? _controller.pause()
                      : _controller.play();
                });
              },
            ),
            const Expanded(
              child: Text('فایل صوتی استودیویی (MP3)',
                  style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: VideoPlayer(_controller),
        ),
        IconButton(
          icon: Icon(
            _controller.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
            size: 36,
          ),
          onPressed: () {
            setState(() {
              _controller.value.isPlaying
                  ? _controller.pause()
                  : _controller.play();
            });
          },
        ),
      ],
    );
  }
}
