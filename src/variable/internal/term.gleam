pub opaque type Term {
  Term(deadline: Int)
  TermForever
}

/// 根据超时时间获取期限
pub fn deadline(timeout: Int) -> Term {
  Term(deadline: monotonic_ms() + timeout)
}

/// 永久期限
pub fn forever() -> Term {
  TermForever
}

/// 是否到期
pub fn is_expired(term: Term) -> Bool {
  case term {
    TermForever -> False
    Term(deadline:) -> monotonic_ms() >= deadline
  }
}

@external(erlang, "term_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int
