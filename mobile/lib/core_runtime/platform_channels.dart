// Kotlin-backed platform services, usable from any Flutter engine (UI or the core engine):
//   "snapy/keystore"  Android Keystore (KeyCipher AES-GCM) — API keys and sync secrets
//   "snapy/runtime"   the core engine's link to Kotlin (events out; contacts, Nano, network in)
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../sync/sync_store.dart';
import 'brain.dart';
import 'commands.dart';
import 'runtime.dart';

const keystoreChannel = MethodChannel('snapy/keystore');

/// SecureKeyStore over the Android Keystore (values encrypted with KeyCipher in Kotlin,
/// stored in `files/snapy/keystore.json`). Used by lib/sync for the X25519 identity.
class KeystoreKeyStore implements SecureKeyStore {
  const KeystoreKeyStore();
  @override
  Future<String?> read(String key) => keystoreChannel.invokeMethod<String>('read', {'key': key});
  @override
  Future<void> write(String key, String value) => keystoreChannel.invokeMethod('write', {'key': key, 'value': value});
  @override
  Future<void> delete(String key) => keystoreChannel.invokeMethod('delete', {'key': key});
}

/// API keys in `files/snapy/secrets.json` (same format the Chaquopy brain wrote, so keys survive).
class KeystoreVault implements SecretVault {
  const KeystoreVault();
  @override
  Future<String> getKey(String name) async => (await keystoreChannel.invokeMethod<String>('apiKeyGet', {'name': name})) ?? '';
  @override
  Future<void> setKey(String name, String value) => keystoreChannel.invokeMethod('apiKeySet', {'name': name, 'value': value});
}

/// The core engine's channel to Kotlin.
class RuntimeChannel implements PlatformHooks, NanoBridge {
  static const channel = MethodChannel('snapy/runtime');
  final Map<int, StreamController<String>> _nano = {};
  int _nanoSeq = 0;

  @override
  SecretVault get vault => const KeystoreVault();

  @override
  NanoBridge get nano => this;

  @override
  Future<String?> findContacts(String name) => channel.invokeMethod<String>('contacts', {'name': name});

  @override
  Future<String?> httpGet(Uri url) => PhoneCommands.httpGet(url);

  @override
  Future<String> status() async => (await channel.invokeMethod<String>('nanoStatus')) ?? 'unavailable';

  /// Kotlin streams the answer back as nanoChunk / nanoDone calls with the request id.
  @override
  Stream<String> generate(String prompt) {
    final id = ++_nanoSeq;
    final c = StreamController<String>();
    _nano[id] = c;
    channel.invokeMethod('nanoGenerate', {'id': id, 'prompt': prompt}).catchError((Object e) {
      _nano.remove(id)?.addError(e);
      c.close();
      return null;
    });
    return c.stream;
  }

  /// Calls from Kotlin that are not runtime methods (Nano chunks).
  bool handleNano(MethodCall call) {
    final args = Map<String, dynamic>.from((call.arguments as Map?) ?? const {});
    final id = (args['id'] as num?)?.toInt();
    if (call.method == 'nanoChunk') {
      _nano[id]?.add('${args['text'] ?? ''}');
      return true;
    }
    if (call.method == 'nanoDone') {
      final c = _nano.remove(id);
      if (c != null) {
        if (args['error'] != null) c.addError(StateError('${args['error']}'));
        c.close();
      }
      return true;
    }
    return false;
  }

  Future<bool> onWifi() async => (await channel.invokeMethod<bool>('onWifi')) ?? false;
  Future<void> multicastLock(bool on) => channel.invokeMethod('multicastLock', {'on': on});

  /// Batched events to Kotlin (routes ops/speech/reminders, forwards all to the UIs).
  Future<void> sendEvents(List<Map<String, dynamic>> batch) => channel.invokeMethod('events', jsonEncode(batch));
}
