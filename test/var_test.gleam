import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import gleeunit

import error
import var

pub fn main() -> Nil {
  gleeunit.main()
}

// 用于测试的自定义类型
type Point {
  Point(x: Int, y: Int)
}

const default_timeout = 1000

// ───────────────────────────── 工具 ─────────────────────────────

/// 在一个作用域里跑断言，回调返回 Nil；作用域本身失败则测试失败
fn with(value: a, run: fn(var.Var(a)) -> Nil) -> Nil {
  let assert Ok(Nil) = var.scope(value, run)
  Nil
}

/// 让值进程忙起来 ms 毫秒。
///
/// 做法：在另一个进程里发起一次耗时的 update（update 在值进程内部执行），
/// 等回调真的进了值进程（收到 busy 信号）再返回，
/// 这样后续的读写就一定能撞上超时，不依赖 sleep 的运气。
fn occupy(value: var.Var(a), ms: Int) -> Nil {
  let busy = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      var.update(value, fn(v) {
        process.send(busy, Nil)
        process.sleep(ms)
        v
      })
    })
  process.receive_forever(busy)
}

// shine_try 现在只交出原始数据（class / reason / stacktrace），
// 所以下面两个 helper 就是"使用者拿到之后要自己做的事"。

/// reason 是 atom 键的 Erlang map，Gleam 里写不出 atom 键，
/// 所以整体解出来后再用 string.inspect 出来的名字比对
fn entries(reason: Dynamic) -> List(#(String, Dynamic)) {
  case decode.run(reason, decode.dict(decode.dynamic, decode.dynamic)) {
    Error(_) -> []
    Ok(dict) ->
      dict
      |> dict.to_list
      |> list.map(fn(kv) { #(string.inspect(kv.0), kv.1) })
  }
}

/// 取 reason 里某个字段的字符串值（取不到返回空串）
fn reason_field(reason: Dynamic, name: String) -> String {
  entries(reason)
  |> list.find_map(fn(kv) {
    case kv.0 == name {
      True ->
        case decode.run(kv.1, decode.string) {
          Ok(text) -> Ok(text)
          Error(_) -> Error(Nil)
        }
      False -> Error(Nil)
    }
  })
  |> result.unwrap("")
}

/// class 是原始的 Erlang atom：error / exit / throw
fn class_name(class: Dynamic) -> String {
  string.inspect(class)
}

// 测试里需要主动抛出另外两类异常
@external(erlang, "erlang", "throw")
fn throw(value: a) -> b

@external(erlang, "erlang", "exit")
fn exit(reason: a) -> b

// ─────────────────────────── 获取 ───────────────────────────

pub fn get_initial_test() {
  with(5, fn(v) {
    assert var.get(v, default_timeout) == 5
  })
}

pub fn get_repeated_test() {
  with(5, fn(v) {
    assert var.get(v, default_timeout) == 5
    assert var.get(v, default_timeout) == 5
    assert var.get(v, default_timeout) == 5
  })
}

pub fn try_get_ok_test() {
  with(7, fn(v) {
    assert var.try_get(v, default_timeout) == Ok(7)
  })
}

// ─────────────────────────── 设置 ───────────────────────────

pub fn set_returns_new_value_test() {
  with(5, fn(v) {
    assert var.set(v, default_timeout, 10) == 10
  })
}

pub fn set_then_get_test() {
  with(5, fn(v) {
    assert var.get(v, default_timeout) == 5
    assert var.set(v, default_timeout, 10) == 10
    assert var.get(v, default_timeout) == 10
  })
}

pub fn set_many_test() {
  with(0, fn(v) {
    assert var.set(v, default_timeout, 1) == 1
    assert var.set(v, default_timeout, 2) == 2
    assert var.set(v, default_timeout, 3) == 3
    assert var.get(v, default_timeout) == 3
  })
}

pub fn try_set_ok_test() {
  with(0, fn(v) {
    assert var.try_set(v, default_timeout, 9) == Ok(9)
    assert var.get(v, default_timeout) == 9
  })
}

// ─────────────────────────── 更新 ───────────────────────────

pub fn update_returns_new_value_test() {
  with(5, fn(v) {
    assert var.update(v, fn(x) { x + 1 }) == Ok(6)
  })
}

pub fn update_then_get_test() {
  with(5, fn(v) {
    assert var.update(v, fn(x) { x * 2 }) == Ok(10)
    assert var.get(v, default_timeout) == 10
  })
}

pub fn update_chain_test() {
  with(0, fn(v) {
    assert var.update(v, fn(x) { x + 1 }) == Ok(1)
    assert var.update(v, fn(x) { x * 10 }) == Ok(10)
    assert var.update(v, fn(x) { x - 3 }) == Ok(7)
    assert var.get(v, default_timeout) == 7
  })
}

/// 回调 panic：返回 Error，且值不变
pub fn update_panic_keeps_value_test() {
  with(5, fn(v) {
    let assert Error(var.UpdateErr(_)) = var.update(v, fn(_) { panic })
    assert var.get(v, default_timeout) == 5
  })
}

/// 回调 panic：错误里带着 shine_try 交出来的原始信息
pub fn update_error_payload_test() {
  with(5, fn(v) {
    let assert Error(var.UpdateErr(e)) = var.update(v, fn(_) { panic as "故意失败" })

    assert class_name(e.class) == "Error"
    assert reason_field(e.reason, "Message") == "故意失败"
    assert reason_field(e.reason, "File") == "test/var_test.gleam"
    assert var.get(v, default_timeout) == 5
  })
}

// ─────────────────────────── 类型无关 ───────────────────────────

pub fn string_value_test() {
  with("hello", fn(v) {
    assert var.get(v, default_timeout) == "hello"
    assert var.set(v, default_timeout, "world") == "world"
    assert var.update(v, fn(s) { s <> "!" }) == Ok("world!")
    assert var.get(v, default_timeout) == "world!"
  })
}

pub fn list_value_test() {
  with([1, 2, 3], fn(v) {
    assert var.update(v, fn(l) { list.append(l, [4]) }) == Ok([1, 2, 3, 4])
    assert var.get(v, default_timeout) == [1, 2, 3, 4]
  })
}

pub fn custom_type_value_test() {
  with(Point(1, 2), fn(v) {
    assert var.get(v, default_timeout) == Point(1, 2)
    assert var.update(v, fn(p) { Point(x: p.x + 1, y: p.y + 1) })
      == Ok(Point(2, 3))
    assert var.set(v, default_timeout, Point(9, 9)) == Point(9, 9)
    assert var.get(v, default_timeout) == Point(9, 9)
  })
}

// ─────────────────────────── 作用域 ───────────────────────────

/// 回调的返回值会被 scope 带出来
pub fn scope_returns_callback_value_test() {
  let assert Ok(42) = var.scope(5, fn(v) { var.get(v, default_timeout) + 37 })
  Nil
}

/// 回调 panic：返回 ScopeErr，并带着原始异常信息
pub fn scope_callback_panic_test() {
  let result = var.scope(5, fn(_) { panic as "炸了" })

  let assert Error(var.ScopeErr(e)) = result
  assert class_name(e.class) == "Error"
  assert reason_field(e.reason, "Message") == "炸了"
}

/// 回调 throw：class 是 throw
pub fn scope_callback_throw_test() {
  let result = var.scope(5, fn(_) { throw("boom") })
  let assert Error(var.ScopeErr(e)) = result
  assert class_name(e.class) == "Throw"
}

/// 回调 exit：class 是 exit
pub fn scope_callback_exit_test() {
  let result = var.scope(5, fn(_) { exit("bye") })
  let assert Error(var.ScopeErr(e)) = result
  assert class_name(e.class) == "Exit"
}

/// 嵌套作用域互不影响
pub fn nested_scope_test() {
  with(1, fn(outer) {
    assert var.set(outer, default_timeout, 2) == 2

    with(10, fn(inner) {
      assert var.set(inner, default_timeout, 20) == 20
      assert var.get(inner, default_timeout) == 20
    })

    // 内层销毁后，外层仍然可用且值不变
    assert var.get(outer, default_timeout) == 2
  })
}

// ─────────────────────────── 超时 ───────────────────────────

pub fn try_get_timeout_test() {
  with(5, fn(v) {
    occupy(v, 300)
    assert var.try_get(v, 50) == Error(var.Timeout)
  })
}

pub fn try_set_timeout_test() {
  with(5, fn(v) {
    occupy(v, 300)
    assert var.try_set(v, 50, 10) == Error(var.Timeout)
  })
}

/// get 超时是 panic，不是返回 Result
pub fn get_timeout_panics_test() {
  with(5, fn(v) {
    occupy(v, 300)
    let assert Error(_) = error.try(fn() { var.get(v, 50) })
    Nil
  })
}

/// set 超时同样是 panic
pub fn set_timeout_panics_test() {
  with(5, fn(v) {
    occupy(v, 300)
    let assert Error(_) = error.try(fn() { var.set(v, 50, 10) })
    Nil
  })
}

// ─────────────────── 永久等待的读写（*_forever） ───────────────────

pub fn get_forever_test() {
  with(5, fn(v) {
    assert var.get_forever(v) == 5
  })
}

pub fn set_forever_test() {
  with(5, fn(v) {
    assert var.set_forever(v, 99) == 99
    assert var.get_forever(v) == 99
  })
}

/// 值进程忙时 get 会超时，get_forever 会一直等到它空闲
pub fn get_forever_waits_test() {
  with(5, fn(v) {
    occupy(v, 200)
    assert var.try_get(v, 50) == Error(var.Timeout)
    assert var.get_forever(v) == 5
  })
}

/// 值进程忙时 set 会超时，set_forever 会等到它空闲再设置
pub fn set_forever_waits_test() {
  with(5, fn(v) {
    occupy(v, 200)
    assert var.try_set(v, 50, 99) == Error(var.Timeout)
    assert var.set_forever(v, 99) == 99
    assert var.get_forever(v) == 99
  })
}

// ─────────────────── 出逃的可变值（文档声明不作保障） ───────────────────
//
// scope 的文档写明「对于可变值出逃后的行为不作保障」，
// 下面这几条锁的是**当前实现的行为**：一旦实现变化，可以放心更新它们。

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

/// 作用域内值还活着
pub fn is_alive_true_in_scope_test() {
  with(5, fn(v) {
    assert var.is_alive(v) == True
  })
}

/// 作用域结束后值已死亡
pub fn is_alive_false_after_scope_test() {
  let escaped = dead_var()
  assert var.is_alive(escaped) == False
}

/// 让作用域回调以给定方式异常结束，并断言值进程仍然被关闭
///
/// scope 内部的 defer 就是「无论回调怎么结束都关闭进程」这条保证。
/// 只测错误类型的话，很容易漏掉「进程没被关闭」这种情况。
fn assert_closed_after_error(run: fn(var.Var(Int)) -> Nil) -> Nil {
  let escaped = process.new_subject()
  let assert Error(var.ScopeErr(_)) =
    var.scope(5, fn(v) {
      process.send(escaped, v)
      run(v)
    })

  let assert Ok(v) = process.receive(escaped, default_timeout)
  // kill 与这次 get 同源，顺序有保证；进程已退出时 get 会 panic
  let assert Error(_) = error.try(fn() { var.get(v, default_timeout) })
  assert var.is_alive(v) == False
}

/// 回调 panic 时值进程同样被关闭
pub fn is_alive_false_after_callback_panic_test() {
  assert_closed_after_error(fn(_) { panic as "炸了" })
}

/// 回调 throw 时值进程同样被关闭
pub fn is_alive_false_after_callback_throw_test() {
  assert_closed_after_error(fn(_) { throw("boom") })
}

/// 回调 exit 时值进程同样被关闭
pub fn is_alive_false_after_callback_exit_test() {
  assert_closed_after_error(fn(_) { exit("bye") })
}

/// 已死亡的值，反复查询结果稳定
pub fn is_alive_stays_false_test() {
  let escaped = dead_var()
  assert var.is_alive(escaped) == False
  let _ = var.try_get(escaped, default_timeout)
  assert var.is_alive(escaped) == False
}

/// 作用域结束后，逃出去的 Var 再用会 panic
pub fn escaped_value_get_panics_test() {
  let escaped = escaped_var()

  // kill 与这次 get 都由本进程发出，消息顺序有保证
  let assert Error(_) = error.try(fn() { var.get(escaped, default_timeout) })
  Nil
}

/// 当前行为：值已死亡时 try_get 返回 Error(Timeout)（而不是别的错误）
pub fn escaped_value_try_get_is_timeout_test() {
  let escaped = dead_var()
  assert var.try_get(escaped, default_timeout) == Error(var.Timeout)
}

/// 当前行为：值已死亡时 update 会让调用方 panic，而不是返回 Error
pub fn update_on_dead_value_panics_test() {
  let escaped = dead_var()
  let survived = process.new_subject()

  let _ =
    process.spawn_unlinked(fn() {
      let _ = var.update(escaped, fn(x) { x })
      // 能走到这里说明 update 没有 panic（与预期不符）
      process.send(survived, Nil)
    })

  assert process.receive(survived, 200) == Error(Nil)
}

// ─────────────────────────── 并发 ───────────────────────────

/// 多个进程同时 update：值进程串行处理，结果不会丢更新
pub fn concurrent_update_test() {
  let workers = 10

  with(0, fn(v) {
    let done = process.new_subject()

    list.repeat(Nil, workers)
    |> list.each(fn(_) {
      let _ =
        process.spawn_unlinked(fn() {
          let _ = var.update(v, fn(x) { x + 1 })
          process.send(done, Nil)
        })
      Nil
    })

    list.repeat(Nil, workers)
    |> list.each(fn(_) { process.receive_forever(done) })

    assert var.get(v, default_timeout) == workers
  })
}

/// 另一个进程设置值，本进程能立刻读到（set 是同步的）
pub fn cross_process_set_test() {
  with(0, fn(v) {
    let done = process.new_subject()
    let _ =
      process.spawn_unlinked(fn() {
        process.send(done, var.set(v, default_timeout, 7))
      })

    assert process.receive_forever(done) == 7
    assert var.get(v, default_timeout) == 7
  })
}

/// 另一个进程读完把值带回来
pub fn cross_process_get_test() {
  with(99, fn(v) {
    let done = process.new_subject()
    let _ =
      process.spawn_unlinked(fn() {
        process.send(done, var.get(v, default_timeout))
      })

    assert process.receive_forever(done) == 99
  })
}
