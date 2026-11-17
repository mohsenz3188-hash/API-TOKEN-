import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'models.dart';

class AIService {
  static ProxySettings proxySettings = ProxySettings();
  static String globalMemory = '';
  static List<KnowledgeDoc> knowledgeBase = [];
  static List<CustomWebhookTool> webhookTools = [];
  static bool ragEnabled = true;

  static http.Client _createClient() {
    final ioClient = HttpClient();
    ioClient.connectionTimeout = const Duration(seconds: 30);

    if (proxySettings.enabled && proxySettings.host.trim().isNotEmpty) {
      final host = proxySettings.host.trim();
      final port = proxySettings.port;
      if (proxySettings.type == 'SOCKS5') {
        ioClient.findProxy = (uri) => 'SOCKS5 $host:$port; DIRECT';
      } else {
        ioClient.findProxy = (uri) => 'PROXY $host:$port; DIRECT';
      }
    }
    return IOClient(ioClient);
  }

  /// Auto-fetches available models from /models endpoint
  static Future<List<String>> fetchAvailableModels({
    required String provider,
    required String baseUrl,
    required String apiKey,
  }) async {
    final client = _createClient();
    final cleanUrl = baseUrl.trim().replaceAll(RegExp(r'/$'), '');
    try {
      if (provider == 'gemini') {
        final res = await client.get(
          Uri.parse('$cleanUrl/v1beta/models?key=$apiKey'),
        );
        if (res.statusCode != 200) {
          throw Exception('خطا در دریافت لیست مدل‌ها: ${res.body}');
        }
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final models = (data['models'] as List? ?? [])
            .map((m) => (m['name'] as String).replaceFirst('models/', ''))
            .toList();
        return models;
      } else {
        final res = await client.get(
          Uri.parse('$cleanUrl/models'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'x-api-key': apiKey,
            'anthropic-version': '2023-06-01',
          },
        );
        if (res.statusCode != 200) {
          throw Exception('خطا در دریافت لیست مدل‌ها: ${res.body}');
        }
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        final list = (data['data'] as List? ?? [])
            .map((m) => m['id'].toString())
            .toList();
        list.sort();
        return list;
      }
    } finally {
      client.close();
    }
  }

  /// Retrieves top relevant chunks from Local Knowledge Base (RAG)
  static String _retrieveRagContext(String userQuery) {
    if (!ragEnabled || knowledgeBase.isEmpty || userQuery.trim().isEmpty) {
      return '';
    }

    final queryWords = userQuery
        .toLowerCase()
        .split(RegExp(r'[\s\p{P}]+', unicode: true))
        .where((w) => w.length > 2)
        .toSet();
    if (queryWords.isEmpty) return '';

    final List<Map<String, dynamic>> scoredChunks = [];

    for (final doc in knowledgeBase) {
      final text = doc.content;
      const chunkSize = 900;
      const overlap = 150;
      for (int start = 0; start < text.length; start += (chunkSize - overlap)) {
        final end = min(start + chunkSize, text.length);
        final chunk = text.substring(start, end);
        final chunkLower = chunk.toLowerCase();
        int score = 0;
        for (final w in queryWords) {
          if (chunkLower.contains(w)) score++;
        }
        if (score > 0) {
          scoredChunks.add({
            'title': doc.title,
            'chunk': chunk,
            'score': score,
          });
        }
      }
    }

    scoredChunks.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
    final top = scoredChunks.take(3).toList();
    if (top.isEmpty) return '';

    final buffer = StringBuffer('

[منابع مرتبط از پایگاه دانش محلی]:
');
    for (final item in top) {
      buffer.writeln('--- منبع: ${item['title']} ---
${item['chunk']}
');
    }
    return buffer.toString();
  }

  static String _buildEffectiveSystemPrompt(AIProfile profile) {
    final parts = <String>[];
    if (globalMemory.trim().isNotEmpty) {
      parts.add('[حافظه بلندمدت کاربر]:
${globalMemory.trim()}');
    }
    if (profile.systemPrompt.trim().isNotEmpty) {
      parts.add(profile.systemPrompt.trim());
    }
    return parts.join('

');
  }

  /// Executes a user-defined HTTP Webhook Tool
  static Future<String> _executeWebhookTool(
    CustomWebhookTool tool,
    String queryArg,
  ) async {
    final client = _createClient();
    try {
      final encodedArg = Uri.encodeComponent(queryArg);
      final targetUrl = tool.url.replaceAll('{{query}}', encodedArg);
      if (tool.method.toUpperCase() == 'GET') {
        final res = await client.get(Uri.parse(targetUrl));
        return 'Status ${res.statusCode}: ${utf8.decode(res.bodyBytes)}';
      } else {
        final payload = tool.bodyTemplate.replaceAll('{{query}}', queryArg);
        final res = await client.post(
          Uri.parse(targetUrl),
          headers: {'Content-Type': 'application/json'},
          body: payload,
        );
        return 'Status ${res.statusCode}: ${utf8.decode(res.bodyBytes)}';
      }
    } catch (e) {
      return 'Webhook Error: $e';
    } finally {
      client.close();
    }
  }

  /// Streams chat with automatic API Key Rotation on 429/quota errors + RAG + Webhook Tools
  static Stream<String> streamChat({
    required AIProfile profile,
    required List<ChatMessage> history,
  }) async* {
    final keys = profile.apiKeys.where((k) => k.trim().isNotEmpty).toList();
    if (keys.isEmpty) {
      throw Exception('هیچ API Key معتبری در این پروفایل ثبت نشده است.');
    }

    Exception? lastError;
    for (int kIdx = 0; kIdx < keys.length; kIdx++) {
      final currentKey = keys[kIdx].trim();
      try {
        if (profile.provider == 'gemini') {
          yield* _streamGeminiChat(profile, currentKey, history);
        } else if (profile.provider == 'claude') {
          yield* _streamClaudeChat(profile, currentKey, history);
        } else {
          yield* _streamOpenAIChat(profile, currentKey, history);
        }
        return; // Completed successfully
      } catch (e) {
        lastError = Exception(e.toString());
        final errStr = e.toString().toLowerCase();
        final isQuotaOrRate = errStr.contains('429') ||
            errStr.contains('quota') ||
            errStr.contains('rate') ||
            errStr.contains('limit');
        if (isQuotaOrRate && kIdx < keys.length - 1) {
          yield '
*[سهمیه کلید ${kIdx + 1} تمام شد؛ چرخش خودکار به کلید ${kIdx + 2}...]*

';
          continue;
        }
        rethrow;
      }
    }
    if (lastError != null) throw lastError;
  }

  static Future<String> transcribeWithWhisper({
    required AIProfile profile,
    required String apiKey,
    required File audioFile,
  }) async {
    final client = _createClient();
    try {
      final uri = Uri.parse('${profile.baseUrl}/audio/transcriptions');
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..fields['model'] = 'whisper-1'
        ..files.add(await http.MultipartFile.fromPath('file', audioFile.path));

      final streamedRes = await client.send(req);
      final body = await streamedRes.stream.bytesToString();
      if (streamedRes.statusCode != 200) {
        throw Exception('خطای Whisper: $body');
      }
      final data = jsonDecode(body);
      return data['text'] ?? '';
    } finally {
      client.close();
    }
  }

  static Future<String> _uploadToGeminiFiles(
    AIProfile profile,
    String apiKey,
    File file,
    String mimeType,
  ) async {
    final client = _createClient();
    try {
      final bytes = await file.readAsBytes();
      final startUrl = Uri.parse(
        '${profile.baseUrl}/upload/v1beta/files?key=$apiKey',
      );

      final startReq = http.Request('POST', startUrl)
        ..headers.addAll({
          'X-Goog-Upload-Protocol': 'resumable',
          'X-Goog-Upload-Command': 'start',
          'X-Goog-Upload-Header-Content-Length': bytes.length.toString(),
          'X-Goog-Upload-Header-Content-Type': mimeType,
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({
          'file': {'display_name': file.uri.pathSegments.last}
        });

      final startStream = await client.send(startReq);
      final uploadUrl = startStream.headers['x-goog-upload-url'];
      if (uploadUrl == null) {
        throw Exception('خطا در دریافت لینک آپلود فایل از Gemini');
      }

      final uploadRes = await client.post(
        Uri.parse(uploadUrl),
        headers: {
          'Content-Length': bytes.length.toString(),
          'X-Goog-Upload-Offset': '0',
          'X-Goog-Upload-Command': 'upload, finalize',
        },
        body: bytes,
      );

      if (uploadRes.statusCode != 200) {
        throw Exception('خطا در آپلود فایل: ${uploadRes.body}');
      }

      final fileInfo = jsonDecode(utf8.decode(uploadRes.bodyBytes))['file'];
      final fileName = fileInfo['name'];
      final fileUri = fileInfo['uri'];

      for (int i = 0; i < 30; i++) {
        final checkRes = await client.get(
          Uri.parse('${profile.baseUrl}/v1beta/$fileName?key=$apiKey'),
        );
        if (checkRes.statusCode == 200) {
          final state = jsonDecode(checkRes.body)['state'];
          if (state == 'ACTIVE') return fileUri;
          if (state == 'FAILED') {
            throw Exception('پردازش رسانه توسط سرور Gemini با خطا مواجه شد.');
          }
        }
        await Future.delayed(const Duration(seconds: 2));
      }
      return fileUri;
    } finally {
      client.close();
    }
  }

  static Stream<String> _streamGeminiChat(
    AIProfile profile,
    String apiKey,
    List<ChatMessage> history,
  ) async* {
    final List<Map<String, dynamic>> contents = [];

    for (int idx = 0; idx < history.length; idx++) {
      final m = history[idx];
      if (m.role == 'assistant' && m.content.isEmpty) continue;
      final List<Map<String, dynamic>> parts = [];
      String combinedText = m.content;

      // Inject RAG context on the latest user message
      if (idx == history.length - 1 && m.role == 'user') {
        combinedText += _retrieveRagContext(m.content);
      }

      for (final att in m.attachments) {
        final f = File(att.path);
        if (!await f.exists()) continue;

        if (att.type == AttachmentType.image ||
            att.type == AttachmentType.audio) {
          final b64 = base64Encode(await f.readAsBytes());
          parts.add({
            'inlineData': {
              'mimeType': att.mimeType,
              'data': b64,
            }
          });
        } else if (att.type == AttachmentType.video) {
          final size = await f.length();
          if (size < 15 * 1024 * 1024) {
            final b64 = base64Encode(await f.readAsBytes());
            parts.add({
              'inlineData': {
                'mimeType': att.mimeType,
                'data': b64,
              }
            });
          } else {
            final uri =
                await _uploadToGeminiFiles(profile, apiKey, f, att.mimeType);
            parts.add({
              'fileData': {
                'mimeType': att.mimeType,
                'fileUri': uri,
              }
            });
          }
        } else if (att.type == AttachmentType.document &&
            att.textContent != null) {
          combinedText += '

--- File: ${att.name} ---
${att.textContent}';
        }
      }

      if (combinedText.isNotEmpty) {
        parts.add({'text': combinedText});
      }

      if (parts.isNotEmpty) {
        contents.add({
          'role': m.role == 'user' ? 'user' : 'model',
          'parts': parts,
        });
      }
    }

    final activeTools = webhookTools.where((t) => t.enabled).toList();
    final List<Map<String, dynamic>> toolsPayload = [];

    if (profile.enableWebSearch) {
      toolsPayload.add({'google_search': {}});
    }

    if (activeTools.isNotEmpty) {
      toolsPayload.add({
        'functionDeclarations': activeTools
            .map((t) => {
                  'name': t.name,
                  'description': t.description,
                  'parameters': {
                    'type': 'OBJECT',
                    'properties': {
                      'query': {
                        'type': 'STRING',
                        'description': 'Input query or payload for the webhook'
                      }
                    },
                    'required': ['query']
                  }
                })
            .toList(),
      });
    }

    final sysPrompt = _buildEffectiveSystemPrompt(profile);
    final client = _createClient();

    try {
      // If custom webhook tools exist, check for functionCall first
      if (activeTools.isNotEmpty) {
        final nonStreamUrl = Uri.parse(
          '${profile.baseUrl}/v1beta/models/${profile.chatModel}:generateContent?key=$apiKey',
        );
        final initPayload = <String, dynamic>{
          'contents': contents,
          'tools': toolsPayload,
          'generationConfig': {'temperature': profile.temperature},
        };
        if (sysPrompt.isNotEmpty) {
          initPayload['systemInstruction'] = {
            'parts': [
              {'text': sysPrompt}
            ]
          };
        }
        final checkRes = await client.post(
          nonStreamUrl,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(initPayload),
        );
        if (checkRes.statusCode != 200) {
          throw Exception(utf8.decode(checkRes.bodyBytes));
        }
        final checkData = jsonDecode(utf8.decode(checkRes.bodyBytes));
        final candParts =
            checkData['candidates']?[0]?['content']?['parts'] as List? ?? [];
        bool calledTool = false;
        for (final p in candParts) {
          if (p['functionCall'] != null) {
            calledTool = true;
            final fnName = p['functionCall']['name'];
            final fnArgs = p['functionCall']['args'] ?? {};
            final queryArg = (fnArgs['query'] ?? '').toString();
            final matchedTool = activeTools.firstWhere(
              (t) => t.name == fnName,
              orElse: () => activeTools.first,
            );
            yield '🔌 *در حال اجرای ابزار Webhook: $fnName...*

';
            final toolResult = await _executeWebhookTool(matchedTool, queryArg);
            contents.add({
              'role': 'model',
              'parts': [p]
            });
            contents.add({
              'role': 'user',
              'parts': [
                {
                  'functionResponse': {
                    'name': fnName,
                    'response': {'result': toolResult}
                  }
                }
              ]
            });
          }
        }
        if (!calledTool) {
          for (final p in candParts) {
            if (p['text'] != null) yield p['text'];
          }
          return;
        }
      }

      // Stream final response
      final url = Uri.parse(
        '${profile.baseUrl}/v1beta/models/${profile.chatModel}:streamGenerateContent?alt=sse&key=$apiKey',
      );
      final Map<String, dynamic> payload = {
        'contents': contents,
        'generationConfig': {'temperature': profile.temperature},
      };
      if (sysPrompt.isNotEmpty) {
        payload['systemInstruction'] = {
          'parts': [
            {'text': sysPrompt}
          ]
        };
      }
      if (toolsPayload.isNotEmpty) {
        payload['tools'] = toolsPayload;
      }

      final req = http.Request('POST', url)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(payload);

      final res = await client.send(req);
      if (res.statusCode != 200) {
        final errBody = await res.stream.bytesToString();
        throw Exception('HTTP ${res.statusCode}: $errBody');
      }

      final lines =
          res.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (line.startsWith('data: ')) {
          final jsonPart = line.substring(6).trim();
          if (jsonPart.isEmpty || jsonPart == '[DONE]') continue;
          try {
            final data = jsonDecode(jsonPart);
            final parts =
                data['candidates']?[0]?['content']?['parts'] as List<dynamic>?;
            if (parts != null) {
              for (final p in parts) {
                if (p['text'] != null) {
                  yield p['text'] as String;
                }
              }
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }

  static Stream<String> _streamOpenAIChat(
    AIProfile profile,
    String apiKey,
    List<ChatMessage> history,
  ) async* {
    final url = Uri.parse('${profile.baseUrl}/chat/completions');
    final List<Map<String, dynamic>> msgs = [];

    final sysPrompt = _buildEffectiveSystemPrompt(profile);
    if (sysPrompt.isNotEmpty) {
      msgs.add({'role': 'system', 'content': sysPrompt});
    }

    for (int idx = 0; idx < history.length; idx++) {
      final m = history[idx];
      if (m.role == 'assistant' && m.content.isEmpty) continue;
      String combinedText = m.content;

      if (idx == history.length - 1 && m.role == 'user') {
        combinedText += _retrieveRagContext(m.content);
      }

      final List<Map<String, dynamic>> contentParts = [];
      bool hasMedia = false;

      for (final att in m.attachments) {
        final f = File(att.path);
        if (!await f.exists()) continue;

        if (att.type == AttachmentType.image) {
          hasMedia = true;
          final b64 = base64Encode(await f.readAsBytes());
          contentParts.add({
            'type': 'image_url',
            'image_url': {'url': 'data:${att.mimeType};base64,$b64'}
          });
        } else if (att.type == AttachmentType.audio) {
          final transcript = await transcribeWithWhisper(
              profile: profile, apiKey: apiKey, audioFile: f);
          combinedText += '
[متن فایل صوتی ${att.name}]: $transcript';
        } else if (att.type == AttachmentType.document &&
            att.textContent != null) {
          combinedText += '

--- File: ${att.name} ---
${att.textContent}';
        }
      }

      if (hasMedia) {
        if (combinedText.isNotEmpty) {
          contentParts.insert(0, {'type': 'text', 'text': combinedText});
        }
        msgs.add({'role': m.role, 'content': contentParts});
      } else {
        msgs.add({'role': m.role, 'content': combinedText});
      }
    }

    final activeTools = webhookTools.where((t) => t.enabled).toList();
    final client = _createClient();

    try {
      if (activeTools.isNotEmpty) {
        final openAiTools = activeTools
            .map((t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': {
                      'type': 'object',
                      'properties': {
                        'query': {'type': 'string'}
                      },
                      'required': ['query']
                    }
                  }
                })
            .toList();

        final initRes = await client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': profile.chatModel,
            'temperature': profile.temperature,
            'messages': msgs,
            'tools': openAiTools,
          }),
        );
        if (initRes.statusCode != 200) {
          throw Exception('HTTP ${initRes.statusCode}: ${initRes.body}');
        }
        final initData = jsonDecode(utf8.decode(initRes.bodyBytes));
        final messageObj = initData['choices'][0]['message'];
        final toolCalls = messageObj['tool_calls'] as List?;
        if (toolCalls != null && toolCalls.isNotEmpty) {
          msgs.add(messageObj);
          for (final tc in toolCalls) {
            final fnName = tc['function']['name'];
            final argsMap = jsonDecode(tc['function']['arguments'] ?? '{}');
            final queryArg = (argsMap['query'] ?? '').toString();
            final matchedTool = activeTools.firstWhere(
              (t) => t.name == fnName,
              orElse: () => activeTools.first,
            );
            yield '🔌 *اجرای ابزار Webhook: $fnName...*

';
            final toolOut = await _executeWebhookTool(matchedTool, queryArg);
            msgs.add({
              'role': 'tool',
              'tool_call_id': tc['id'],
              'content': toolOut,
            });
          }
        } else {
          yield (messageObj['content'] ?? '').toString();
          return;
        }
      }

      final req = http.Request('POST', url)
        ..headers.addAll({
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        })
        ..body = jsonEncode({
          'model': profile.chatModel,
          'temperature': profile.temperature,
          'stream': true,
          'messages': msgs,
        });

      final res = await client.send(req);
      if (res.statusCode != 200) {
        final errBody = await res.stream.bytesToString();
        throw Exception('HTTP ${res.statusCode}: $errBody');
      }

      final lines =
          res.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (line.startsWith('data: ')) {
          final jsonPart = line.substring(6).trim();
          if (jsonPart.isEmpty || jsonPart == '[DONE]') continue;
          try {
            final data = jsonDecode(jsonPart);
            final delta = data['choices']?[0]?['delta']?['content'];
            if (delta != null) {
              yield delta as String;
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }

  static Stream<String> _streamClaudeChat(
    AIProfile profile,
    String apiKey,
    List<ChatMessage> history,
  ) async* {
    final url = Uri.parse('${profile.baseUrl}/v1/messages');
    final List<Map<String, dynamic>> msgs = [];

    for (int idx = 0; idx < history.length; idx++) {
      final m = history[idx];
      if (m.role == 'assistant' && m.content.isEmpty) continue;
      final List<Map<String, dynamic>> contentBlocks = [];
      String combinedText = m.content;

      if (idx == history.length - 1 && m.role == 'user') {
        combinedText += _retrieveRagContext(m.content);
      }

      for (final att in m.attachments) {
        final f = File(att.path);
        if (!await f.exists()) continue;

        if (att.type == AttachmentType.image) {
          final b64 = base64Encode(await f.readAsBytes());
          contentBlocks.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': att.mimeType,
              'data': b64,
            }
          });
        } else if (att.type == AttachmentType.document &&
            att.textContent != null) {
          combinedText += '

--- File: ${att.name} ---
${att.textContent}';
        }
      }

      if (combinedText.isNotEmpty) {
        contentBlocks.add({'type': 'text', 'text': combinedText});
      }

      msgs.add({'role': m.role, 'content': contentBlocks});
    }

    final Map<String, dynamic> body = {
      'model': profile.chatModel,
      'max_tokens': 4096,
      'temperature': profile.temperature,
      'stream': true,
      'messages': msgs,
    };

    final sysPrompt = _buildEffectiveSystemPrompt(profile);
    if (sysPrompt.isNotEmpty) {
      body['system'] = sysPrompt;
    }

    final client = _createClient();
    try {
      final req = http.Request('POST', url)
        ..headers.addAll({
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        })
        ..body = jsonEncode(body);

      final res = await client.send(req);
      if (res.statusCode != 200) {
        final errBody = await res.stream.bytesToString();
        throw Exception('HTTP ${res.statusCode}: $errBody');
      }

      final lines =
          res.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (line.startsWith('data: ')) {
          final jsonPart = line.substring(6).trim();
          if (jsonPart.isEmpty) continue;
          try {
            final data = jsonDecode(jsonPart);
            if (data['type'] == 'content_block_delta') {
              final text = data['delta']?['text'];
              if (text != null) yield text as String;
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }

  /// Generates or edits an image (supports Image-to-Image when referenceImage is passed)
  static Future<String> generateOrEditImage({
    required AIProfile profile,
    required String prompt,
    File? referenceImage,
  }) async {
    final client = _createClient();
    final apiKey = profile.primaryKey;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outPath =
          '${dir.path}/img_${DateTime.now().millisecondsSinceEpoch}.png';

      if (profile.provider == 'gemini') {
        final model = referenceImage != null
            ? (profile.chatModel.contains('image')
                ? profile.chatModel
                : 'gemini-2.0-flash-exp-image-generation')
            : (profile.imageModel.isNotEmpty
                ? profile.imageModel
                : 'imagen-3.0-generate-002');

        if (model.startsWith('imagen') && referenceImage == null) {
          final url = Uri.parse(
            '${profile.baseUrl}/v1beta/models/$model:predict?key=$apiKey',
          );
          final res = await client.post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'instances': [
                {'prompt': prompt}
              ],
              'parameters': {'sampleCount': 1}
            }),
          );
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          if (res.statusCode != 200) {
            throw Exception(data['error']?['message'] ?? res.body);
          }
          final b64 = data['predictions'][0]['bytesBase64Encoded'];
          await File(outPath).writeAsBytes(base64Decode(b64));
          return outPath;
        } else {
          final url = Uri.parse(
            '${profile.baseUrl}/v1beta/models/$model:generateContent?key=$apiKey',
          );
          final List<Map<String, dynamic>> parts = [
            {'text': prompt}
          ];
          if (referenceImage != null && await referenceImage.exists()) {
            parts.add({
              'inlineData': {
                'mimeType': 'image/jpeg',
                'data': base64Encode(await referenceImage.readAsBytes()),
              }
            });
          }
          final res = await client.post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {'parts': parts}
              ],
              'generationConfig': {
                'responseModalities': ['TEXT', 'IMAGE']
              }
            }),
          );
          final data = jsonDecode(utf8.decode(res.bodyBytes));
          if (res.statusCode != 200) {
            throw Exception(data['error']?['message'] ?? res.body);
          }
          final resParts = data['candidates'][0]['content']['parts'] as List;
          for (final p in resParts) {
            if (p['inlineData'] != null) {
              final b64 = p['inlineData']['data'];
              await File(outPath).writeAsBytes(base64Decode(b64));
              return outPath;
            }
          }
          throw Exception('تصویری در پاسخ مدل یافت نشد.');
        }
      } else {
        if (referenceImage != null && await referenceImage.exists()) {
          // OpenAI Image-to-Image (/images/edits)
          final url = Uri.parse('${profile.baseUrl}/images/edits');
          final req = http.MultipartRequest('POST', url)
            ..headers['Authorization'] = 'Bearer $apiKey'
            ..fields['prompt'] = prompt
            ..fields['model'] =
                profile.imageModel.isNotEmpty ? profile.imageModel : 'dall-e-2'
            ..fields['response_format'] = 'b64_json'
            ..files.add(
                await http.MultipartFile.fromPath('image', referenceImage.path));
          final streamed = await client.send(req);
          final body = await streamed.stream.bytesToString();
          if (streamed.statusCode != 200) {
            throw Exception(body);
          }
          final data = jsonDecode(body);
          final b64 = data['data'][0]['b64_json'];
          await File(outPath).writeAsBytes(base64Decode(b64));
          return outPath;
        }

        final model =
            profile.imageModel.isNotEmpty ? profile.imageModel : 'dall-e-3';
        final url = Uri.parse('${profile.baseUrl}/images/generations');

        final res = await client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': model,
            'prompt': prompt,
            'n': 1,
            'size': '1024x1024',
            'response_format': 'b64_json',
          }),
        );

        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (res.statusCode != 200) {
          throw Exception(data['error']?['message'] ?? res.body);
        }

        final item = data['data'][0];
        if (item['b64_json'] != null) {
          await File(outPath).writeAsBytes(base64Decode(item['b64_json']));
          return outPath;
        } else if (item['url'] != null) {
          final imgRes = await client.get(Uri.parse(item['url']));
          await File(outPath).writeAsBytes(imgRes.bodyBytes);
          return outPath;
        }
        throw Exception('خروجی تصویر نامعتبر است.');
      }
    } finally {
      client.close();
    }
  }

  /// Generates studio AI Speech MP3 via OpenAI /audio/speech or ElevenLabs
  static Future<String> generateStudioSpeech({
    required AIProfile profile,
    required String text,
  }) async {
    final client = _createClient();
    final apiKey = profile.primaryKey;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outPath =
          '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.mp3';

      if (profile.provider == 'elevenlabs') {
        final voiceId = profile.voiceId.trim().isNotEmpty
            ? profile.voiceId.trim()
            : '21m00Tcm4TlvDq8ikWAM';
        final url = Uri.parse('${profile.baseUrl}/v1/text-to-speech/$voiceId');
        final res = await client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'xi-api-key': apiKey,
          },
          body: jsonEncode({
            'text': text,
            'model_id': profile.voiceModel.isNotEmpty
                ? profile.voiceModel
                : 'eleven_multilingual_v2',
          }),
        );
        if (res.statusCode != 200) {
          throw Exception('خطای ElevenLabs: ${utf8.decode(res.bodyBytes)}');
        }
        await File(outPath).writeAsBytes(res.bodyBytes);
        return outPath;
      } else {
        final url = Uri.parse('${profile.baseUrl}/audio/speech');
        final res = await client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model':
                profile.voiceModel.isNotEmpty ? profile.voiceModel : 'tts-1',
            'input': text,
            'voice':
                profile.voiceId.isNotEmpty ? profile.voiceId : 'alloy',
          }),
        );
        if (res.statusCode != 200) {
          throw Exception('خطای تولید صوت: ${utf8.decode(res.bodyBytes)}');
        }
        await File(outPath).writeAsBytes(res.bodyBytes);
        return outPath;
      }
    } finally {
      client.close();
    }
  }

  static Future<String> generateVideo({
    required AIProfile profile,
    required String prompt,
  }) async {
    final client = _createClient();
    final apiKey = profile.primaryKey;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final outPath =
          '${dir.path}/vid_${DateTime.now().millisecondsSinceEpoch}.mp4';

      if (profile.provider == 'gemini') {
        final model = profile.videoModel.isNotEmpty
            ? profile.videoModel
            : 'veo-2.0-generate-001';
        final startUrl = Uri.parse(
          '${profile.baseUrl}/v1beta/models/$model:predictLongRunning?key=$apiKey',
        );

        final startRes = await client.post(
          startUrl,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'instances': [
              {'prompt': prompt}
            ],
            'parameters': {'aspectRatio': '16:9'}
          }),
        );

        final startData = jsonDecode(utf8.decode(startRes.bodyBytes));
        if (startRes.statusCode != 200) {
          throw Exception(startData['error']?['message'] ?? startRes.body);
        }

        final opName = startData['name'];
        if (opName == null) {
          throw Exception('شناسه عملیات تولید ویدیو دریافت نشد.');
        }

        for (int i = 0; i < 45; i++) {
          await Future.delayed(const Duration(seconds: 4));
          final pollRes = await client.get(
            Uri.parse('${profile.baseUrl}/v1beta/$opName?key=$apiKey'),
          );
          final pollData = jsonDecode(utf8.decode(pollRes.bodyBytes));
          if (pollData['done'] == true) {
            if (pollData['error'] != null) {
              throw Exception(pollData['error']['message']);
            }
            final samples = pollData['response']?['generateVideoResponse']
                ?['generatedSamples'] as List?;
            final videoUri = samples?[0]?['video']?['uri'];
            if (videoUri == null) {
              throw Exception('لینک دانلود ویدیو در پاسخ یافت نشد.');
            }
            final dlUrl = videoUri.contains('?')
                ? '$videoUri&key=$apiKey'
                : '$videoUri?key=$apiKey';
            final vidRes = await client.get(Uri.parse(dlUrl));
            await File(outPath).writeAsBytes(vidRes.bodyBytes);
            return outPath;
          }
        }
        throw Exception('زمان انتظار برای ساخت ویدیو به پایان رسید.');
      } else {
        final model =
            profile.videoModel.isNotEmpty ? profile.videoModel : 'sora-2';
        final url = Uri.parse('${profile.baseUrl}/videos/generations');

        final res = await client.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'model': model,
            'prompt': prompt,
          }),
        );

        final data = jsonDecode(utf8.decode(res.bodyBytes));
        if (res.statusCode != 200) {
          throw Exception(data['error']?['message'] ?? res.body);
        }

        final vidUrl = data['data']?[0]?['url'];
        if (vidUrl != null) {
          final vidRes = await client.get(Uri.parse(vidUrl));
          await File(outPath).writeAsBytes(vidRes.bodyBytes);
          return outPath;
        }
        throw Exception('سرویس‌دهنده انتخابی از ساخت ویدیو پشتیبانی نمی‌کند.');
      }
    } finally {
      client.close();
    }
  }
}
