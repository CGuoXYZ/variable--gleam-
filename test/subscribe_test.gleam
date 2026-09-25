import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/string

import error
import var

// ───────────────────────────── 工具 ─────────────────────────────

const default_timeout = 1000

/// 在一个作用域里跑断言，回调返回 Nil；作用域本身失败则测试失败
fn with(value: a, run: fn(var.Var(a)) -> Nil) -> Nil {
  let assert Ok(Nil) = var.scope(value, run)
  Nil
}

/// 订阅并把收到的每一对 (旧值, 新值) 转发到通道
fn record(
  value: var.Var(a),
  seen: process.Subject(#(a, a)),
) -> fn() -> var.Unsubscribed {
  var.subscribe(value, fn(old, new) { process.send(seen, #(old, new)) })
}

/// 当前 VM 的进程数，用来检测订阅进程是否泄漏
@external(erlang, "erlang", "processes")
fn processes() -> List(process.Pid)

fn process_count() -> Int {
  list.length(processes())
}

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, key: Dynamic) -> Dynamic

/// 本进程邮箱里待处理的消息数
///
/// 订阅通知必须发给「订阅进程」，而不是调用 subscribe 的那个进程。
/// 这个函数用来把「通知发错进程」这种 bug 钉住。
fn mailbox_len() -> Int {
  let info =
    process_info(
      process.self(),
      atom.to_dynamic(atom.create("message_queue_len")),
    )

  case decode.run(info, decode.at([1], decode.int)) {
    Ok(len) -> len
    Error(_) -> -1
  }
}

/// 取 n 条消息；取不到就让断言失败（不会把测试挂死）
fn take(subject: process.Subject(a), n: Int) -> List(a) {
  case n <= 0 {
    True -> []
    False -> {
      let assert Ok(message) = process.receive(subject, default_timeout)
      [message, ..take(subject, n - 1)]
    }
  }
}

/// 断言通道里没有待处理的消息
///
/// 只能靠超时判断：通知由「订阅进程」发出，与测试进程不是同一个发送方，
/// 所以无法用哨兵消息做严格屏障。好在生产者侧的顺序是有保证的
/// （测试进程先发 Unsubscribe 再发 Set，值进程必然按序处理），
/// 因此这里超时基本等价于「确实没通知」。
fn assert_no_message(subject: process.Subject(a)) -> Nil {
  case process.receive(subject, 100) {
    Ok(_) -> panic as "不应该再收到通知"
    Error(_) -> Nil
  }
}

/// [1, 2, .., n]
fn count(n: Int) -> List(Int) {
  case n <= 0 {
    True -> []
    False -> [n, ..count(n - 1)]
  }
}

/// 拿到一个逃出作用域的 Var
fn escaped_var() -> var.Var(Int) {
  let box = process.new_subject()
  let assert Ok(Nil) =
    var.scope(5, fn(v) {
      process.send(box, v)
      Nil
    })
  process.receive_forever(box)
}

/// 拿到一个确定已死亡的 Var
fn dead_var() -> var.Var(Int) {
  let escaped = escaped_var()
  // kill 与这次 get 同源，顺序有保证；get 会因为进程已退出而 panic，
  // panic 回来时进程一定已经死了
  let assert Error(_) = error.try(fn() { var.get(escaped, default_timeout) })
  escaped
}

// ─────────────────────── 旧值 / 新值的语义 ───────────────────────

/// set 通知时同时给出旧值和新值
pub fn set_notifies_with_old_and_new_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ = record(v, seen)

    let _ = var.set_forever(v, 1)

    assert take(seen, 1) == [#(0, 1)]
  })
}

/// update 通知时同时给出旧值和新值
pub fn update_notifies_with_old_and_new_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ = record(v, seen)

    assert var.update(v, fn(n) { n + 1 }) == Ok(1)

    assert take(seen, 1) == [#(0, 1)]
  })
}

/// 连续变化时，每一条的旧值就是上一条的新值（首尾相接）
pub fn consecutive_changes_chain_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ = record(v, seen)

    list.each([1, 2, 3], fn(n) { var.set_forever(v, n) })

    assert take(seen, 3) == [#(0, 1), #(1, 2), #(2, 3)]
  })
}

/// 设成相同的值也会通知，此时旧值等于新值
pub fn set_same_value_still_notifies_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ = record(v, seen)

    let _ = var.set_forever(v, 5)
    let _ = var.set_forever(v, 5)

    assert take(seen, 2) == [#(0, 5), #(5, 5)]
  })
}

/// 旧值由值进程给出，不在订阅者自己记
///
/// b 是晚一步订阅的，它第一条通知的旧值是「订阅那一刻的实际值」，
/// 不会因为漏看了前面的变化而给出错误的旧值。
pub fn old_value_is_computed_by_value_process_test() {
  with(0, fn(v) {
    let a = process.new_subject()
    let b = process.new_subject()
    let _ = record(v, a)

    let _ = var.set_forever(v, 1)
    // b 晚一步订阅
    let _ = record(v, b)
    let _ = var.set_forever(v, 2)

    assert take(a, 2) == [#(0, 1), #(1, 2)]
    assert take(b, 1) == [#(1, 2)]
  })
}

/// 订阅不补发当前值，只收注册之后的变更
///
/// 但第一条通知的旧值仍然是真实的「之前的值」，不是订阅者自己的初始值。
pub fn subscribe_does_not_replay_current_value_test() {
  with(0, fn(v) {
    // 此时还没有订阅者
    let _ = var.set_forever(v, 5)
    let _ = var.set_forever(v, 6)

    let seen = process.new_subject()
    let _ = record(v, seen)
    let _ = var.set_forever(v, 7)

    assert take(seen, 1) == [#(6, 7)]
  })
}

/// 订阅后立刻 set，第一次变化不会漏
pub fn subscription_does_not_miss_first_change_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ = record(v, seen)

    let _ = var.set_forever(v, 42)

    assert take(seen, 1) == [#(0, 42)]
  })
}

/// 通知保序
pub fn notifications_are_ordered_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ = record(v, seen)

    list.each([1, 2, 3, 4, 5], fn(n) { var.set_forever(v, n) })

    assert take(seen, 5) == [#(0, 1), #(1, 2), #(2, 3), #(3, 4), #(4, 5)]
  })
}

/// update 的回调异常时不通知（值没有变化）
///
/// 用「前后各一次 set」把它夹住：三次操作只有两次该产生通知，
/// 而通知都由同一个订阅进程发出（消息保序），所以结果必然是这两条。
pub fn failed_update_does_not_notify_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ = record(v, seen)

    let _ = var.set_forever(v, 1)
    let assert Error(_) = var.update(v, fn(_) { panic as "更新失败" })
    let _ = var.set_forever(v, 2)

    assert take(seen, 2) == [#(0, 1), #(1, 2)]
  })
}

/// 别的类型一样能拿到旧值和新值
pub fn old_and_new_work_for_other_types_test() {
  let seen = process.new_subject()
  let assert Ok(Nil) =
    var.scope("a", fn(v) {
      let _ = record(v, seen)
      let _ = var.set_forever(v, "b")
      let _ = var.set_forever(v, "c")
      Nil
    })

  assert take(seen, 2) == [#("a", "b"), #("b", "c")]
}

/// 回调的返回值可以是任意类型（签名里是 discard），不会被使用
pub fn callback_may_return_any_value_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ =
      var.subscribe(v, fn(old, new) {
        process.send(seen, #(old, new))
        old + new
      })

    let _ = var.set_forever(v, 1)

    assert take(seen, 1) == [#(0, 1)]
  })
}

// ─────────────────────────── 投递与多订阅者 ───────────────────────────

/// 多个订阅者都能收到同一对旧值/新值
pub fn multiple_subscribers_all_receive_test() {
  with(0, fn(v) {
    let a = process.new_subject()
    let b = process.new_subject()
    let c = process.new_subject()
    let _ = record(v, a)
    let _ = record(v, b)
    let _ = record(v, c)

    let _ = var.set_forever(v, 9)

    assert take(a, 1) == [#(0, 9)]
    assert take(b, 1) == [#(0, 9)]
    assert take(c, 1) == [#(0, 9)]
  })
}

// ─────────────────── 通知发给了谁（回归测试）───────────────────
//
// 曾经 subscribe 在「调用方进程」里创建 subject，于是通知全塞进了调用方
// 邮箱，订阅进程永远收不到，回调一次都不会被调用。这条测试把路由钉住。

pub fn notifications_go_to_subscriber_not_caller_test() {
  with(0, fn(v) {
    let before = mailbox_len()
    let seen = process.new_subject()
    let _ = record(v, seen)

    list.each([1, 2, 3, 4, 5], fn(n) { var.set_forever(v, n) })

    // 订阅者确实收到了
    assert take(seen, 5) == [#(0, 1), #(1, 2), #(2, 3), #(3, 4), #(4, 5)]
    // 调用方邮箱里没有多出通知
    assert mailbox_len() == before
  })
}

// ─────────────────────────── 取消订阅 ───────────────────────────

/// 取消后不再收到通知
pub fn unsubscribe_stops_notifications_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let unsub = record(v, seen)

    let _ = var.set_forever(v, 1)
    assert take(seen, 1) == [#(0, 1)]

    let _ = unsub()
    let _ = var.set_forever(v, 2)

    assert_no_message(seen)
  })
}

/// 退订函数的返回值是 Unsubscribed，而且确实退订了
pub fn unsubscribe_returns_unsubscribed_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let unsub = record(v, seen)

    // 类型标注本身就是编译期断言
    let result: var.Unsubscribed = unsub()
    assert string.inspect(result) == "Unsubscribed"

    let _ = var.set_forever(v, 1)
    assert_no_message(seen)
  })
}

/// 重复退订不崩，也不影响值进程
pub fn unsubscribe_is_idempotent_test() {
  with(0, fn(v) {
    let unsub = var.subscribe(v, fn(_, _) { Nil })

    let _ = unsub()
    let _ = unsub()
    let _ = unsub()

    assert var.is_alive(v) == True
    assert var.try_get(v, default_timeout) == Ok(0)
  })
}

/// 取消订阅只影响自己，别的订阅者照常
pub fn unsubscribe_only_affects_itself_test() {
  with(0, fn(v) {
    let a = process.new_subject()
    let b = process.new_subject()
    let unsub_a = record(v, a)
    let _ = record(v, b)

    let _ = unsub_a()
    let _ = var.set_forever(v, 3)

    assert_no_message(a)
    assert take(b, 1) == [#(0, 3)]
  })
}

/// 退订会回收订阅进程
pub fn unsubscribe_frees_subscriber_process_test() {
  with(0, fn(v) {
    let base = process_count()

    let unsubs =
      list.map(count(50), fn(_) { var.subscribe(v, fn(_, _) { Nil }) })
    assert process_count() >= base + 50

    list.each(unsubs, fn(u) { u() })
    process.sleep(300)

    // 留一点环境噪音的余量，但 50 个订阅进程必须都回收
    assert process_count() <= base + 5
  })
}

/// 取消后再订阅不会串台
pub fn resubscribe_after_unsubscribe_test() {
  with(0, fn(v) {
    let old = process.new_subject()
    let new = process.new_subject()

    let unsub = record(v, old)
    let _ = unsub()
    process.sleep(50)

    let _ = record(v, new)
    let _ = var.set_forever(v, 7)

    assert take(new, 1) == [#(0, 7)]
    assert_no_message(old)
  })
}

/// 值进程销毁后订阅自动结束，订阅进程被回收
pub fn var_death_frees_subscriber_process_test() {
  let base = process_count()

  with(0, fn(v) {
    let _ = var.subscribe(v, fn(_, _) { process.sleep(5000) })
    let _ = var.subscribe(v, fn(_, _) { process.sleep(5000) })
    // 值进程 + 两个订阅进程
    assert process_count() >= base + 2
  })

  process.sleep(300)
  assert process_count() <= base + 5
}

/// 对已死亡的值订阅是安全的：不挂起、不崩，退订也安全
pub fn subscribe_on_dead_var_is_safe_test() {
  let dead = dead_var()

  let unsub = var.subscribe(dead, fn(_, _) { Nil })
  let _ = unsub()

  assert var.is_alive(dead) == False
}

// ────────────────── 回调在独立进程里执行（不阻塞）──────────────────

/// 慢回调不阻塞 get
pub fn slow_callback_does_not_block_get_test() {
  with(0, fn(v) {
    let _ = var.subscribe(v, fn(_, _) { process.sleep(500) })

    let _ = var.set_forever(v, 1)

    assert var.try_get(v, 50) == Ok(1)
  })
}

/// 慢回调不阻塞 set
pub fn slow_callback_does_not_block_set_test() {
  with(0, fn(v) {
    let _ = var.subscribe(v, fn(_, _) { process.sleep(500) })

    assert var.try_set(v, 50, 1) == Ok(1)
    assert var.try_get(v, 50) == Ok(1)
  })
}

/// 连续 set 不等待回调完成
pub fn many_sets_do_not_wait_for_callback_test() {
  with(0, fn(v) {
    let _ = var.subscribe(v, fn(_, _) { process.sleep(200) })

    list.each([1, 2, 3], fn(n) {
      assert var.try_set(v, 50, n) == Ok(n)
    })
  })
}

/// 一个慢订阅者不拖累其他订阅者
pub fn slow_subscriber_does_not_delay_others_test() {
  with(0, fn(v) {
    let slow = process.new_subject()
    let fast = process.new_subject()
    let _ =
      var.subscribe(v, fn(old, new) {
        process.send(slow, #(old, new))
        process.sleep(300)
      })
    let _ = record(v, fast)

    let _ = var.set_forever(v, 1)

    assert process.receive(fast, 100) == Ok(#(0, 1))
  })
}

/// 回调慢导致消息堆积时，每一对旧值/新值仍然正确
///
/// 旧值和新值都是值进程在产生变化时一起发出的，
/// 订阅进程只是按顺序消费，不会因为堆积而错配。
pub fn slow_callback_still_gets_correct_pairs_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ =
      var.subscribe(v, fn(old, new) {
        process.sleep(50)
        process.send(seen, #(old, new))
      })

    list.each([1, 2, 3], fn(n) { var.set_forever(v, n) })

    assert take(seen, 3) == [#(0, 1), #(1, 2), #(2, 3)]
  })
}

// ─────────────────── 回调异常被隔离（不影响别人）───────────────────

/// 回调抛异常后，这个订阅仍然继续工作
pub fn callback_panic_does_not_stop_subscription_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ =
      var.subscribe(v, fn(old, new) {
        case new {
          1 -> panic as "回调炸了"
          _ -> process.send(seen, #(old, new))
        }
      })

    let _ = var.set_forever(v, 1)
    let _ = var.set_forever(v, 2)

    assert take(seen, 1) == [#(1, 2)]
  })
}

/// 一个回调抛异常不影响其他订阅者
pub fn callback_panic_does_not_affect_others_test() {
  with(0, fn(v) {
    let seen = process.new_subject()
    let _ = var.subscribe(v, fn(_, _) { panic as "回调炸了" })
    let _ = record(v, seen)

    let _ = var.set_forever(v, 3)

    assert take(seen, 1) == [#(0, 3)]
  })
}

/// 回调里用同一个 Var 不会死锁
///
/// 早期的内联实现会把值进程卡死：回调里的 update 永远等不到回复，
/// 之后所有读写都超时，而且进程还"活着"。这里用一个完成信号做屏障。
pub fn callback_can_update_same_var_test() {
  with(0, fn(v) {
    let done = process.new_subject()
    let _ =
      var.subscribe(v, fn(_, new) {
        case new {
          1 -> {
            let _ = var.update(v, fn(n) { n + 100 })
            process.send(done, Nil)
            Nil
          }
          _ -> Nil
        }
      })

    let _ = var.set_forever(v, 1)

    let assert Ok(Nil) = process.receive(done, default_timeout)
    assert var.try_get(v, default_timeout) == Ok(101)
  })
}

/// 回调里 set 同一个 Var 也不会死锁（值是回调自己设的）
pub fn callback_can_set_same_var_test() {
  with(0, fn(v) {
    let done = process.new_subject()
    let _ =
      var.subscribe(v, fn(_, new) {
        case new {
          1 -> {
            let _ = var.set_forever(v, 2)
            process.send(done, Nil)
            Nil
          }
          _ -> Nil
        }
      })

    let _ = var.set_forever(v, 1)

    let assert Ok(Nil) = process.receive(done, default_timeout)
    assert var.try_get(v, default_timeout) == Ok(2)
  })
}
