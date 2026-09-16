import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
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
  let assert Ok(Nil) = var.scope(value, default_timeout, run)
  Nil
}

/// 同上，但自定义超时上限
fn with_timeout(value: a, ms: Int, run: fn(var.Var(a)) -> Nil) -> Nil {
  let assert Ok(Nil) = var.scope(value, ms, run)
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

// ─────────────────────────── 获取 ───────────────────────────

pub fn get_initial_test() {
  with(5, fn(v) {
    assert var.get(v) == 5
  })
}

pub fn get_repeated_test() {
  with(5, fn(v) {
    assert var.get(v) == 5
    assert var.get(v) == 5
    assert var.get(v) == 5
  })
}

pub fn try_get_ok_test() {
  with(7, fn(v) {
    assert var.try_get(v) == Ok(7)
  })
}

// ─────────────────────────── 设置 ───────────────────────────

pub fn set_returns_new_value_test() {
  with(5, fn(v) {
    assert var.set(v, 10) == 10
  })
}

pub fn set_then_get_test() {
  with(5, fn(v) {
    assert var.get(v) == 5
    assert var.set(v, 10) == 10
    assert var.get(v) == 10
  })
}

pub fn set_many_test() {
  with(0, fn(v) {
    assert var.set(v, 1) == 1
    assert var.set(v, 2) == 2
    assert var.set(v, 3) == 3
    assert var.get(v) == 3
  })
}

pub fn try_set_ok_test() {
  with(0, fn(v) {
    assert var.try_set(v, 9) == Ok(9)
    assert var.get(v) == 9
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
    assert var.get(v) == 10
  })
}

pub fn update_chain_test() {
  with(0, fn(v) {
    assert var.update(v, fn(x) { x + 1 }) == Ok(1)
    assert var.update(v, fn(x) { x * 10 }) == Ok(10)
    assert var.update(v, fn(x) { x - 3 }) == Ok(7)
    assert var.get(v) == 7
  })
}

/// 回调 panic：返回 Error，且值不变
pub fn update_panic_keeps_value_test() {
  with(5, fn(v) {
    let assert Error(var.CallbackError(_)) = var.update(v, fn(_) { panic })
    assert var.get(v) == 5
  })
}

/// 回调 panic：错误里带着 shine_try 解析出来的异常信息
pub fn update_error_payload_test() {
  with(5, fn(v) {
    let assert Error(var.CallbackError(e)) =
      var.update(v, fn(_) { panic as "故意失败" })

    assert e.is_gleam_error == True
    assert e.message == Some("故意失败")
    assert e.class == error.ErrorClass
    assert var.get(v) == 5
  })
}

// ─────────────────────────── 类型无关 ───────────────────────────

pub fn string_value_test() {
  with("hello", fn(v) {
    assert var.get(v) == "hello"
    assert var.set(v, "world") == "world"
    assert var.update(v, fn(s) { s <> "!" }) == Ok("world!")
    assert var.get(v) == "world!"
  })
}

pub fn list_value_test() {
  with([1, 2, 3], fn(v) {
    assert var.update(v, fn(l) { list.append(l, [4]) }) == Ok([1, 2, 3, 4])
    assert var.get(v) == [1, 2, 3, 4]
  })
}

pub fn custom_type_value_test() {
  with(Point(1, 2), fn(v) {
    assert var.get(v) == Point(1, 2)
    assert var.update(v, fn(p) { Point(x: p.x + 1, y: p.y + 1) })
      == Ok(Point(2, 3))
    assert var.set(v, Point(9, 9)) == Point(9, 9)
    assert var.get(v) == Point(9, 9)
  })
}

// ─────────────────────────── 作用域 ───────────────────────────

/// 回调的返回值会被 scope 带出来
pub fn scope_returns_callback_value_test() {
  let assert Ok(42) = var.scope(5, default_timeout, fn(v) { var.get(v) + 37 })
  Nil
}

/// 回调 panic：返回 CallbackErr，并带着异常信息
pub fn scope_callback_panic_test() {
  let result = var.scope(5, default_timeout, fn(_) { panic as "炸了" })

  let assert Error(var.CallbackErr(e)) = result
  assert e.is_gleam_error == True
  assert e.message == Some("炸了")
  assert e.file != None
  assert e.line != None
}

/// 回调 throw：shine_try 捕获三类异常，同样返回 CallbackErr
pub fn scope_callback_throw_test() {
  let result = var.scope(5, default_timeout, fn(_) { throw("boom") })
  let assert Error(var.CallbackErr(e)) = result
  assert e.class == error.ThrowClass
}

/// 回调 exit：同样被捕获
pub fn scope_callback_exit_test() {
  let result = var.scope(5, default_timeout, fn(_) { exit("bye") })
  let assert Error(var.CallbackErr(e)) = result
  assert e.class == error.ExitClass
}

/// 嵌套作用域互不影响
pub fn nested_scope_test() {
  with(1, fn(outer) {
    assert var.set(outer, 2) == 2

    with(10, fn(inner) {
      assert var.set(inner, 20) == 20
      assert var.get(inner) == 20
    })

    // 内层销毁后，外层仍然可用且值不变
    assert var.get(outer) == 2
  })
}

// ─────────────────────────── 超时 ───────────────────────────

pub fn try_get_timeout_test() {
  with_timeout(5, 50, fn(v) {
    occupy(v, 300)
    assert var.try_get(v) == Error(var.Timeout)
  })
}

pub fn try_set_timeout_test() {
  with_timeout(5, 50, fn(v) {
    occupy(v, 300)
    assert var.try_set(v, 10) == Error(var.Timeout)
  })
}

/// get 超时是 panic，不是返回 Result
pub fn get_timeout_panics_test() {
  with_timeout(5, 50, fn(v) {
    occupy(v, 300)
    let assert Error(_) = error.try(fn() { var.get(v) })
    Nil
  })
}

/// set 超时同样是 panic
pub fn set_timeout_panics_test() {
  with_timeout(5, 50, fn(v) {
    occupy(v, 300)
    let assert Error(_) = error.try(fn() { var.set(v, 10) })
    Nil
  })
}

// ─────────────────── 永久等待的读写（*_forever） ───────────────────

/// get_forever 不受 time_out 限制：time_out = 0 时 get 会超时，它依然能拿到值
pub fn get_forever_ignores_timeout_test() {
  with_timeout(5, 0, fn(v) {
    assert var.get_forever(v) == 5
  })
}

/// set_forever 同理
pub fn set_forever_ignores_timeout_test() {
  with_timeout(5, 0, fn(v) {
    assert var.set_forever(v, 99) == 99
    assert var.get_forever(v) == 99
  })
}

/// 值进程忙时 get 会超时，get_forever 会一直等到它空闲
pub fn get_forever_waits_test() {
  with_timeout(5, 50, fn(v) {
    occupy(v, 200)
    assert var.try_get(v) == Error(var.Timeout)
    assert var.get_forever(v) == 5
  })
}

/// 值进程忙时 set_forever 会等到它空闲再设置
pub fn set_forever_waits_test() {
  with_timeout(5, 50, fn(v) {
    occupy(v, 200)
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
    var.scope(5, default_timeout, fn(v) {
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
  let assert Error(_) = error.try(fn() { var.get(escaped) })
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

/// 已死亡的值，反复查询结果稳定
pub fn is_alive_stays_false_test() {
  let escaped = dead_var()
  assert var.is_alive(escaped) == False
  let _ = var.try_get(escaped)
  assert var.is_alive(escaped) == False
}

/// 作用域结束后，逃出去的 Var 再用会 panic
pub fn escaped_value_get_panics_test() {
  let escaped = escaped_var()

  // kill 与这次 get 都由本进程发出，消息顺序有保证
  let assert Error(_) = error.try(fn() { var.get(escaped) })
  Nil
}

/// 当前行为：值已死亡时 try_get 返回 Error(Timeout)（而不是别的错误）
pub fn escaped_value_try_get_is_timeout_test() {
  let escaped = dead_var()
  assert var.try_get(escaped) == Error(var.Timeout)
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

    assert var.get(v) == workers
  })
}

/// 另一个进程设置值，本进程能立刻读到（set 是同步的）
pub fn cross_process_set_test() {
  with(0, fn(v) {
    let done = process.new_subject()
    let _ = process.spawn_unlinked(fn() { process.send(done, var.set(v, 7)) })

    assert process.receive_forever(done) == 7
    assert var.get(v) == 7
  })
}

/// 另一个进程读完把值带回来
pub fn cross_process_get_test() {
  with(99, fn(v) {
    let done = process.new_subject()
    let _ = process.spawn_unlinked(fn() { process.send(done, var.get(v)) })

    assert process.receive_forever(done) == 99
  })
}

// 测试里需要主动抛出另外两类异常
@external(erlang, "erlang", "throw")
fn throw(value: a) -> b

@external(erlang, "erlang", "exit")
fn exit(reason: a) -> b
