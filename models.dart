import 'dart:convert';

enum GenerationMode {
  chat,
  arena,
  imageGen,
  videoGen,
  voiceGen,
}

enum AttachmentType {
  image,
  video,
  audio,
  document,
}

class ProxySettings {
  bool enabled;
  String type; // 'HTTP' or 'SOCKS5'
  String host;
  int port;

  ProxySettings({
    this.enabled = false,
    this.type = 'HTTP',
    this.host = '127.0.0.1',
    this.port = 10808,
  });

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'type': type,
        'host': host,
        'port': port,
      };

  factory ProxySettings.fromJson(Map<String, dynamic> json) => ProxySettings(
        enabled: json['enabled'] ?? false,
        type: json['type'] ?? 'HTTP',
        host: json['host'] ?? '127.0.0.1',
        port: json['port'] ?? 10808,
      );
}

class CustomWebhookTool {
  String id;
  String name; // e.g., send_telegram_alert
  String description;
  String method; // 'GET' or 'POST'
  String url; // supports {{query}}
  String bodyTemplate; // JSON string supporting {{query}}
  bool enabled;

  CustomWebhookTool({
    required this.id,
    required this.name,
    required this.description,
    this.method = 'POST',
    required this.url,
    this.bodyTemplate = '{"query": "{{query}}"}',
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'method': method,
        'url': url,
        'bodyTemplate': bodyTemplate,
        'enabled': enabled,
      };

  factory CustomWebhookTool.fromJson(Map<String, dynamic> json) =>
      CustomWebhookTool(
        id: json['id'],
        name: json['name'],
        description: json['description'] ?? '',
        method: json['method'] ?? 'POST',
        url: json['url'] ?? '',
        bodyTemplate: json['bodyTemplate'] ?? '{"query": "{{query}}"}',
        enabled: json['enabled'] ?? true,
      );
}

class KnowledgeDoc {
  String id;
  String title;
  String content;
  DateTime addedAt;

  KnowledgeDoc({
    required this.id,
    required this.title,
    required this.content,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'addedAt': addedAt.toIso8601String(),
      };

  factory KnowledgeDoc.fromJson(Map<String, dynamic> json) => KnowledgeDoc(
        id: json['id'],
        title: json['title'],
        content: json['content'] ?? '',
        addedAt: DateTime.tryParse(json['addedAt'] ?? '') ?? DateTime.now(),
      );
}

class PromptTemplate {
  String id;
  String title;
  String prompt;

  PromptTemplate({
    required this.id,
    required this.title,
    required this.prompt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'prompt': prompt,
      };

  factory PromptTemplate.fromJson(Map<String, dynamic> json) => PromptTemplate(
        id: json['id'],
        title: json['title'],
        prompt: json['prompt'],
      );
}

class MediaAttachment {
  final AttachmentType type;
  final String path;
  final String name;
  final String mimeType;
  final String? textContent;

  MediaAttachment({
    required this.type,
    required this.path,
    required this.name,
    required this.mimeType,
    this.textContent,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'path': path,
        'name': name,
        'mimeType': mimeType,
        'textContent': textContent,
      };

  factory MediaAttachment.fromJson(Map<String, dynamic> json) => MediaAttachment(
        type: AttachmentType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => AttachmentType.document,
        ),
        path: json['path'] ?? '',
        name: json['name'] ?? '',
        mimeType: json['mimeType'] ?? 'application/octet-stream',
        textContent: json['textContent'],
      );
}

class AIProfile {
  String id;
  String name;
  String provider; // 'gemini', 'openai_compatible', 'claude', 'elevenlabs'
  List<String> apiKeys; // Supports multiple keys for automatic rotation
  String baseUrl;
  String chatModel;
  String imageModel;
  String videoModel;
  String voiceModel;
  String voiceId;
  String systemPrompt;
  double temperature;
  bool enableWebSearch;

  AIProfile({
    required this.id,
    required this.name,
    required this.provider,
    required this.apiKeys,
    required this.baseUrl,
    required this.chatModel,
    this.imageModel = '',
    this.videoModel = '',
    this.voiceModel = 'tts-1',
    this.voiceId = 'alloy',
    this.systemPrompt = '',
    this.temperature = 0.7,
    this.enableWebSearch = false,
  });

  String get primaryKey => apiKeys.isNotEmpty ? apiKeys.first : '';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'provider': provider,
        'apiKeys': apiKeys,
        'baseUrl': baseUrl,
        'chatModel': chatModel,
        'imageModel': imageModel,
        'videoModel': videoModel,
        'voiceModel': voiceModel,
        'voiceId': voiceId,
        'systemPrompt': systemPrompt,
        'temperature': temperature,
        'enableWebSearch': enableWebSearch,
      };

  factory AIProfile.fromJson(Map<String, dynamic> json) {
    List<String> keys = [];
    if (json['apiKeys'] is List) {
      keys = List<String>.from(json['apiKeys']);
    } else if (json['apiKey'] != null) {
      keys = [json['apiKey'].toString()];
    }
    return AIProfile(
      id: json['id'],
      name: json['name'],
      provider: json['provider'],
      apiKeys: keys,
      baseUrl: json['baseUrl'],
      chatModel: json['chatModel'] ?? json['model'] ?? 'gpt-4o-mini',
      imageModel: json['imageModel'] ?? '',
      videoModel: json['videoModel'] ?? '',
      voiceModel: json['voiceModel'] ?? 'tts-1',
      voiceId: json['voiceId'] ?? 'alloy',
      systemPrompt: json['systemPrompt'] ?? '',
      temperature: (json['temperature'] ?? 0.7).toDouble(),
      enableWebSearch: json['enableWebSearch'] ?? false,
    );
  }
}

class ChatMessage {
  final String role; // 'user' or 'assistant'
  String content;
  final String? modelLabel;
  final List<MediaAttachment> attachments;
  final String? generatedImagePath;
  final String? generatedVideoPath;
  final String? generatedAudioPath;
  final DateTime timestamp;

  ChatMessage({
    required this.role,
    required this.content,
    this.modelLabel,
    this.attachments = const [],
    this.generatedImagePath,
    this.generatedVideoPath,
    this.generatedAudioPath,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  int get estimatedTokens => (content.length / 3.5).ceil();

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'modelLabel': modelLabel,
        'attachments': attachments.map((e) => e.toJson()).toList(),
        'generatedImagePath': generatedImagePath,
        'generatedVideoPath': generatedVideoPath,
        'generatedAudioPath': generatedAudioPath,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: json['role'],
        content: json['content'] ?? '',
        modelLabel: json['modelLabel'],
        attachments: (json['attachments'] as List<dynamic>? ?? [])
            .map((e) => MediaAttachment.fromJson(e))
            .toList(),
        generatedImagePath: json['generatedImagePath'],
        generatedVideoPath: json['generatedVideoPath'],
        generatedAudioPath: json['generatedAudioPath'],
        timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
      );
}

class ChatSession {
  String id;
  String title;
  List<ChatMessage> messages;
  DateTime updatedAt;

  ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  int get totalEstimatedTokens =>
      messages.fold(0, (sum, m) => sum + m.estimatedTokens);

  String toRawJson() => jsonEncode({
        'id': id,
        'title': title,
        'messages': messages.map((e) => e.toJson()).toList(),
        'updatedAt': updatedAt.toIso8601String(),
      });

  factory ChatSession.fromRawJson(String raw) {
    final json = jsonDecode(raw);
    return ChatSession(
      id: json['id'],
      title: json['title'] ?? 'گفتگوی جدید',
      messages: (json['messages'] as List<dynamic>? ?? [])
          .map((e) => ChatMessage.fromJson(e))
          .toList(),
      updatedAt: DateTime.tryParse(json['updatedAt'] ?? '') ?? DateTime.now(),
    );
  }
}
