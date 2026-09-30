import error.{type Exception}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/otp/actor.{type Next, type StartError, type Started, Started}
import gleam/result

import variable/internal/term.{type Term}

/// 要与可变值交互需要持有此类型
pub opaque type Var(var) {
  Var(sub: Subject(ValMessage(var)), pid: Pid)
}

/// 属于[scope](https://variable.hexdocs.pm/var.html#scope)函数的错误类型
pub type ScopeError {
  /// 进程启动失败
  StartErr(err: StartError)
  /// 回调函数异常
  ScopeErr(err: Exception)
}

/// 属于[update](https://variable.hexdocs.pm/var.html#update)函数的错误类型
pub type UpdateError {
  /// 回调函数异常
  UpdateErr(err: Exception)
}

/// 属于[try_get](https://variable.hexdocs.pm/var.html#try_get)/[try_set](https://variable.hexdocs.pm/var.html#try_set)函数的错误类型
pub type Timeout {
  /// 超时
  Timeout
}

/// [subscribe](https://variable.hexdocs.pm/var.html#subscribe)函数返回的用于取消订阅的函数的返回值
pub opaque type Unsubscribed {
  /// 已取消订阅
  Unsubscribed
}

/// 可变值进程携带的状态
type Val(var) {
  /// val: 值本身
  /// 
  /// subscribe: 携带订阅进程通道的字典
  Val(val: var, subscribes: Dict(Reference, Subject(SubMessage(var))))
}

/// 可变值进程接收的消息
type ValMessage(var) {
  /// 关闭可变值进程
  ValStop
  /// 订阅
  Subscribe(ref: Reference, sub: Subject(SubMessage(var)))
  /// 取消订阅
  Unsubscribe(ref: Reference)
  /// 获取值
  Get(sub: Subject(var), term: Term)
  /// 设置值
  Set(new_val: var, sub: Subject(var), term: Term)
  /// 使用给定函数处理值
  Update(update: fn(var) -> var, sub: Subject(Result(var, UpdateError)))
}

/// 订阅进程接收的消息
type SubMessage(var) {
  /// 关闭订阅进程
  SubStop
  /// 可变值进程已关闭
  ValStopped
  /// 值变化
  ValChange(old_val: var, new_val: var)
}

/// 创建一个进程模拟可变值
/// 
/// 可变值在回调函数中可用，回调结束自动关闭可变值进程
/// 
/// 关闭是同步的，会等待所有消息处理完毕，回调函数结束后进程必然已关闭
/// 
/// # Notice
/// 如果回调已经结束，但仍有进程在持有可变值则有引发异常的风险
/// 
/// 对于可变值出逃后的行为不作保障
/// ```gleam
/// let sub = process.new_subject()
/// // 将Var传到回调外部
/// // 随后回调结束，进程关闭
/// var.scope(5, fn(val) { process.send(sub, val) })
/// let val = process.receive_forever(sub)
///
/// // 进程已关闭，这里会产生异常
/// var.get(val, 1000)
/// ```
/// 
/// # Param
/// val：初始值
/// 
/// scope：一个接受可变值([Var](https://variable.hexdocs.pm/var.html#Var))作为参数的函数
pub fn scope(
  val: var,
  scope: fn(Var(var)) -> return,
) -> Result(return, ScopeError) {
  case init(val) {
    // 启动失败
    Error(err) -> Error(StartErr(err))
    // 启动成功
    Ok(var) -> {
      // 尝试执行回调函数
      let return = error.try(fn() { scope(var) })
      // 等待所有消息处理完毕，随后关闭进程
      closure(var)
      // 成功返回函数的返回值
      // 失败返回函数的异常
      use ex <- result.try_recover(return)
      Error(ScopeErr(ex))
    }
  }
}

/// 订阅函数，每当成功[set](https://variable.hexdocs.pm/var.html#set)/[update](https://variable.hexdocs.pm/var.html#update)时自动调用订阅函数
/// 
/// 订阅函数发生异常一般不会有后果
/// 
/// 该函数会为每个订阅spawn一个进程，如果订阅函数执行的较慢则会导致消息堆积
/// 
/// # Notice
/// 订阅函数只接收订阅后的值，不补发当前值
/// 
/// 在订阅函数中[set](https://variable.hexdocs.pm/var.html#set)/[update](https://variable.hexdocs.pm/var.html#update)同一个[Var](https://variable.hexdocs.pm/var.html#Var)会导致循环
/// ```gleam
/// use val <- var.scope(5)
/// 
/// var.subscribe(val, fn(old, new) {
///   io.println(int.to_string(old) <> " -> " <> int.to_string(new))
///   var.set(val, 1000, new + 1)
/// })
/// 
/// var.set(val, 1000, 6)
/// ```
/// 
/// # Param 
/// subscribe: 接收旧值和新值的订阅函数(**subscribe(old_val, new_val)**)
/// 
/// # Return
/// 返回一个用于取消订阅的函数
pub fn subscribe(
  var: Var(var),
  subscribe: fn(var, var) -> discard,
) -> fn() -> Unsubscribed {
  // 用于接收订阅进程的通道
  let ready = process.new_subject()

  // 创建订阅进程
  process.spawn_unlinked(fn() {
    // 订阅进程的通道
    let sub = process.new_subject()
    // 监控可变值进程
    let mon = process.monitor(var.pid)
    // 选择器
    let sel =
      process.new_selector()
      |> process.select(sub)
      |> process.select_specific_monitor(mon, fn(_) { ValStopped })

    // 发送订阅进程的通道
    process.send(ready, sub)

    subscribe_loop(sel, subscribe)
  })

  // 唯一键
  let ref = reference.new()
  // 获取订阅进程的通道以用于发送值变化的消息
  let sub = process.receive_forever(ready)
  // 向可变值进程发送消息以注册订阅
  process.send(var.sub, Subscribe(ref:, sub:))

  // 返回用于取消订阅的函数
  fn() -> Unsubscribed {
    process.send(var.sub, Unsubscribe(ref:))
    Unsubscribed
  }
}

/// 在指定时间内(毫秒)获取值
/// 
/// 操作可能超时，可以使用[try_get](https://variable.hexdocs.pm/var.html#try_get)
/// 
/// 如果想一直等待可以使用[get_forever](https://variable.hexdocs.pm/var.html#get_forever)
/// 
/// # Panic
/// 进程关闭后使用该函数会导致异常
pub fn get(var: Var(var), timeout: Int) -> var {
  process.call(var.sub, timeout, Get(sub: _, term: term.deadline(timeout)))
}

/// 获取值并一直等待直至成功
/// 
/// # Panic
/// 进程关闭后使用该函数会导致异常
pub fn get_forever(var: Var(var)) -> var {
  process.call_forever(var.sub, Get(sub: _, term: term.forever()))
}

/// 尝试在指定时间内(毫秒)获取值
pub fn try_get(var: Var(var), timeout: Int) -> Result(var, Timeout) {
  fn() { get(var, timeout) }
  |> error.try()
  |> result.try_recover(fn(_) { Error(Timeout) })
}

/// 在指定时间内(毫秒)设置值，随后后返回新的值
/// 
/// 操作可能超时，可以使用[try_set](https://variable.hexdocs.pm/var.html#try_set)
/// 
/// 如果想一直等待可以使用[set_forever](https://variable.hexdocs.pm/var.html#set_forever)
/// 
/// # Panic
/// 进程关闭后使用该函数会导致异常
pub fn set(var: Var(var), timeout: Int, new_val: var) -> var {
  process.call(var.sub, timeout, Set(
    new_val:,
    sub: _,
    term: term.deadline(timeout),
  ))
}

/// 设置值并一直等待直至成功，随后返回新的值
/// 
/// # Panic
/// 进程关闭后使用该函数会导致异常
pub fn set_forever(var: Var(var), new_val: var) -> var {
  process.call_forever(var.sub, Set(new_val:, sub: _, term: term.forever()))
}

/// 尝试在指定时间内(毫秒)设置值，随后返回新的值
pub fn try_set(
  var: Var(var),
  timeout: Int,
  new_val: var,
) -> Result(var, Timeout) {
  fn() { set(var, timeout, new_val) }
  |> error.try()
  |> result.try_recover(fn(_) { Error(Timeout) })
}

/// 使用函数更新值，随后返回更新后的值
/// 
/// 若函数异常则保持原有值不变
/// 
/// # Notice
/// 该函数没有超时保护，会一直等待直至回调函数返回或异常
/// 
/// 如果回调函数卡住则会造成阻塞，导致其他操作超时
/// 
/// 这么做会卡死
/// ```gleam
/// pub fn main() {
///   use val <- var.scope(5)
///   var.update(val, func(val, _))
/// }
///
/// fn func(val, v) {
///   var.update(val, func(val, _))
///   v + 1
/// }
/// ```
/// 
/// # Panic
/// 进程关闭后使用该函数会导致异常
pub fn update(
  var: Var(var),
  update: fn(var) -> var,
) -> Result(var, UpdateError) {
  process.call_forever(var.sub, Update(update:, sub: _))
}

/// 检查可变值是否存活
/// 
/// # Notice
/// 同进程内`scope`回调结束进程已关闭，该值必然为`False`，`scope`回调内进程未关闭，该值必然为`True`
/// 
/// 跨进程该值才有参考价值，但也仅供参考
pub fn is_alive(var: Var(var)) -> Bool {
  process.is_alive(var.pid)
}

/// 等待所有消息处理完毕，随后关闭进程
fn closure(var: Var(var)) -> Nil {
  let mon = process.monitor(var.pid)
  let sel =
    process.new_selector()
    |> process.select_specific_monitor(mon, fn(_) { Nil })

  process.send(var.sub, ValStop)

  process.selector_receive_forever(sel)
}

/// 初始化新的可变值
fn init(val: var) -> Result(Var(var), StartError) {
  use Started(data:, pid:) <- result.try(new(val))
  Var(data, pid) |> Ok()
}

/// 创建新的可变值进程
fn new(val: var) -> Result(Started(Subject(ValMessage(var))), StartError) {
  actor.new(Val(val:, subscribes: dict.new()))
  |> actor.on_message(handle)
  |> actor.start()
}

/// 封装订阅函数
fn subscribe_loop(
  sel: Selector(SubMessage(var)),
  subscribe: fn(var, var) -> discard,
) -> Nil {
  case process.selector_receive_forever(sel) {
    // 关闭消息或可变值进程关闭消息
    SubStop | ValStopped -> Nil
    // 值变化消息
    ValChange(old_val:, new_val:) -> {
      // 执行订阅函数
      let _ = error.try(fn() { subscribe(old_val, new_val) })

      // 递归调用，继续接收消息
      subscribe_loop(sel, subscribe)
    }
  }
}

/// 通知订阅函数值已发生变化
fn notify(
  subscribe: Dict(Reference, Subject(SubMessage(var))),
  old_val: var,
  new_val: var,
) -> Nil {
  use _, sub <- dict.each(subscribe)
  process.send(sub, ValChange(old_val:, new_val:))
}

fn handle(
  value: Val(var),
  msg: ValMessage(var),
) -> Next(Val(var), ValMessage(var)) {
  let Val(val:, subscribes:) = value
  case msg {
    // 关闭
    ValStop -> actor.stop()
    // 订阅
    Subscribe(ref:, sub:) ->
      Val(..value, subscribes: dict.insert(subscribes, ref, sub))
      |> actor.continue()
    // 取消订阅
    Unsubscribe(ref:) -> {
      // 通知该订阅关闭
      case dict.get(subscribes, ref) {
        Error(_) -> Nil
        Ok(sub) -> process.send(sub, SubStop)
      }

      // 从字典中删除该订阅
      Val(..value, subscribes: dict.delete(subscribes, ref))
      |> actor.continue()
    }
    // 获取值
    Get(sub:, term:) -> {
      use <- bool.guard(term.is_expired(term), actor.continue(value))

      process.send(sub, val)

      actor.continue(value)
    }
    // 设置值
    Set(new_val:, sub:, term:) -> {
      use <- bool.guard(term.is_expired(term), actor.continue(value))

      process.send(sub, new_val)
      notify(subscribes, val, new_val)

      Val(..value, val: new_val)
      |> actor.continue()
    }
    // 使用给定函数更新值
    Update(update:, sub:) ->
      case error.try(fn() { update(val) }) {
        // 函数异常
        Error(err) -> {
          process.send(sub, Error(UpdateErr(err)))

          actor.continue(value)
        }
        // 函数正常
        Ok(new_val) -> {
          process.send(sub, Ok(new_val))
          notify(subscribes, val, new_val)

          Val(..value, val: new_val)
          |> actor.continue()
        }
      }
  }
}
