# Internationalization (i18n) Architecture for Multi-language Todo Support

## Overview

This document outlines the architecture for supporting multi-language todo recording in the houmao application.

## Current State

All prompts and user-facing strings have been converted to English as the default language.

## Architecture Components

### 1. Language Detection

The system should automatically detect the language of user input:
- Use language detection libraries (e.g., `NaturalLanguage` framework on macOS)
- Support common languages: English, Chinese (Simplified/Traditional), Japanese, Korean, etc.

### 2. Localization Strategy

#### For Swift (macOS app):
- Use `Localizable.strings` files for UI strings
- Store localized strings in language-specific bundles
- Structure: `{language}.lproj/Localizable.strings`

Example structure:
```
mac/houmao/houmao/
├── en.lproj/
│   └── Localizable.strings
├── zh-Hans.lproj/
│   └── Localizable.strings
└── ja.lproj/
    └── Localizable.strings
```

#### For Python (openai_adapter):
- Use `gettext` for internationalization
- Store translations in `.po` files
- Use `babel` for translation management

### 3. Todo Data Model

#### Database Schema
```swift
struct TodoRecord {
    let id: UUID
    let timestamp: Date
    let text: String
    let language: String  // ISO 639-1 code (e.g., "en", "zh", "ja")
    let category: String? // Optional categorization
    let completed: Bool
    let metadata: [String: String]? // Additional flexible data
}
```

#### Storage
- Store todos with language metadata
- Allow filtering by language
- Support cross-language search (optional with translation API)

### 4. User Interface Changes

#### Settings
Add language preferences in AppSettings:
```swift
class AppSettings {
    @Published var uiLanguage: String = "en" // UI display language
    @Published var autoDetectLanguage: Bool = true
    @Published var defaultTodoLanguage: String = "en"
}
```

#### Display
- Show language indicator for each todo
- Allow filtering todos by language
- Support language-specific formatting (date, time, etc.)

### 5. API Integration

For the OpenAI adapter:
- Accept `language` parameter in API requests
- Return responses in the requested language
- Support language translation if needed

## Implementation Phases

### Phase 1: Foundation (Completed ✅)
- Convert all existing prompts to English
- Establish English as base language

### Phase 2: Infrastructure
- Create localization file structure
- Implement language detection utility
- Update data models to include language field

### Phase 3: Localization
- Add translation files for supported languages
- Implement language switching in UI
- Add language preferences

### Phase 4: Todo Multi-language Support
- Extend todo/history records with language field
- Add language filtering in history view
- Display language indicators

### Phase 5: Advanced Features
- Cross-language search
- Automatic translation (optional)
- Language-specific formatting

## Code Examples

### Swift Language Detection
```swift
import NaturalLanguage

func detectLanguage(_ text: String) -> String {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)

    guard let language = recognizer.dominantLanguage else {
        return "en" // default to English
    }

    return language.rawValue
}
```

### Localized String Usage
```swift
// In Swift code
Text(NSLocalizedString("history.title", comment: "History panel title"))

// In Localizable.strings (en)
"history.title" = "Usage History";

// In Localizable.strings (zh-Hans)
"history.title" = "使用历史";
```

### Python i18n (gettext)
```python
import gettext

# Setup
locale_dir = 'locales'
lang = 'zh_CN'
translation = gettext.translation('messages', locale_dir, languages=[lang])
translation.install()

# Usage
print(_("OpenAI Compatible Adapter"))
```

## File Changes Required

### New Files
- `mac/houmao/houmao/Localization/`
  - `LanguageDetector.swift`
  - `LocalizationManager.swift`
- `mac/houmao/houmao/en.lproj/Localizable.strings`
- `mac/houmao/houmao/zh-Hans.lproj/Localizable.strings`
- `openai_adapter/locales/zh_CN/LC_MESSAGES/messages.po`

### Modified Files
- `mac/houmao/houmao/UsageTracker.swift` - Add language detection
- `mac/houmao/houmao/MainView.swift` - Use localized strings
- `mac/houmao/houmao/AppSettings.swift` - Add language preferences
- Database models - Add language field

## Best Practices

1. **Always use keys for UI strings**: Never hardcode display text
2. **Keep translations in sync**: Use automated tools to track missing translations
3. **Context in comments**: Provide clear comments for translators
4. **Test with actual content**: Use real-world examples in all languages
5. **Right-to-left (RTL) support**: Consider RTL languages if needed in future
6. **Pluralization**: Handle plural forms correctly for each language
7. **Date/Time formatting**: Use locale-specific formatting

## Testing Strategy

- Test with mixed-language input
- Verify correct language detection
- Test UI in all supported languages
- Verify data storage and retrieval
- Test edge cases (unknown languages, mixed scripts)

## Migration Plan

For existing data:
1. Add migration script to add language field to existing records
2. Default to "en" for existing records, or attempt auto-detection
3. Preserve all existing functionality during migration

## Resources

- Apple's Localization Guide: https://developer.apple.com/localization/
- Python gettext documentation: https://docs.python.org/3/library/gettext.html
- ISO 639-1 language codes: https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes
