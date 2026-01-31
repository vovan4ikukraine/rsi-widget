import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../localization/app_localizations.dart';
import 'user_service.dart';
import 'yahoo_proto.dart';

/// Error types for grouping in admin dashboard
enum ErrorType {
  network, // SocketException, connection issues
  timeout, // TimeoutException
  server, // HTTP 500, 502, 503, etc.
  rateLimit, // HTTP 429, too many requests
  noData, // Empty data, symbol not found
  validation, // Invalid data format, validation errors
  unknown, // Other errors
}

/// Service for handling errors and logging them to server
class ErrorService {
  static String get _endpoint => AppConfig.apiBaseUrl;
  static const Duration _logTimeout = Duration(seconds: 5);

  /// Get user-friendly error message from exception
  static String getUserFriendlyError(
    dynamic error,
    AppLocalizations loc,
  ) {
    if (error is YahooException) {
      final message = error.message.toLowerCase();
      
      // Check for specific error types
      if (message.contains('timeout') || message.contains('timed out')) {
        return loc.t('error_timeout');
      }
      
      if (message.contains('500') ||
          message.contains('502') ||
          message.contains('503') ||
          message.contains('504') ||
          message.contains('server error') ||
          message.contains('server returned error')) {
        return loc.t('error_server_error');
      }
      
      if (message.contains('429') ||
          message.contains('too many requests') ||
          message.contains('rate limit')) {
        return loc.t('error_too_many_requests');
      }
      
      if (message.contains('no data') ||
          message.contains('empty') ||
          message.contains('not found')) {
        return loc.t('error_no_data');
      }
    }
    
    if (error is SocketException) {
      return loc.t('error_no_internet');
    }
    
    if (error is TimeoutException || error is http.ClientException) {
      return loc.t('error_timeout');
    }
    
    if (error is http.Response) {
      final statusCode = error.statusCode;
      if (statusCode >= 500) {
        return loc.t('error_server_error');
      }
      if (statusCode == 429) {
        return loc.t('error_too_many_requests');
      }
    }
    
    // Default to unknown error
    return loc.t('error_unknown');
  }

  /// Get error type for grouping
  static ErrorType getErrorType(dynamic error) {
    if (error is YahooException) {
      final message = error.message.toLowerCase();
      
      if (message.contains('timeout') || message.contains('timed out')) {
        return ErrorType.timeout;
      }
      
      if (message.contains('500') ||
          message.contains('502') ||
          message.contains('503') ||
          message.contains('504') ||
          message.contains('server error')) {
        return ErrorType.server;
      }
      
      if (message.contains('429') ||
          message.contains('too many requests') ||
          message.contains('rate limit')) {
        return ErrorType.rateLimit;
      }
      
      if (message.contains('no data') ||
          message.contains('empty') ||
          message.contains('not found')) {
        return ErrorType.noData;
      }
    }
    
    if (error is SocketException) {
      return ErrorType.network;
    }
    
    if (error is TimeoutException || error is http.ClientException) {
      return ErrorType.timeout;
    }
    
    if (error is http.Response) {
      final statusCode = error.statusCode;
      if (statusCode >= 500) {
        return ErrorType.server;
      }
      if (statusCode == 429) {
        return ErrorType.rateLimit;
      }
    }
    
    return ErrorType.unknown;
  }

  /// Log error to server (non-blocking)
  static Future<void> logError({
    required dynamic error,
    String? context,
    String? symbol,
    String? timeframe,
    Map<String, dynamic>? additionalData,
  }) async {
    // Always log errors (even in debug mode for testing)
    if (kDebugMode) {
      debugPrint('ErrorService: $error (context: $context)');
    }

    try {
      final errorType = getErrorType(error);
      final userId = UserService.currentUserId;
      
      final errorData = {
        'type': errorType.name,
        'message': error.toString(),
        'errorClass': error.runtimeType.toString(),
        'timestamp': DateTime.now().toIso8601String(),
        if (userId != null) 'userId': userId,
        if (context != null) 'context': context,
        if (symbol != null) 'symbol': symbol,
        if (timeframe != null) 'timeframe': timeframe,
        if (additionalData != null) ...additionalData,
      };

      // Send to server (non-blocking, don't wait for response)
      http
          .post(
            Uri.parse('$_endpoint/admin/log-error'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(errorData),
          )
          .timeout(_logTimeout, onTimeout: () {
        // Silently fail - don't block user experience
        return http.Response('', 408);
      }).catchError((_) {
        // Silently fail - don't log logging errors
        return http.Response('', 500);
      });
    } catch (e) {
      // Silently fail - don't log logging errors
      if (kDebugMode) {
        debugPrint('ErrorService: Failed to log error: $e');
      }
    }
  }
}
