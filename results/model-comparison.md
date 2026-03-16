# Opencode CLI Model Comparison Report

## Ruby MiniGit Benchmark Results (20 trials each)

## Summary Table

| Model | v1 Pass Rate | v2 Pass Rate | Avg v1 Time | Avg v2 Time | Avg Total Time | Avg LOC (v2) |
|-------|--------------|--------------|-------------|-------------|----------------|--------------|
| qwen3.5-plus | 19/20 (95%) | 20/20 (100%) | 36.5s | 66.0s | 102.5s | 273 |
| MiniMax-M2.5 | 0/20 (0%) | 0/20 (0%) | 2.8s | 2.9s | 5.7s | 0 |
| kimi-k2.5 | 17/20 (85%) | 20/20 (100%) | 75.7s | 92.1s | 167.8s | 271 |
| glm-5 | 20/20 (100%) | 19/20 (95%) | 52.6s | 71.9s | 124.5s | 216 |

## Detailed Analysis

### Qwen 3.5 Plus

- **v1 Pass Rate**: 19/20 (95%)
- **v2 Pass Rate**: 20/20 (100%)
- **v1 Time**: 36.5s ± 14.4s
- **v2 Time**: 66.0s ± 17.7s
- **Total Time**: 102.5s

Best overall performance with highest reliability and fastest execution time.

### GLM-5

- **v1 Pass Rate**: 20/20 (100%)
- **v2 Pass Rate**: 19/20 (95%)
- **v1 Time**: 52.6s ± 13.4s
- **v2 Time**: 71.9s ± 18.6s
- **Total Time**: 124.5s

Excellent v1 reliability (100%), slightly slower than Qwen 3.5 Plus.

### Kimi K2.5

- **v1 Pass Rate**: 17/20 (85%)
- **v2 Pass Rate**: 20/20 (100%)
- **v1 Time**: 75.7s ± 34.7s
- **v2 Time**: 92.1s ± 23.2s
- **Total Time**: 167.8s

Slower execution with occasional v1 failures, but excellent v2 recovery.

### MiniMax-M2.5

- **v1 Pass Rate**: 0/20 (0%)
- **v2 Pass Rate**: 0/20 (0%)
- **v1 Time**: 2.8s ± 0.3s
- **v2 Time**: 2.9s ± 0.2s
- **Total Time**: 5.7s

**Not compatible with Opencode CLI**. API returns error:
```
Error: max_tokens parameter must be between 1 and 32768
```

## Notes

- **MiniMax-M2.5**: Failed all trials due to API error
  - Error: `max_tokens` parameter must be between 1 and 32768
  - This is an Opencode CLI compatibility issue with this model
- **Kimi K2.5**: 3 trials had v1 failures (0/0 tests generated)
  - But v2 passed in all cases, showing strong recovery
- **GLM-5**: 1 trial had v2 failure (0/0 tests)
  - Otherwise showed excellent performance
- **Qwen 3.5 Plus**: 1 trial had 10/11 v1 tests
  - v2 passed in all trials

## Conclusion

**Ranking by Reliability:**
1. **Qwen 3.5 Plus** - 95%/100% pass rate, fastest execution
2. **GLM-5** - 100%/95% pass rate, second fastest
3. **Kimi K2.5** - 85%/100% pass rate, slower execution
4. **MiniMax-M2.5** - Not compatible with Opencode CLI

**Ranking by Speed:**
1. **Qwen 3.5 Plus** - 102.5s average
2. **GLM-5** - 124.5s average
3. **Kimi K2.5** - 167.8s average