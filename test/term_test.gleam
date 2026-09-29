import gleam/erlang/process

import variable/internal/term

// ─────────────── 期限（单调时间 deadline）单元测试 ───────────────
//
// term 是内部模块，但 is_expired 的判定是整个「超时丢弃」语义的根，
// 直接钉住它定位更快，也覆盖了只走 var 层面测不到的分支。

/// forever 永远不会到期
pub fn forever_is_never_expired_test() {
  assert !term.is_expired(term.forever())
}

/// 期限 0：读取时必然已到期
///
/// deadline 是 monotonic_ms() + timeout，而单调时间只增不减，
/// 所以 timeout = 0 时 monotonic_ms() >= deadline 恒成立。
pub fn zero_deadline_is_expired_test() {
  assert term.is_expired(term.deadline(0))
}

/// 期限很长：不会立刻到期
pub fn far_deadline_is_not_expired_test() {
  assert !term.is_expired(term.deadline(10_000))
}

/// 时间确实在推进：短期限等一会就会到期
///
/// 这里不断言「还没到期」——那要求两次单调时钟调用之间严格小于 50ms，
/// 机器负载高时会抖。「还没到期」由 far_deadline_is_not_expired_test 负责。
pub fn deadline_expires_after_time_passes_test() {
  let t = term.deadline(50)
  process.sleep(150)
  assert term.is_expired(t)
}
