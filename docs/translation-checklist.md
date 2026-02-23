# English Translation & i18n Readiness Checklist

## Completed ✅

### Code Translation
- [x] `/openai_adapter/main.py` - All Chinese strings converted to English
  - [x] Module docstring
  - [x] Section comments
  - [x] Function docstrings
  - [x] Error messages
- [x] `/openai_adapter/test_openai_sdk.py` - Test file translated
  - [x] Comments
  - [x] Test descriptions
  - [x] Output messages
- [x] `/mac/houmao/houmao/LLMClient.swift` - Mock responses in English
- [x] `/mac/houmao/houmao/MainView.swift` - UI filter updated
- [x] `/mac/houmao/houmao/UsageTracker.swift` - App switch prefix updated

### Documentation
- [x] Created `/docs/i18n-architecture.md` - Comprehensive i18n architecture guide
- [x] Created `/docs/translation-summary.md` - Summary of all changes

## Testing Checklist

### Python (OpenAI Adapter)
- [ ] Run the adapter: `cd openai_adapter && python main.py`
- [ ] Test health endpoint: `curl http://localhost:8080/health`
- [ ] Run test suite: `python test_openai_sdk.py`
- [ ] Verify error messages display in English

### Swift (macOS App)
- [ ] Build the app in Xcode
- [ ] Test app switching - verify "[Switch]" appears in history
- [ ] Test mock LLM - verify English response
- [ ] Check history filtering still works with English "[Switch]" prefix

## Known Issues / Considerations

### Data Compatibility
- Existing history records with Chinese "[切换]" will remain
- App settings filter checks for "[Switch]" prefix
- Old records with "[切换]" won't be filtered if `showAppSwitch` is false

### Recommendations
1. **Add migration for existing data** (optional):
   ```swift
   // Batch update existing records
   UPDATE history SET text = REPLACE(text, '[切换]', '[Switch]')
   WHERE text LIKE '[切换]%'
   ```

2. **Update filter logic** (recommended):
   ```swift
   // Support both old and new format during transition
   let filtered = settings.showAppSwitch
       ? historyViewModel.records
       : historyViewModel.records.filter {
           !$0.text.hasPrefix("[Switch]") &&
           !$0.text.hasPrefix("[切换]")
         }
   ```

## Next Steps for Full i18n Support

### Phase 1: Infrastructure Setup
- [ ] Install localization tools
  - [ ] Swift: Create `.lproj` directories
  - [ ] Python: Install `babel` for gettext support
- [ ] Create localization files
  - [ ] `en.lproj/Localizable.strings`
  - [ ] `zh-Hans.lproj/Localizable.strings`
  - [ ] `locales/zh_CN/LC_MESSAGES/messages.po`

### Phase 2: Code Updates
- [ ] Create `LanguageDetector.swift` utility
- [ ] Update `AppSettings` with language preferences
- [ ] Wrap all UI strings with `NSLocalizedString()`
- [ ] Update data models to include language field

### Phase 3: Translation
- [ ] Extract all localizable strings
- [ ] Translate to target languages
- [ ] Review and test translations

### Phase 4: Testing
- [ ] Test language switching
- [ ] Verify all UI strings are translated
- [ ] Test with mixed-language input
- [ ] Verify language detection accuracy

## Files to Monitor

### Python
- `openai_adapter/main.py` - API adapter
- `openai_adapter/test_openai_sdk.py` - Tests

### Swift
- `mac/houmao/houmao/MainView.swift` - Main UI
- `mac/houmao/houmao/LLMClient.swift` - LLM interface
- `mac/houmao/houmao/UsageTracker.swift` - History tracking
- `mac/houmao/houmao/AppSettings.swift` - Settings (for language prefs)

## Resources

- Architecture guide: `/docs/i18n-architecture.md`
- Translation summary: `/docs/translation-summary.md`
- Apple i18n docs: https://developer.apple.com/localization/
- Python gettext: https://docs.python.org/3/library/gettext.html

## Git Commit Suggestion

```bash
git add -A
git commit -m "Translate all prompts from Chinese to English

- Convert all user-facing strings to English as base language
- Update OpenAI adapter comments and messages
- Update Swift mock responses and history prefixes
- Add comprehensive i18n architecture documentation
- Prepare codebase for multi-language todo support

This establishes English as the foundation for future
internationalization and multi-language feature development."
```

## Completion Criteria

The task is complete when:
1. ✅ All Chinese strings in code are translated to English
2. ✅ Documentation is created for future i18n work
3. [ ] All tests pass
4. [ ] App builds and runs successfully
5. [ ] No regressions in functionality

## Notes

- This is the foundation for multi-language support
- Future work will build on this base
- English is now the primary language for the codebase
- Localization can be added incrementally
