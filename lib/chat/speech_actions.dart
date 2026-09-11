import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

typedef DictationResultCallback = void Function(String words, bool isFinal);
typedef SpeechErrorCallback = void Function(String message);

abstract interface class DictationEngine {
  Future<bool> start({
    required DictationResultCallback onResult,
    required VoidCallback onStopped,
    required SpeechErrorCallback onError,
  });

  Future<void> stop();

  Future<void> cancel();
}

final class NativeDictationEngine implements DictationEngine {
  NativeDictationEngine({SpeechToText? speech})
    : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  bool _initialized = false;
  int _session = 0;
  DictationResultCallback? _onResult;
  VoidCallback? _onStopped;
  SpeechErrorCallback? _onError;

  @override
  Future<bool> start({
    required DictationResultCallback onResult,
    required VoidCallback onStopped,
    required SpeechErrorCallback onError,
  }) async {
    final session = ++_session;
    _onResult = onResult;
    _onStopped = onStopped;
    _onError = onError;
    try {
      if (!_initialized) {
        _initialized = await _speech.initialize(
          onError: _handleError,
          onStatus: _handleStatus,
        );
      }
      if (!_initialized || session != _session) return false;
      await _speech.listen(
        onResult: (result) {
          if (session == _session) _handleResult(result);
        },
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      );
      return session == _session;
    } on Object catch (error) {
      _onError?.call(_messageFor(error));
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _speech.stop();
    } on Object catch (error) {
      _onError?.call(_messageFor(error));
    }
  }

  @override
  Future<void> cancel() async {
    _session++;
    try {
      await _speech.cancel();
    } on Object catch (error) {
      _onError?.call(_messageFor(error));
    }
  }

  void _handleResult(SpeechRecognitionResult result) {
    _onResult?.call(result.recognizedWords, result.finalResult);
  }

  void _handleStatus(String status) {
    if (status == SpeechToText.notListeningStatus ||
        status == SpeechToText.doneStatus) {
      _onStopped?.call();
    }
  }

  void _handleError(SpeechRecognitionError error) {
    _onError?.call(_messageFor(error.errorMsg));
  }

  String _messageFor(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('permission') || text.contains('denied')) {
      return 'Microphone and speech recognition access is required for dictation.';
    }
    if (text.contains('no_match') || text.contains('speech_timeout')) {
      return 'No speech was recognized. Try again.';
    }
    return 'Dictation is unavailable right now.';
  }
}

typedef SpeechStartedCallback = void Function();

abstract interface class AnswerSpeaker {
  Future<void> speak(
    String text, {
    required SpeechStartedCallback onStarted,
    required VoidCallback onComplete,
    required SpeechErrorCallback onError,
  });

  Future<void> stop();
}

final class NativeAnswerSpeaker implements AnswerSpeaker {
  NativeAnswerSpeaker({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  SpeechStartedCallback? _onStarted;
  VoidCallback? _onComplete;
  SpeechErrorCallback? _onError;

  @override
  Future<void> speak(
    String text, {
    required SpeechStartedCallback onStarted,
    required VoidCallback onComplete,
    required SpeechErrorCallback onError,
  }) async {
    _onStarted = onStarted;
    _onComplete = onComplete;
    _onError = onError;
    _tts.setStartHandler(_handleStarted);
    _tts.setCompletionHandler(_handleComplete);
    _tts.setCancelHandler(_handleComplete);
    _tts.setErrorHandler(_handleError);
    try {
      final result = await _tts.speak(text);
      if (result == 0) {
        throw StateError('Text to speech did not start.');
      }
    } on Object {
      _onError?.call('Read aloud is unavailable right now.');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } on Object {
      _onError?.call('Read aloud could not be stopped.');
    }
  }

  void _handleStarted() => _onStarted?.call();

  void _handleComplete() => _onComplete?.call();

  void _handleError(dynamic _) {
    _onError?.call('Read aloud is unavailable right now.');
  }
}
